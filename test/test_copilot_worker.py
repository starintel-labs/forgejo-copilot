import importlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
worker = importlib.import_module("copilot_worker")
jobs = importlib.import_module("copilot_jobs")
core = importlib.import_module("pi_review_service")


def archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as zipped:
        for name, data in files.items():
            zipped.writestr("repo/" + name, data)
    return output.getvalue()


class Worker(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.store = jobs.JobStore(self.root / "jobs.sqlite3")
        self.job, _ = self.store.enqueue("o/r", 1, "writer", "mara", "Build actor", "one")
        self.job = self.store.claim()
        self.settings = core.config("enabled: true\ntasks: true\ntask_tests: python3 -m unittest")

    def test_cancel_and_steering_invalidate_inflight_work(self):
        self.store.enqueue("o/r", 1, "writer", "mara", "Add tests", "two")
        with self.assertRaises(worker.Steered):
            worker.current_job(self.store, self.job)
        self.store.update(self.job["id"], state="cancelled")
        with self.assertRaises(worker.Cancelled):
            worker.current_job(self.store, self.job)

    def test_partial_workspace_survives_provider_failure(self):
        target = self.root / "artifact"
        def export(_name, destination):
            destination.mkdir()
            (destination / "partial.txt").write_text("retained")
        with patch.object(worker.subprocess, "run"), patch.object(worker, "run_process", side_effect=ValueError("provider")), patch.object(worker, "export_workspace", side_effect=export):
            with self.assertRaisesRegex(ValueError, "provider"):
                worker.implement(None, self.store, self.job, self.root, target, "prompt")
        self.assertEqual((target / "partial.txt").read_text(), "retained")
        self.assertIsNone(self.store.get(self.job["id"])["container"])

    def test_check_timeout_keeps_current_output_and_explicit_failure(self):
        with patch.object(worker, "run_process", side_effect=worker.ProcessTimeout("current test started")), patch.object(worker.subprocess, "run") as cleanup:
            code, output = worker.run_checks(self.store, self.job, self.root, self.settings)
        self.assertEqual(code, 124)
        self.assertIn("current test started", output)
        self.assertIn("deadline exceeded", output)
        cleanup.assert_called_once()

    def test_real_process_timeout_captures_output(self):
        with self.assertRaises(worker.ProcessTimeout) as result:
            worker.run_process([sys.executable, "-u", "-c", "import time; print('started'); time.sleep(30)"], self.store, self.job, timeout=0.01)
        self.assertIn("started", result.exception.output)

    def test_revoked_authority_fails_before_execution(self):
        class Forge:
            def call(inner, path):
                if path.endswith("/permission"):
                    return {"permission": "read"}
                if "/branches/" in path:
                    return {"commit": {"id": "base"}}
                if "/issues/" in path:
                    return {"state": "open"}
                return {"default_branch": "main"}
        with patch.object(core, "base_config", return_value=self.settings):
            with self.assertRaisesRegex(ValueError, "revoked"):
                worker.admitted_policy(Forge(), self.store, self.job)

    def publication(self, *, remote_files=None, remote_sha="base", branch="copilot/test"):
        before = {"src/code.py": b"before\n"}
        after = {"src/code.py": b"after\n"}
        self.store.update(self.job["id"], branch=branch, base_ref="main", base_sha="base",
                          artifact_hash=worker.artifact_hash(after), result=json.dumps({"summary": "Implemented", "tools": ["read"]}))
        job = self.store.get(self.job["id"])
        class Forge:
            posted = []
            sha = remote_sha
            url = "https://forge.invalid"
            def call(inner, path, body=None, **kwargs):
                if body is not None:
                    inner.posted.append((path, body))
                    if path.endswith("/contents"):
                        inner.sha = "published"
                    return {"number": 2, "html_url": "https://forge.invalid/o/r/pulls/2"}
                if "/branches/" in path:
                    return {"commit": {"id": inner.sha}}
                if "/archive/" in path:
                    return archive(remote_files if remote_files is not None else after)
                raise AssertionError(path)
            def pages(inner, path):
                return []
        forge = Forge()
        return forge, job, before, after

    def test_publisher_checks_artifact_before_success_status_and_pr(self):
        forge, job, before, after = self.publication()
        worker.publish(forge, forge, self.store, job, before, after, self.settings)
        self.assertEqual([p.rsplit("/", 1)[-1] for p, _ in forge.posted], ["contents", "published", "pulls"])
        self.assertEqual(forge.posted[1][1]["context"], "copilot/tests")

    def test_publisher_rejects_wrong_artifact_and_protected_branch(self):
        for options in ({"remote_files": {"src/code.py": b"tampered"}}, {"branch": "main"}):
            forge, job, before, after = self.publication(**options)
            with self.assertRaises(ValueError):
                worker.publish(forge, forge, self.store, job, before, after, self.settings)
            self.assertFalse(any("/statuses/" in path or path.endswith("/pulls") for path, _ in forge.posted))

    def test_uncertain_commit_recovery_never_rewrites_the_branch(self):
        forge, job, before, after = self.publication(remote_sha="published")
        worker.publish(forge, forge, self.store, job, before, after, self.settings)
        self.assertFalse(any(path.endswith("/contents") for path, _ in forge.posted))
        forge, job, before, after = self.publication(remote_sha="unexpected", remote_files=before)
        with self.assertRaisesRegex(ValueError, "changed unexpectedly"):
            worker.publish(forge, forge, self.store, job, before, after, self.settings)
        self.assertEqual(forge.posted, [])


if __name__ == "__main__":
    unittest.main()
