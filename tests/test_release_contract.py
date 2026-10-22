import json
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from validate_release_contract import validate

class ReleaseContractTests(unittest.TestCase):
    def test_repository_contract(self):
        result = validate(ROOT)
        self.assertEqual(result["parts"], 3)
        self.assertLessEqual(result["max_part_bytes"], 1_000_000_000)
        self.assertTrue(result["release_workflow"])

if __name__ == "__main__":
    unittest.main()
