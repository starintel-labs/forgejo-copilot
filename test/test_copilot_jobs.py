import importlib
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
core = importlib.import_module("pi_review_service")
jobs = importlib.import_module("copilot_jobs")


class Jobs(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.store = jobs.JobStore(self.root / "jobs.sqlite3")
        self.settings = core.config("enabled: true\ntasks: true\ntask_tests: python3 -B -m unittest discover -s tests -v")

    def test_natural_and_explicit_routing(self):
        identities = {"mara": object(), "star": object()}
        self.assertEqual(jobs.invocation("@mara Bootstrap an actor", self.settings, identities), ("mara", "task", "Bootstrap an actor"))
        self.assertEqual(jobs.invocation("@star /task fix the bug", self.settings, identities), ("star", "task", "fix the bug"))
        self.assertEqual(jobs.invocation("@mara status", self.settings, identities)[1], "status")
        for text in ("@mara why does this fail?", "@marathon fix this", "> @mara fix this", "```\n@mara fix this\n```", "Thanks @mara"):
            self.assertIsNone(jobs.invocation(text, self.settings, identities))
        self.assertIn("-B", self.settings["task_tests"])

    def test_event_idempotency_and_steering(self):
        first, action = self.store.enqueue("o/r", 1, "writer", "mara", "Build actor", "event-1")
        self.assertEqual(action, "new")
        same, action = self.store.enqueue("o/r", 1, "writer", "mara", "Build actor", "event-1")
        self.assertEqual((same["id"], action), (first["id"], "seen"))
        claimed = self.store.claim()
        self.assertEqual(claimed["state"], "running")
        steered, action = self.store.enqueue("o/r", 1, "writer", "mara", "Use an adapter", "event-2")
        self.assertEqual((steered["id"], action, steered["version"]), (first["id"], "steered", 2))
        self.assertIn("Use an adapter", steered["request"])
        self.assertIsNone(self.store.claim())

    def test_restart_cancel_and_retry(self):
        job, _ = self.store.enqueue("o/r", 1, "writer", "mara", "Fix", "one")
        self.store.claim()
        restarted = jobs.JobStore(self.root / "jobs.sqlite3")
        restarted.recover()
        self.assertEqual(restarted.claim()["id"], job["id"])
        restarted.update(job["id"], state="cancelled")
        self.assertIsNone(restarted.claim())
        restarted.retry(job["id"])
        retried = restarted.claim()
        self.assertEqual(retried["id"], job["id"])
        self.assertEqual(retried["version"], 2)
        self.assertIsNone(retried["error"])
        restarted.retry(job["id"])
        self.assertEqual(restarted.get(job["id"])["version"], 2)

    def test_writes_are_strictly_scoped(self):
        settings = dict(self.settings, task_allowed_paths="src/,tests/,README.md")
        self.assertTrue(jobs.allowed_path("src/example.py", settings))
        for name in ("../secret", "/etc/passwd", "src/../.copilot", ".copilot", ".forgejo/workflows/a.yml", "src/.env", "src/.pi/config.json", "src/x\\y", "src/.git/hooks/pre-commit"):
            self.assertFalse(jobs.allowed_path(name, settings), name)
        (self.root / "src").mkdir()
        (self.root / "src/a.py").write_text("print(1)\n")
        self.assertEqual(jobs.snapshot_files(self.root)["src/a.py"], b"print(1)\n")
        (self.root / "src/link").symlink_to("/etc/passwd")
        with self.assertRaises(ValueError):
            jobs.snapshot_files(self.root)

    def test_policy_and_diff(self):
        before = {"src/a.py": b"before\n", ".copilot": b"enabled: true\n"}
        after = dict(before, **{"src/a.py": b"after\n"})
        changes = jobs.file_operations(before, after, self.settings)
        self.assertEqual(changes[0]["operation"], "update")
        self.assertEqual(changes[0]["sha"], jobs.blob_sha(b"before\n"))
        after[".copilot"] = b"enabled: false\n"
        with self.assertRaises(ValueError):
            jobs.file_operations(before, after, self.settings)

    def test_writable_workspace_is_memory_bounded(self):
        command = core.sandbox_command("task-test", self.root, task=True)
        self.assertIn("--detach", command)
        self.assertIn(f"type=bind,src={self.root},dst=/input,readonly", command)
        self.assertIn("/workspace:rw,nosuid,nodev,size=128m,mode=1777", command)
        self.assertNotIn(f"type=bind,src={self.root},dst=/workspace", command)


if __name__ == "__main__":
    unittest.main()
