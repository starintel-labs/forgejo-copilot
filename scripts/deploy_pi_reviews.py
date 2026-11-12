#!/usr/bin/env python3
"""Deploy repository-owned service files without ever copying credentials into images."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent


def run(*argv):
    subprocess.run(argv, check=True)


def secret(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(value)


def provision_key(directory):
    target = directory / "forgejo-copilot-key"
    if target.exists():
        return target
    management = (directory / "management-key").read_text().strip()
    request = urllib.request.Request(
        "https://openrouter.ai/api/v1/keys",
        data=json.dumps({"name": "forgejo-copilot", "limit": 5, "limit_reset": "daily",
                         "include_byok_in_limit": True}).encode(),
        headers={"Authorization": "Bearer " + management, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    secret(target, data["key"])
    secret(directory / "forgejo-copilot-key.json", json.dumps(data["data"], indent=2))
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--forgejo-url", default="https://git.starintel.actor")
    parser.add_argument("--identity", action="append", default=[], metavar="USER=TOKEN_FILE")
    parser.add_argument("--review-as", help="Verified identity used for review comments")
    parser.add_argument("--openrouter-dir", type=Path, default=Path.home() / ".config/openrouter")
    args = parser.parse_args()
    if os.getuid() != 1000:
        parser.error("Current container UID policy requires host UID 1000")
    identities = {}
    for entry in args.identity:
        login, path = entry.split("=", 1)
        if login in identities:
            parser.error("Duplicate question identity")
        identities[login] = str(Path(path).resolve())
    from pi_review_service import load_identities
    load_identities(args.forgejo_url, identities)
    if args.review_as and args.review_as not in identities:
        parser.error("--review-as requires a matching --identity")
    key = provision_key(args.openrouter_dir)
    sys.path.insert(0, str(SOURCE / "deploy"))
    from gateway import check_key
    check_key(key.read_text().strip())
    install = Path.home() / ".local/share/forgejo-copilot"
    state = Path.home() / ".local/state/forgejo-copilot"
    config_dir = Path.home() / ".config/forgejo-copilot"
    for directory in (install, state, config_dir, state / "gateway"):
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o700)
    for folder in ("deploy", "scripts"):
        shutil.copytree(SOURCE / folder, install / folder, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
    config_file = config_dir / "service.json"
    config_file.write_text(json.dumps({"forgejo_url": args.forgejo_url,
                                     "token_file": str(args.token_file.resolve()),
                                     "identities": identities,
                                     "review_identity": args.review_as,
                                     "repos": args.repo, "state_dir": str(state)}, indent=2))
    config_file.chmod(0o600)
    run("docker", "build", "-f", str(SOURCE / "deploy/pi.Dockerfile"), "-t", "forgejo-copilot-pi:1.5.2", str(SOURCE))
    run("docker", "build", "-f", str(SOURCE / "deploy/gateway.Dockerfile"), "-t", "forgejo-copilot-gateway:1", str(SOURCE))
    subprocess.run(["systemctl", "--user", "stop", "forgejo-copilot.service"], check=True)
    network = "forgejo-copilot-sandbox"
    existing = subprocess.run(["docker", "network", "inspect", network], capture_output=True)
    if existing.returncode:
        run("docker", "network", "create", "--internal", "--opt",
            "com.docker.network.bridge.gateway_mode_ipv4=isolated", network)
    else:
        data = json.loads(existing.stdout)[0]
        if not data["Internal"] or data.get("Options", {}).get("com.docker.network.bridge.gateway_mode_ipv4") != "isolated":
            raise ValueError("Existing sandbox network is not host-isolated")
    name = "forgejo-copilot-gateway"
    if subprocess.run(["docker", "container", "inspect", name], capture_output=True).returncode == 0:
        run("docker", "rm", "-f", name)
    # Create without starting: both networks must be attached before any agent can use it.
    run("docker", "create", "--name", name, "--restart=unless-stopped",
        "--network", network, "--read-only", "--user", "1000:1000", "--cap-drop=ALL",
        "--security-opt=no-new-privileges:true", "--pids-limit=32", "--memory=256m", "--cpus=0.5",
        "--mount", f"type=bind,src={key.resolve()},dst=/run/secrets/openrouter,readonly",
        "--mount", f"type=bind,src={state / 'gateway'},dst=/state",
        "--env", "KEY_FILE=/run/secrets/openrouter", "--env", "BUDGET_DB=/state/budget.sqlite3",
        "forgejo-copilot-gateway:1")
    run("docker", "network", "connect", "bridge", name)
    run("docker", "start", name)
    unit_dir = Path.home() / ".config/systemd/user"
    unit_dir.mkdir(parents=True, exist_ok=True)
    unit = unit_dir / "forgejo-copilot.service"
    if unit.is_symlink():
        raise ValueError("Service owned by another configuration manager")
    text = (SOURCE / "deploy/forgejo-copilot.service.in").read_text()
    for key, value in {"PYTHON": sys.executable, "INSTALL": install, "CONFIG": config_file}.items():
        text = text.replace("@" + key + "@", str(value))
    unit.write_text(text)
    run("systemctl", "--user", "daemon-reload")
    run("systemctl", "--user", "enable", "forgejo-copilot.service")
    run("systemctl", "--user", "restart", "forgejo-copilot.service")
    print("Deployed Forgejo Pi review service with dedicated $5/day OpenRouter key")


if __name__ == "__main__":
    main()
