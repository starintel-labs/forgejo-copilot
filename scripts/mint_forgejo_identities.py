#!/usr/bin/env python3
"""Explicit admin operation: mint scoped tokens for existing users; never reset passwords."""
import argparse
import os
import re
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from pi_review_service import load_identities


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True, help="SSH administrator target")
    parser.add_argument("--jump")
    parser.add_argument("--user", action="append", required=True)
    parser.add_argument("--forgejo-url", default="https://git.starintel.actor")
    parser.add_argument("--output-dir", type=Path, default=Path.home() / ".config/forgejo-copilot")
    parser.add_argument("--task-writer", action="store_true", help="Mint separate repository-write tokens for the trusted publisher")
    args = parser.parse_args()
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    if args.jump:
        ssh += ["-J", args.jump]
    ssh.append(args.host)
    metadata = subprocess.check_output(ssh + ["systemctl show forgejo.service -p ExecStart --value"], text=True, timeout=30)
    match = re.search(r"path=(/nix/store/[^ ;]+/bin/forgejo)\s*;", metadata)
    if not match:
        raise RuntimeError("Cannot resolve deployed Forgejo CLI from service metadata")
    args.output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    files = {}
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for login in args.user:
        if not re.fullmatch(r"[a-z0-9_-]+", login):
            parser.error("Invalid account name")
        path = args.output_dir / (login + ("-task-token" if args.task_writer else "-token"))
        if not path.exists():
            command = ["runuser", "-u", "forgejo", "--", "env", "FORGEJO_WORK_DIR=/var/lib/forgejo",
                       "FORGEJO_CUSTOM=/var/lib/forgejo/custom", match[1], "--config",
                       "/var/lib/forgejo/custom/conf/app.ini", "admin", "user", "generate-access-token",
                       "--username", login, "--token-name", ("forgejo-copilot-tasks-" if args.task_writer else "forgejo-copilot-questions-") + stamp,
                       "--scopes", "write:repository,write:issue,read:user" if args.task_writer else "read:repository,write:issue,read:user", "--raw"]
            result = subprocess.run(ssh + [shlex.join(command)], capture_output=True, text=True, timeout=30, check=True)
            token = result.stdout.strip()
            if not re.fullmatch(r"[a-fA-F0-9]{40,128}", token):
                raise RuntimeError("Unexpected mint output; secret not displayed")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as output:
                output.write(token)
        files[login] = str(path)
    load_identities(args.forgejo_url, files)
    print("Verified real Forgejo token owners: " + ", ".join(files))


if __name__ == "__main__":
    main()
