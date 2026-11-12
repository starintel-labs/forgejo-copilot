#!/usr/bin/env python3
"""Verify delivery of a specific current-head manual review without printing secrets."""
import argparse
import hashlib
import json
from pathlib import Path

from pi_review_service import Forgejo, MARKER, read_token


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--comment", type=int, required=True)
    parser.add_argument("--identity", default="mara")
    args = parser.parse_args()
    settings = json.loads((Path.home() / ".config/forgejo-copilot/service.json").read_text())
    assert args.repo in settings["repos"], "Repository is not enrolled"
    api = Forgejo(settings["forgejo_url"], read_token(settings["token_file"]))
    pull = api.call(f"repos/{args.repo}/pulls/{args.pr}")
    key = hashlib.sha256(f"{args.repo}:{args.pr}:{pull['head']['sha']}:{pull['base']['sha']}:{args.comment}".encode()).hexdigest()
    marker = MARKER + key + " -->"
    comments = list(api.pages(f"repos/{args.repo}/issues/{args.pr}/comments"))
    matches = [comment for comment in comments if marker in comment["body"]]
    assert len(matches) == 1, f"Expected one current-head review, found {len(matches)}"
    assert matches[0]["user"]["login"] == args.identity
    assert "Tools observed:" in matches[0]["body"]
    print("Verified one real", args.identity, "review for", args.repo, "PR", args.pr)
    print(matches[0]["html_url"])


if __name__ == "__main__":
    main()
