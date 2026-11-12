import base64
import importlib.util
import io
import json
import sqlite3
import stat
import tempfile
import unittest
import urllib.error
import zipfile
from pathlib import Path
from unittest.mock import patch
from contextlib import closing


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


service = load("reviews", "scripts/pi_review_service.py")
gateway = load("gateway", "deploy/gateway.py")


class Reviews(unittest.TestCase):
    def test_config(self):
        self.assertEqual(service.config("enabled: true\nauto: false")['auto'], False)
        for text in ("", "enabled: maybe", "enabled: true\nenabled: false", "enabled: true\nbroken", "x" * 4097):
            self.assertFalse(service.config(text)["enabled"])
        self.assertTrue(service.config("enabled: yes\nauto: true\ntasks: false")["auto"])

    def test_archive(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("repo/src/app.py", "print(1)")
            archive.writestr("repo/.pi/extensions/evil.js", "bad")
            link = zipfile.ZipInfo("repo/link")
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "/etc/passwd")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service.extract_snapshot(data.getvalue(), root)
            self.assertEqual((root / "src/app.py").read_text(), "print(1)")
            self.assertFalse((root / ".pi").exists())
            self.assertFalse((root / "link").exists())
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("repo/../../escape", "bad")
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            service.extract_snapshot(data.getvalue(), Path(directory))

    def test_sandbox(self):
        argv = service.sandbox_command("test", Path("/tmp/test"))
        for flag in ("--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true", "--log-driver=none"):
            self.assertIn(flag, argv)
        self.assertNotIn("--privileged", argv)
        self.assertNotIn("/var/run/docker.sock", " ".join(argv))
        self.assertEqual(argv[argv.index("--network") + 1], "forgejo-copilot-sandbox")

    def test_agent_result(self):
        output = '\n'.join(json.dumps(e) for e in [
            {"type": "tool_execution_start", "toolName": "read"},
            {"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "bug at app.py:1"}]}}
        ])
        self.assertEqual(service.agent_result(output), ("bug at app.py:1", ["read"]))
        with self.assertRaises(ValueError):
            service.agent_result('{"type":"message_end","message":{"role":"assistant","stopReason":"error"}}')

    def test_daily_budget_durable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "budget.sqlite3")
            for _ in range(20):
                gateway.reserve(path)
            with self.assertRaises(ValueError):
                gateway.reserve(path)
            with closing(sqlite3.connect(path)) as db:
                self.assertEqual(db.execute("SELECT cents FROM budget").fetchone()[0], 500)

    def test_gateway_policy(self):
        body = {"model": gateway.MODEL, "messages": [{"role": "user", "content": "Review"}], "max_tokens": 999999}
        self.assertEqual(gateway.completion(body)["max_tokens"], 4096)
        for body in (
            {"model": "expensive"},
            {"model": gateway.MODEL, "messages": [], "plugins": [{"id": "web"}]},
            {"model": gateway.MODEL, "messages": [{"role": "user", "content": [{"type": "image_url"}]}]},
            {"model": gateway.MODEL, "messages": [{"role": "user", "content": "x"}], "tools": [{"type": "web_search"}]},
        ):
            with self.assertRaises(ValueError):
                gateway.completion(body)

    def test_key_must_be_capped(self):
        for data in ({"limit": None}, {"limit": 5, "limit_reset": "monthly"},
                     {"limit": 5, "limit_reset": "daily", "include_byok_in_limit": True, "limit_remaining": 0}):
            response = io.BytesIO(json.dumps({"data": data}).encode())
            with patch.object(gateway, "upstream", return_value=response), self.assertRaises(ValueError):
                gateway.check_key("not-a-real-key")

    def test_price_fail_closed(self):
        for pricing in ({"prompt": "0.0001", "completion": "0.000001"},
                        {"prompt": "0.000001", "completion": "0.000004", "request": "1"}):
            response = io.BytesIO(json.dumps({"data": [{"id": gateway.MODEL, "pricing": pricing}]}).encode())
            with patch.object(gateway, "upstream", return_value=response), self.assertRaises(ValueError):
                gateway.check_price("not-a-real-key")
        response = io.BytesIO(json.dumps({"data": [{"id": gateway.MODEL, "pricing": {
            "prompt": "0.0000004", "completion": "0.0000016", "web_search": "0.01"}}]}).encode())
        with patch.object(gateway, "upstream", return_value=response):
            gateway.check_price("not-a-real-key")  # Optional search is blocked at request admission.

    def test_review_opt_in_and_idempotency(self):
        pull = {"number": 1, "state": "open", "base": {"sha": "base"}, "head": {"sha": "head"}}
        class Fake:
            text = "enabled: true\nauto: true"
            comments = []
            posts = 0
            def pages(self, path):
                return [pull] if "/pulls?" in path else self.comments
            def call(self, path, body=None):
                if "/contents/.copilot?ref=base" in path:
                    return {"content": base64.b64encode(self.text.encode()).decode()}
                if body:
                    self.posts += 1
                    self.comments = [{"body": body["body"]}]
                    return {"id": 1}
                return pull
        forge = Fake()
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.execute("CREATE TABLE completed(id TEXT PRIMARY KEY)")
        with patch.object(service, "review", return_value=("app.py:1 bug", ["read"])) as review:
            service.poll(forge, ["owner/repo"], db, "/tmp")
            service.poll(forge, ["owner/repo"], db, "/tmp")
            self.assertEqual(forge.posts, 1)
            self.assertEqual(review.call_count, 1)
            db.execute("DELETE FROM completed")
            service.poll(forge, ["owner/repo"], db, "/tmp")
            self.assertEqual(forge.posts, 1)  # Remote marker recovers crash after posting.
            forge.text = "enabled: false\nauto: true"
            forge.comments = []
            service.poll(forge, ["owner/repo"], db, "/tmp")
            self.assertEqual(forge.posts, 1)

    def test_manual_authorization_and_stale_result(self):
        pull = {"number": 1, "state": "open", "base": {"sha": "base"}, "head": {"sha": "head"}}
        class Fake:
            permission = "read"
            missing = False
            stale = False
            reads = 0
            posts = 0
            def pages(self, path):
                if "/pulls?" in path:
                    return [pull]
                return [{"id": 5, "body": "/review", "user": {"login": "writer"}}]
            def call(self, path, body=None):
                if "/contents/.copilot?ref=base" in path:
                    if self.missing:
                        raise urllib.error.HTTPError("https://example.test", 404, "absent", {}, None)
                    return {"content": base64.b64encode(b"enabled: true\nauto: false").decode()}
                if "/permission" in path:
                    return {"permission": self.permission}
                if body:
                    self.posts += 1
                    return {"id": 1}
                self.reads += 1
                if self.stale and self.reads % 2 == 0:
                    return dict(pull, state="closed")
                return pull
        forge = Fake()
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.execute("CREATE TABLE completed(id TEXT PRIMARY KEY)")
        with patch.object(service, "review", return_value=("app.py:1 bug", ["read"])) as review:
            service.poll(forge, ["owner/repo"], db, "/tmp")
            review.assert_not_called()
            forge.permission = "write"
            forge.missing = True
            service.poll(forge, ["owner/repo"], db, "/tmp")
            review.assert_not_called()
            forge.missing = False
            forge.stale = True
            forge.reads = 0
            service.poll(forge, ["owner/repo"], db, "/tmp")
            self.assertEqual(review.call_count, 1)
            self.assertEqual(forge.posts, 0)
            forge.stale = False
            service.poll(forge, ["owner/repo"], db, "/tmp")
            self.assertEqual(forge.posts, 1)
            self.assertEqual(review.call_count, 2)

    def test_question_trigger_policy(self):
        settings = service.config("enabled: true\nquestions: true\nquestion_mentions: mara,star\nquestion_mode: explicit")
        identities = {"mara": object(), "star": object()}
        self.assertEqual(service.question_targets("@mara and @STAR why?", settings, identities), ["mara", "star"])
        for body in ("Thanks @mara", "@marathon why?", "> @mara why?", "```\n@star why?\n```", "person@mara.example why?"):
            self.assertEqual(service.question_targets(body, settings, identities), [])
        self.assertEqual(service.question_targets("@star /ask explain mean", settings, identities), ["star"])
        for text in ("enabled: true\nquestion_mode: always", "enabled: true\nquestion_mentions: mara,*",
                     "enabled: true\nquestion_access: adminish"):
            self.assertFalse(service.config(text)["enabled"])

    def test_question_real_posters_and_idempotency(self):
        issue = {"number": 2, "state": "open", "user": {"login": "writer"},
                 "body": "@mara @star Why does mean([]) return zero?"}
        class Fake:
            comments = []
            def pages(self, path):
                return [issue] if "issues?" in path else list(self.comments)
            def call(self, path, body=None):
                if path == "repos/o/r":
                    return {"default_branch": "main"}
                if "/branches/" in path:
                    return {"commit": {"id": "a" * 40}}
                if "/contents/.copilot?ref=" in path:
                    return {"content": base64.b64encode(b"enabled: true\nquestions: true").decode()}
                if "/permission" in path:
                    return {"permission": "write"}
                return issue
        forge = Fake()
        class Poster:
            def __init__(self, login):
                self.login = login
            def call(self, path, body):
                forge.comments.append({"id": len(forge.comments) + 5, "body": body["body"], "user": {"login": self.login}})
        identities = {login: Poster(login) for login in ("mara", "star")}
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        with patch.object(service, "run_agent", return_value=("calculator.py:2 checks empty input.", ["read"])) as agent:
            service.poll_questions(forge, ["o/r"], identities, db, "/tmp")
            service.poll_questions(forge, ["o/r"], identities, db, "/tmp")
            self.assertEqual(agent.call_count, 2)
            self.assertEqual([c["user"]["login"] for c in forge.comments], ["mara", "star"])
            db.execute("DELETE FROM answers")
            service.poll_questions(forge, ["o/r"], identities, db, "/tmp")
            self.assertEqual(agent.call_count, 2)  # Remote markers and bot-author exclusion.

    def test_identity_mismatch_fails_closed(self):
        with tempfile.NamedTemporaryFile(mode="w") as token:
            token.write("fake-token")
            token.flush()
            with patch.object(service.Forgejo, "call", return_value={"login": "not-mara"}), self.assertRaises(ValueError):
                service.load_identities("https://example.test", {"mara": token.name})
            Path(token.name).chmod(0o644)
            with self.assertRaises(ValueError):
                service.read_token(token.name)


if __name__ == "__main__":
    unittest.main()
