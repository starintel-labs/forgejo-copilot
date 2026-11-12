"""The sandbox's only egress: one model, one endpoint, no client credentials.

Reserve $0.25 durably before every upstream attempt (never refund on failures).
With <=200KB of text input, <=4096 output tokens and catalog prices bounded
by $1/M input and $4/M output this overestimates each request. A dedicated
OpenRouter daily key limit is a second, independent spending boundary.
"""
import json
import os
import sqlite3
import urllib.error
import urllib.request
import uuid
from decimal import Decimal, ROUND_CEILING
from datetime import datetime, timezone
from contextlib import closing
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

MODEL = "openai/gpt-4.1-mini"
MAX_BODY = 200_000
RESERVATION_CENTS = 25
DAILY_CENTS = 500
UPSTREAM = "https://openrouter.ai/api/v1"


def upstream(path, key, body=None):
    request = urllib.request.Request(
        UPSTREAM + path, data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *_args):
            return None
    return urllib.request.build_opener(NoRedirect).open(request, timeout=120)


def check_key(key):
    with upstream("/key", key) as response:
        data = json.load(response)["data"]
    if (data.get("limit") != 5 or data.get("limit_reset") != "daily"
            or data.get("include_byok_in_limit") is not True
            or data.get("is_management_key") is True or data.get("disabled") is True):
        raise ValueError("Dedicated key must have a $5 daily limit including BYOK")
    remaining = data.get("limit_remaining")
    if remaining is None or remaining < RESERVATION_CENTS / 100:
        raise ValueError("Daily budget exhausted")
    return data


def provider_floor_cents(data):
    value = Decimal(str(data.get("usage_daily", 0))) + Decimal(str(data.get("byok_usage_daily", 0)))
    if not value.is_finite() or value < 0:
        raise ValueError("Invalid provider accounting")
    return int((value * 100).to_integral_value(rounding=ROUND_CEILING))


def check_price(key):
    with upstream("/models", key) as response:
        model = next(m for m in json.load(response)["data"] if m["id"] == MODEL)
    prices = model["pricing"]
    if not (0 <= float(prices["prompt"]) <= 0.000001
            and 0 <= float(prices["completion"]) <= 0.000004):
        raise ValueError("Model price exceeds conservative budget reservation")
    # Optional search/image products are inaccessible: text-only content,
    # function-only tools, and no plugins. Reject unconditional extra fees.
    if any(float(prices.get(k, 0) or 0) != 0
           for k in ("request", "internal_reasoning", "input_cache_write")):
        raise ValueError("Unbudgeted model fee")
    if not 0 <= float(prices.get("input_cache_read", 0)) <= 0.000001:
        raise ValueError("Unbudgeted cache-read price")


def reserve(db_path, floor_cents=0):
    day = datetime.now(timezone.utc).date().isoformat()
    attempt = uuid.uuid4().hex
    with closing(sqlite3.connect(db_path)) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS budget(day TEXT PRIMARY KEY, cents INTEGER NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY,day TEXT NOT NULL,reserved INTEGER NOT NULL,charged INTEGER)")
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT cents FROM budget WHERE day=?", (day,)).fetchone()
        used = max(row[0] if row else 0, floor_cents)
        if used + RESERVATION_CENTS > DAILY_CENTS:
            raise ValueError("Daily conservative budget exhausted")
        db.execute("INSERT INTO budget VALUES(?,?) ON CONFLICT(day) DO UPDATE SET cents=excluded.cents",
                    (day, used + RESERVATION_CENTS))
        db.execute("INSERT INTO attempts VALUES(?,?,?,NULL)", (attempt, day, RESERVATION_CENTS))
    return attempt


