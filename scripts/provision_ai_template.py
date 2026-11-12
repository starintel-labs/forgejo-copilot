#!/usr/bin/env python3
"""Publish a Forgejo template and optionally seed an explicitly empty test repo."""
import argparse
import base64
import json
import subprocess
from pathlib import Path

import pi_review_service as core

ROOT = Path(__file__).resolve().parent.parent


def tea(path, body=None, method=None):
    argv = ["tea", "api", path]
    if body is not None:
        argv += ["--data", json.dumps(body)]
    if method:
        argv += ["--method", method]
    result = subprocess.run(argv, check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def operations():
    folder = ROOT / "templates/ai-repo"
    return [{"operation": "create", "path": path.relative_to(folder).as_posix(),
             "content": base64.b64encode(path.read_bytes()).decode()}
            for path in sorted(folder.rglob("*")) if path.is_file()]


def initialize(repo, owner, bots):
    info = tea(f"repos/{repo}")
    if not info.get("empty", info.get("is_empty", False)):
        raise ValueError("Refusing to seed a non-empty repository")
    tea(f"repos/{repo}/contents", {"branch": "main", "message": "Initialize AI-enabled repository policy and tests", "files": operations()})
    for bot in bots:
        tea(f"repos/{repo}/collaborators/{bot}", {"permission": "write"}, "PUT")
    tea(f"repos/{repo}/branch_protections", {
        "branch_name": "main", "rule_name": "main", "apply_to_admins": True,
        "enable_push": True, "enable_push_whitelist": True, "push_whitelist_usernames": [owner],
        "required_approvals": 1, "dismiss_stale_approvals": True,
        "block_on_rejected_reviews": True, "block_on_outdated_branch": True,
        "enable_status_check": True, "status_check_contexts": ["copilot/tests"],
    })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", default="nsaspy/ai-enabled-repo-template")
    parser.add_argument("--seed-empty", help="Explicitly initialize this existing empty repository")
    args = parser.parse_args()
    owner, name = args.template.split("/")
    if not core.REPO.fullmatch(args.template):
        parser.error("Invalid template repository")
    # Never overwrite an existing repository; creation failure stays a visible error.
    user = tea("user")["login"]
    if user != owner:
        parser.error("Template owner must match the authenticated tea account")
    tea("user/repos", {"name": name, "private": True, "auto_init": False,
                      "default_branch": "main", "template": True,
                      "description": "AI-enabled Pi coding workflow: questions, reviews and human-gated implementation PRs"})
    initialize(args.template, owner, ["mara", "star"])
    print("Template:", tea(f"repos/{args.template}")["html_url"])
    if args.seed_empty:
        if not core.REPO.fullmatch(args.seed_empty) or args.seed_empty.split("/")[0] != owner:
            parser.error("Only an explicitly named empty repository owned by this user may be seeded")
        initialize(args.seed_empty, owner, ["mara", "star"])
        print("Initialized empty repository:", tea(f"repos/{args.seed_empty}")["html_url"])


if __name__ == "__main__":
    main()
