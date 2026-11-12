import unittest
from pathlib import Path


class Scaffold(unittest.TestCase):
    def test_repository_has_policy_and_source(self):
        root = Path(__file__).resolve().parents[1]
        self.assertTrue((root / ".copilot").is_file())
        self.assertTrue((root / "src").is_dir())


if __name__ == "__main__":
    unittest.main()
