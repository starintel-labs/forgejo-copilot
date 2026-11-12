#!/usr/bin/env python3
"""Observe a real issue-to-PR result; optionally wait on filesystem events, not polling."""
import argparse
import ctypes
import json
import select
import sqlite3
import time
from contextlib import closing
from pathlib import Path

import pi_review_service as core
from copilot_jobs import JobStore, snapshot_files
from copilot_worker import artifact_hash, run_checks


def latest(path, repo, issue):
    if not path.exists():
        return None
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        row = db.execute("SELECT * FROM jobs WHERE repo=? AND issue=? ORDER BY created DESC LIMIT 1", (repo, issue)).fetchone()
        return dict(row) if row else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--issue", type=int, required=True)
    parser.add_argument("--wait", type=int, default=0, help="Maximum event-driven wait in seconds")
    parser.add_argument("--rerun-checks", action="store_true")
    parser.add_argument("--after", type=float, default=0, help="Ignore terminal states older than this request timestamp")
    args = parser.parse_args()
    settings = json.loads((Path.home() / ".config/forgejo-copilot/service.json").read_text())
    root = Path(settings["state_dir"])
    path = root / "jobs.sqlite3"
    libc = ctypes.CDLL(None, use_errno=True)
    descriptor = libc.inotify_init1(0x80000)
    if descriptor < 0 or libc.inotify_add_watch(descriptor, str(root).encode(), 0x8 | 0x80 | 0x100) < 0:
        raise OSError("Cannot observe task state directory")
    deadline = time.monotonic() + args.wait
    try:
        while True:
            job = latest(path, args.repo, args.issue)
            if job and job["updated"] >= args.after and job["state"] in {"ready", "blocked", "cancelled", "failed"}:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
                raise AssertionError("Implementation has not reached a terminal state")
            import os
            os.read(descriptor, 65536)
    finally:
        import os
        os.close(descriptor)
    assert job["state"] == "ready", f"Task {job['state']}: {job.get('error')}"
    assert job["test_exit"] == 0 and job["artifact_hash"]
    assert job["branch"].startswith("copilot/") and job["base_ref"] != job["branch"]
    api = core.Forgejo(settings["forgejo_url"], core.read_token(settings["token_file"]))
    pull = api.call(f"repos/{args.repo}/pulls/{job['pr']}")
    assert pull["state"] == "open" and pull["user"]["login"] == job["identity"]
    assert pull["head"]["ref"] == job["branch"] and pull["base"]["ref"] == job["base_ref"]
    status = api.call(f"repos/{args.repo}/commits/{pull['head']['sha']}/status")
    assert any(s["context"] == "copilot/tests" and s["status"] == "success" for s in status.get("statuses") or [])
    workspace = root / "jobs" / job["id"] / "workspace"
    assert artifact_hash(snapshot_files(workspace)) == job["artifact_hash"]
    if args.rerun_checks:
        policy = core.base_config(api, args.repo, job["policy_sha"])
        code, output = run_checks(JobStore(path), job, workspace, policy, settings.get("task_references", {}).get(args.repo))
        print(output[-6000:])
        assert code == 0, "Independent rerun of the actual checks failed"
    print("Verified real", job["identity"], "implementation PR, scoped branch, artifact digest and actual successful check status")
    print(pull["html_url"])


if __name__ == "__main__":
    main()