def settle(db_path, attempt, usage):
    """Release unused reservation only after complete, validated provider usage.

    Charge whole cents at the admitted *price ceilings*, not optimistic actual
    prices. Errors, partial streams and missing usage retain the full reserve.
    """
    prompt, output = usage.get("prompt_tokens"), usage.get("completion_tokens")
    if type(prompt) is not int or type(output) is not int or prompt < 0 or not 0 <= output <= 4096:
        raise ValueError("Invalid provider usage")
    charged = max(1, (prompt + 4 * output + 9999) // 10000)
    if charged > RESERVATION_CENTS:
        raise ValueError("Usage exceeded the conservative reservation")
    with closing(sqlite3.connect(db_path)) as db, db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT day,reserved,charged FROM attempts WHERE id=?", (attempt,)).fetchone()
        if row is None:
            raise ValueError("Unknown reservation")
        if row[2] is not None:
            return
        db.execute("UPDATE attempts SET charged=? WHERE id=?", (charged, attempt))
        db.execute("UPDATE budget SET cents=cents-? WHERE day=?", (row[1] - charged, row[0]))


class UsageStream:
    def __init__(self):
        self.buffer = b""
        self.usage = None
        self.done = False

    def feed(self, chunk):
        self.buffer += chunk
        if len(self.buffer) > 1024 * 1024:
            raise ValueError("Provider event exceeds limit")
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            if not line.startswith(b"data:"):
                continue
            payload = line[5:].strip()
            if payload == b"[DONE]":
                self.done = True
            else:
                event = json.loads(payload)
                if not isinstance(event, dict):
                    raise ValueError("Invalid provider event")
                if isinstance(event.get("usage"), dict):
                    self.usage = event["usage"]


def completion(body):
    if not isinstance(body, dict) or body.get("model") != MODEL:
        raise ValueError("Model not allowed")
    allowed = {"model", "messages", "tools", "tool_choice", "stream", "stream_options",
               "max_tokens", "max_completion_tokens", "temperature", "top_p"}
    if set(body) - allowed:
        raise ValueError("Request field not allowed")
    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("Missing messages")
    for message in messages:
        if not isinstance(message, dict):
            raise ValueError("Only text content is allowed")
        content = message.get("content", "")
        if isinstance(content, list):
            if not all(isinstance(part, dict) and set(part) == {"type", "text"}
                       and part["type"] == "text" and isinstance(part["text"], str) for part in content):
                raise ValueError("Only text content is allowed")
            message["content"] = "\n".join(part["text"] for part in content)
        elif not isinstance(content, (str, type(None))):
            raise ValueError("Only text content is allowed")
        if set(message) - {"role", "content", "tool_calls", "tool_call_id", "name"}:
            raise ValueError("Message field not allowed")
        if message.get("role") not in {"system", "developer", "user", "assistant", "tool"}:
            raise ValueError("Message role not allowed")
        for call in message.get("tool_calls", []):
            if call.get("type") != "function" or set(call) - {"id", "type", "function"}:
                raise ValueError("Only local function calls are allowed")
    for tool in body.get("tools", []):
        if tool.get("type") != "function" or set(tool) != {"type", "function"}:
            raise ValueError("Only local function tools are allowed")
    choice = body.get("tool_choice", "auto")
    if isinstance(choice, dict):
        if set(choice) != {"type", "function"} or choice["type"] != "function":
            raise ValueError("Tool choice not allowed")
    elif choice not in {"auto", "none", "required"}:
        raise ValueError("Tool choice not allowed")
    body.pop("max_completion_tokens", None)
    body["max_tokens"] = 4096
    body["provider"] = {"allow_fallbacks": False, "require_parameters": True}
    return body


class Gateway(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(130)

    def log_message(self, *_args):
        pass  # Never log prompts, credentials, or upstream errors.

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        stage = "request"
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError("Request size exceeds limit")
            body = completion(json.loads(self.rfile.read(length)))
            stage = "key"
            key = Path(os.environ["KEY_FILE"]).read_text().strip()
            key_data = check_key(key)
            stage = "price"
            check_price(key)
            stage = "reservation"
            attempt = reserve(os.environ["BUDGET_DB"], provider_floor_cents(key_data))
            stage = "completion"
            with upstream("/chat/completions", key, body) as response:
                self.send_response(200)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.end_headers()
                usage = UsageStream()
                complete_usage = True
                while chunk := response.read1(8192):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if complete_usage:
                        try:
                            usage.feed(chunk)
                        except (ValueError, TypeError, KeyError):
                            complete_usage = False
                if complete_usage and usage.done and usage.usage is not None:
                    try:
                        settle(os.environ["BUDGET_DB"], attempt, usage.usage)
                    except (ValueError, sqlite3.Error):
                        print("gateway retained full reservation: incomplete accounting", flush=True)
        except (ValueError, KeyError, TypeError, StopIteration) as error:
            print("gateway denied:", stage, type(error).__name__, flush=True)
            self.send_error(429, "Budget or request policy denied")
        except (urllib.error.URLError, TimeoutError, OSError):
            self.send_error(502, "Model gateway unavailable")


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Gateway).serve_forever()
