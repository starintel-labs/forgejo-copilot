import importlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
core = importlib.import_module("pi_review_service")
jobs = importlib.import_module("copilot_jobs")
worker = importlib.import_module("copilot_worker")


@unittest.skipUnless(os.environ.get("COPILOT_DOCKER_TESTS") == "1", "explicit real-Docker test gate")
class WorkerDocker(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source"
        (self.source / "src").mkdir(parents=True)
        (self.source / "src/example.txt").write_text("original\n")
        self.store = jobs.JobStore(self.root / "jobs.sqlite3")
        self.job, _ = self.store.enqueue("o/r", 1, "writer", "mara", "test", "docker-fixture")
        self.job = self.store.claim()

    def test_memory_workspace_export_and_secret_boundary(self):
        name = "copilot-task-docker-probe"
        self.addCleanup(lambda: subprocess.run(["docker", "rm", "-f", name], capture_output=True))
        subprocess.run(core.sandbox_command(name, self.source, task=True), check=True, capture_output=True)
        subprocess.run(["docker", "exec", name, "sh", "-c", "while [ ! -f /tmp/copilot-workspace-ready ]; do sleep 0.05; done"], check=True, timeout=10)
        probe = """
import os,socket
from pathlib import Path
assert os.getuid()==1000
assert not Path('/var/run/docker.sock').exists()
assert not Path('/run/secrets/openrouter').exists()
assert not any('TOKEN' in key or 'KEY' in key for key in os.environ)
Path('/workspace/src/example.txt').write_text('changed\\n')
try:Path('/input/src/example.txt').write_text('unsafe')
except OSError:pass
else:raise AssertionError('input writable')
try:socket.create_connection(('1.1.1.1',443),timeout=1)
except OSError:pass
else:raise AssertionError('general egress allowed')
"""
        subprocess.run(["docker", "exec", name, "python3", "-c", probe], check=True, timeout=10)
        exported = worker.export_workspace(name, self.root / "artifact")
        self.assertIn("src/example.txt", exported)
        self.assertEqual(exported["src/example.txt"], b"changed\n")
        self.assertEqual((self.source / "src/example.txt").read_text(), "original\n")

    def test_check_result_is_the_real_process_exit(self):
        settings = {"task_tests": "python3 -c 'print(\"claimed success\"); raise SystemExit(7)'"}
        code, output = worker.run_checks(self.store, self.job, self.source, settings)
        self.assertEqual(code, 7)
        self.assertIn("claimed success", output)


if __name__ == "__main__":
    unittest.main()
