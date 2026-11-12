#!/usr/bin/env python3
"""Live checks: security policy, private fixture review, and provider-side cap. No secrets in output."""
import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from pi_review_service import Forgejo, MARKER, load_identities, sandbox_command


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", type=int, default=1)
    parser.add_argument("--exercise-restart", action="store_true")
    parser.add_argument("--question-issue", type=int)
    args = parser.parse_args()
    settings = json.loads((Path.home() / ".config/forgejo-copilot/service.json").read_text())
    if args.exercise_restart:
        subprocess.run(["systemctl", "--user", "stop", "forgejo-copilot.service"], check=True)
        try:
            subprocess.run([sys.executable, str(ROOT / "scripts/pi_review_service.py"),
                            "--config", str(Path.home() / ".config/forgejo-copilot/service.json"),
                            "--once"], check=True, timeout=60)
        finally:
            subprocess.run(["systemctl", "--user", "start", "forgejo-copilot.service"], check=True)
    forge = Forgejo(settings["forgejo_url"], Path(settings["token_file"]).read_text().strip())
    for login, api in load_identities(settings["forgejo_url"], settings.get("identities", {})).items():
        try:
            api.call("admin/users?limit=1")
        except urllib.error.HTTPError as error:
            assert error.code == 403, "unexpected admin-scope probe failure"
            error.close()
        else:
            raise AssertionError("Question identity has unexpected admin API authority: " + login)
    subprocess.run(["systemctl", "--user", "is-active", "--quiet", "forgejo-copilot.service"], check=True)
    network = json.loads(subprocess.check_output(["docker", "network", "inspect", "forgejo-copilot-sandbox"]))[0]
    assert network["Internal"]
    assert network["Options"]["com.docker.network.bridge.gateway_mode_ipv4"] == "isolated"
    assert all(not item.get("Gateway") for item in network["IPAM"]["Config"]), "isolated bridge must have no host address"
    gateway = json.loads(subprocess.check_output(["docker", "inspect", "forgejo-copilot-gateway"]))[0]
    assert gateway["State"]["Running"]
    assert not gateway["HostConfig"]["PortBindings"]
    assert gateway["HostConfig"]["ReadonlyRootfs"]
    assert gateway["Config"]["User"] == "1000:1000"
    assert not gateway["NetworkSettings"]["Networks"]["forgejo-copilot-sandbox"]["Gateway"]
    bridge_host = gateway["NetworkSettings"]["Networks"]["bridge"]["Gateway"]
    with tempfile.TemporaryDirectory(dir=settings["state_dir"]) as directory:
        Path(directory).chmod(0o755)
        probe = '''
import os,socket,urllib.request,urllib.error
assert os.getuid()==1000
assert not os.path.exists('/var/run/docker.sock')
assert not os.path.exists('/run/secrets/openrouter')
assert not any('KEY' in k or 'TOKEN' in k for k in os.environ)
for destination in [('1.1.1.1',443),('172.17.0.1',80)]:
    try:s=socket.create_connection(destination,timeout=2)
    except OSError:pass
    else:s.close();raise AssertionError('egress allowed')
try:socket.getaddrinfo('example.com',443)
except OSError:pass
else:raise AssertionError('external DNS forwarding allowed')
try:open('/workspace/should-fail','w')
except OSError:pass
else:raise AssertionError('workspace writable')
try:open('/etc/should-fail','w')
except OSError:pass
else:raise AssertionError('root writable')
try:
    urllib.request.urlopen(urllib.request.Request('http://forgejo-copilot-gateway:8080/v1/chat/completions',data=b'{}',headers={'Content-Type':'application/json'}),timeout=10)
except urllib.error.HTTPError as e:assert e.code==429
else:raise AssertionError('gateway accepts arbitrary models')
print('sandbox: uid, secrets, sockets, egress, readonly mounts, gateway policy passed')
'''
        probe = probe.replace("('172.17.0.1',80)", repr((bridge_host, 8080)))
        argv = sandbox_command("copilot-security-probe", Path(directory))
        argv[-1:-1] = ["--entrypoint", "python3"]
        subprocess.run(argv + ["-c", probe], check=True, timeout=30)
    spec = importlib.util.spec_from_file_location("gateway", ROOT / "deploy/gateway.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.check_key((Path.home() / ".config/openrouter/forgejo-copilot-key").read_text().strip())
    print("OpenRouter: dedicated $5/day cap including BYOK verified")
    comments = list(forge.pages(f"repos/{args.repo}/issues/{args.pr}/comments"))
    reviews = [c for c in comments if MARKER in c["body"]]
    pull = forge.call(f"repos/{args.repo}/pulls/{args.pr}")
    key = hashlib.sha256(f"{args.repo}:{args.pr}:{pull['head']['sha']}:{pull['base']['sha']}:auto".encode()).hexdigest()
    current_reviews = [c for c in reviews if MARKER + key + " -->" in c["body"]]
    assert len(current_reviews) == 1, f"expected one review of current commits, found {len(current_reviews)}"
    assert len({c["body"].split("-->", 1)[0] for c in reviews}) == len(reviews), "duplicate review marker"
    body = current_reviews[0]["body"]
    assert "calculator.py" in body and ("zero" in body.lower() or "empty" in body.lower())
    assert "Tools observed:" in body and "read" in body
    if settings.get("review_identity"):
        assert current_reviews[0]["user"]["login"] == settings["review_identity"]
    print("live fixture: bug found, tool execution observed, one review per head/base commit pair")
    if args.question_issue:
        replies = list(forge.pages(f"repos/{args.repo}/issues/{args.question_issue}/comments"))
        for login in ("mara", "star"):
            answers = [c for c in replies if c["user"]["login"] == login and "<!-- forgejo-copilot-answer:" in c["body"]]
            assert len(answers) == 1, f"expected one real {login} answer, found {len(answers)}"
            assert "calculator.py" in answers[0]["body"] and "read" in answers[0]["body"]
        print("questions: real Mara and Star each posted one grounded answer with observed tools")
    if args.exercise_restart:
        print("restart: persisted ledger prevented a duplicate review during a fresh one-shot poll")
    print(f"{settings['forgejo_url']}/{args.repo}/pulls/{args.pr}")


if __name__ == "__main__":
    main()
