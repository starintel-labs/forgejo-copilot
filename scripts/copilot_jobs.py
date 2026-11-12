"""Durable admission and publication policy for background implementation jobs."""
import base64
import hashlib
import json
import os
import re
import sqlite3
import stat
import time
import urllib.parse
from contextlib import closing
from pathlib import Path, PurePosixPath

import pi_review_service as core

ACTIVE = ("queued", "running", "blocked")
FIELDS = {"state", "phase", "branch", "base_ref", "base_sha", "policy_sha", "pr", "url", "result", "test_exit", "test_output", "artifact_hash", "error", "container", "version", "request", "notified", "notice_retry"}


class JobStore:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self.connect()) as db, db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS jobs(
                    id TEXT PRIMARY KEY, repo TEXT NOT NULL, issue INTEGER NOT NULL,
                    actor TEXT NOT NULL, identity TEXT NOT NULL, request TEXT NOT NULL,
                    version INTEGER NOT NULL DEFAULT 1, state TEXT NOT NULL DEFAULT 'queued',
                    branch TEXT, base_ref TEXT, base_sha TEXT, policy_sha TEXT,
                    pr INTEGER, url TEXT, result TEXT, test_exit INTEGER, error TEXT,
                    container TEXT, created REAL NOT NULL, updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, job TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS controls(id TEXT PRIMARY KEY);
                CREATE UNIQUE INDEX IF NOT EXISTS active_issue ON jobs(repo,issue)
                    WHERE state IN ('queued','running','blocked');
            """)
            columns = {row[1] for row in db.execute("PRAGMA table_info(jobs)")}
            for name, kind in {"phase": "TEXT", "test_output": "TEXT", "artifact_hash": "TEXT", "notified": "TEXT", "notice_retry": "REAL DEFAULT 0"}.items():
                if name not in columns:
                    db.execute(f"ALTER TABLE jobs ADD COLUMN {name} {kind}")
        self.path.chmod(0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        return db

    def get(self, key):
        with closing(self.connect()) as db:
            row = db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone()
            return dict(row) if row else None

    def latest(self, repo, issue):
        with closing(self.connect()) as db:
            row = db.execute("SELECT * FROM jobs WHERE repo=? AND issue=? ORDER BY created DESC LIMIT 1", (repo, issue)).fetchone()
            return dict(row) if row else None

    def enqueue(self, repo, issue, actor, identity, request, event):
        if not core.REPO.fullmatch(repo) or not request.strip() or len(request.encode()) > 20_000:
            raise ValueError("Invalid task request")
        key = hashlib.sha256(f"{repo}:{issue}:{identity}:{event}:{request}".encode()).hexdigest()
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            seen = db.execute("SELECT job FROM events WHERE id=?", (event,)).fetchone()
            if seen:
                row = db.execute("SELECT * FROM jobs WHERE id=?", (seen[0],)).fetchone()
                return dict(row), "seen"
            row = db.execute("SELECT * FROM jobs WHERE repo=? AND issue=? AND state IN ('queued','running','blocked')", (repo, issue)).fetchone()
            now = time.time()
            if row:
                if row["identity"] != identity:
                    raise ValueError("This issue already has an active task owned by another identity")
                request = row["request"] + f"\n\nFollow-up from {actor}:\n" + request
                if len(request.encode()) > 32_000:
                    raise ValueError("Task context limit reached")
                key = row["id"]
                state = "queued" if row["state"] == "blocked" else row["state"]
                db.execute("UPDATE jobs SET request=?,version=version+1,state=?,phase='implementing',test_exit=NULL,artifact_hash=NULL,updated=? WHERE id=?", (request, state, now, key))
                action = "steered"
            else:
                db.execute("INSERT INTO jobs(id,repo,issue,actor,identity,request,created,updated) VALUES(?,?,?,?,?,?,?,?)", (key, repo, issue, actor, identity, request, now, now))
                action = "new"
            db.execute("INSERT INTO events VALUES(?,?)", (event, key))
            return dict(db.execute("SELECT * FROM jobs WHERE id=?", (key,)).fetchone()), action

    def update(self, key, **values):
        if not values or set(values) - FIELDS:
            raise ValueError("Invalid job state patch")
        with closing(self.connect()) as db, db:
            db.execute("UPDATE jobs SET " + ",".join(name + "=?" for name in values) + ",updated=? WHERE id=?", (*values.values(), time.time(), key))

    def claim(self):
        with closing(self.connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT id FROM jobs WHERE state='queued' ORDER BY created LIMIT 1").fetchone()
            if not row:
                return None
            db.execute("UPDATE jobs SET state='running',updated=? WHERE id=?", (time.time(), row[0]))
            return dict(db.execute("SELECT * FROM jobs WHERE id=?", (row[0],)).fetchone())

    def recover(self):
        with closing(self.connect()) as db, db:
            db.execute("UPDATE jobs SET state='queued' WHERE state='running'")

    def retry(self, key):
        with closing(self.connect()) as db, db:
            db.execute("UPDATE jobs SET state='queued',version=version+1,error=NULL,notice_retry=0,updated=? "
                       "WHERE id=? AND state IN ('blocked','failed','cancelled')", (time.time(), key))

    def previous_ready(self, job):
        with closing(self.connect()) as db:
            row = db.execute("SELECT * FROM jobs WHERE repo=? AND issue=? AND id!=? AND state='ready' AND pr IS NOT NULL ORDER BY created DESC LIMIT 1", (job["repo"], job["issue"], job["id"])).fetchone()
            return dict(row) if row else None

    def pending_notices(self):
        with closing(self.connect()) as db:
            return [dict(row) for row in db.execute("SELECT * FROM jobs WHERE state IN ('ready','blocked','cancelled') AND (notified IS NULL OR notified!=state||':'||version) AND notice_retry<=? ORDER BY created LIMIT 10", (time.time(),))]

    def controlled(self, event, *, record=False):
        with closing(self.connect()) as db, db:
            if record:
                db.execute("INSERT OR IGNORE INTO controls VALUES(?)", (event,))
            return db.execute("SELECT 1 FROM controls WHERE id=?", (event,)).fetchone() is not None


def invocation(body, settings, identities):
    if not settings.get("tasks"):
        return None
    lines, fenced = [], False
    for line in body.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
        elif not fenced and not line.lstrip().startswith(">"):
            lines.append(line)
    text = "\n".join(lines).strip()
    match = re.match(r"^@([a-z0-9_-]+)\s+(.+)$", text, re.I | re.S)
    if not match:
        return None
    identity, request = match[1].lower(), match[2].strip()
    if identity not in identities or identity not in settings["task_mentions"].split(","):
        return None
    command = re.match(r"^/?(status|cancel|stop|pause|retry|resume)\b", request, re.I)
    if command:
        action = {"stop": "cancel", "pause": "cancel", "resume": "retry"}.get(command[1].lower(), command[1].lower())
        return identity, action, request
    if re.match(r"^/(?:task|implement)\s+", request, re.I):
        return identity, "task", re.sub(r"^/\w+\s+", "", request)
    if re.match(r"^(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?(?:bootstrap|implement|build|create|fix|add|update|remove|refactor|write)\b", request, re.I):
        return identity, "task", request
    return None


def allowed_path(name, settings):
    path = PurePosixPath(name)
    if (not name or name != str(path) or path.is_absolute() or "\\" in name or any(ord(c) < 32 for c in name)
            or any(part in {"..", ".git", ".pi", ".prolog", ".github", ".forgejo"}
                   or part.startswith(".env") for part in path.parts)
            or path.name in {".copilot", "AGENTS.md", "CLAUDE.md"}):
        return False
    return any(name.startswith(prefix) if prefix.endswith("/") else name == prefix
               for prefix in settings["task_allowed_paths"].split(","))


def ignored(path):
    return any(p in {"__pycache__", ".pytest_cache"} for p in path.parts) or path.suffix == ".pyc"


def snapshot_files(root):
    files, total = {}, 0
    for directory, directories, names in os.walk(root, followlinks=False):
        for name in directories + names:
            path = Path(directory) / name
            mode = path.lstat()
            if stat.S_ISLNK(mode.st_mode) or not (stat.S_ISREG(mode.st_mode) or stat.S_ISDIR(mode.st_mode)):
                raise ValueError("Special file in task workspace")
            if stat.S_ISREG(mode.st_mode) and mode.st_nlink != 1:
                raise ValueError("Hardlink in task workspace")
        for name in names:
            path = Path(directory) / name
            relative = path.relative_to(root)
            if ignored(relative):
                continue
            total += path.stat().st_size
            if path.stat().st_size > 4 * 1024 * 1024 or total > 64 * 1024 * 1024 or len(files) >= 10_000:
                raise ValueError("Task artifact exceeds limit")
            files[relative.as_posix()] = path.read_bytes()
    return files


def blob_sha(data):
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def file_operations(before, after, settings):
    changes, total = [], 0
    for name in sorted(set(before) | set(after)):
        if before.get(name) == after.get(name):
            continue
        data = after.get(name, b"")
        if not allowed_path(name, settings) or len(data) > 128 * 1024:
            raise ValueError("Task attempted a forbidden or oversized path")
        data.decode("utf-8")
        if b"\0" in data:
            raise ValueError("Binary task artifact")
        total += len(data)
        operation = {"path": name, "operation": "delete" if name not in after else "update" if name in before else "create"}
        if name in before:
            operation["sha"] = blob_sha(before[name])
        if name in after:
            operation["content"] = base64.b64encode(data).decode()
        changes.append(operation)
    if not changes or len(changes) > 32 or total > 1024 * 1024:
        raise ValueError("Empty or oversized task change set")
    return changes


def status_text(job):
    if not job:
        return "There is no implementation job for this issue. Use `@mara /task <request>`."
    text = f"Task `{job['id'][:12]}`: **{job['state']}**, revision {job['version']}."
    if job.get("phase"):
        text += " Phase: " + job["phase"] + "."
    if job.get("url"):
        text += "\n" + job["url"]
    if job.get("error"):
        text += "\n" + job["error"]
    return text


def poll_tasks(forge, repo, identities, store, *, armed=None):
    info = forge.call(f"repos/{repo}")
    if info.get("empty") or info.get("is_empty"):
        return
    branch = forge.call(f"repos/{repo}/branches/" + urllib.parse.quote(info["default_branch"], safe=""))
    settings = core.base_config(forge, repo, branch["commit"]["id"])
    if not settings.get("enabled") or not settings.get("tasks"):
        return
    for issue in forge.pages(f"repos/{repo}/issues?state=open&type=issues"):
        if issue.get("pull_request"):
            continue
        comments = list(forge.pages(f"repos/{repo}/issues/{issue['number']}/comments"))
        for event in [dict(issue, id="body")] + comments:
            actor = event["user"]["login"]
            if actor.lower() in identities or event["user"].get("bot"):
                continue
            parsed = invocation(event.get("body") or "", settings, identities)
            if not parsed:
                continue
            identity, action, request = parsed
            permission = forge.call(f"repos/{repo}/collaborators/{urllib.parse.quote(actor, safe='')}/permission")
            if permission.get("permission") not in {"write", "admin", "owner"}:
                continue
            event_key = hashlib.sha256(f"{repo}:{issue['number']}:{event['id']}:{event.get('body')}".encode()).hexdigest()
            if action == "task" and armed is not None and identity not in armed:
                disabled = "<!-- forgejo-copilot-disabled:" + event_key + " -->"
                if not any(disabled in comment["body"] for comment in comments):
                    identities[identity].call(f"repos/{repo}/issues/{issue['number']}/comments", {"body": disabled + "\nImplementation is not activated for this identity yet. The operator must configure its scoped task-publisher credential and worker. Your request has not been executed."})
                continue
            marker = "<!-- forgejo-copilot-control:" + event_key + " -->"
            if store.controlled(event_key):
                continue
            if any(marker in comment["body"] for comment in comments):
                store.controlled(event_key, record=True)
                continue
            try:
                if action == "task":
                    job, change = store.enqueue(repo, issue["number"], actor, identity, request, event_key)
                    text = status_text(job) + ("\nFollow-up recorded; the worker will use the revised request." if change == "steered" else "\nI will work in an isolated workspace and open a PR. Human review is required.")
                else:
                    job = store.latest(repo, issue["number"])
                    if job and action == "cancel" and job["state"] in ACTIVE:
                        store.update(job["id"], state="cancelled")
                    elif job and action == "retry" and job["state"] in {"blocked", "failed", "cancelled"}:
                        store.retry(job["id"])
                    text = status_text(store.get(job["id"]) if job else None)
                identities[identity].call(f"repos/{repo}/issues/{issue['number']}/comments", {"body": marker + "\n" + text})
                store.controlled(event_key, record=True)
            except ValueError as error:
                core.LOG.error("task admission denied %s #%s (%s)", repo, issue["number"], type(error).__name__)
                identities[identity].call(f"repos/{repo}/issues/{issue['number']}/comments", {"body": marker + "\nI could not admit this task: " + str(error) + ". No implementation run was started for this message."})
                store.controlled(event_key, record=True)
