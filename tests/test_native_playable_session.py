from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativePlayableSessionTests(unittest.TestCase):
    def test_user_facing_runner_completes_real_map_sequence(self):
        if not (ROOT / "Data" / "RPP_10.pp").is_file():
            self.skipTest("local original Data is not supplied")
        commands = "\n".join(["i"] * 8 + ["q", ""])
        result = subprocess.run(
            [sys.executable, str(ROOT / "tools/native_playable_session.py"),
             "--data", str(ROOT / "Data")],
            input=commands, text=True, capture_output=True, check=True,
        )
        output = result.stdout
        for selector in (0, 1, 3, 4, 5, 6, 7, 8):
            self.assertIn(f"map {selector} admitted", output)
        self.assertIn("chapter complete", output)

    def test_runner_requires_proximity_before_interaction(self):
        if not (ROOT / "Data" / "RPP_10.pp").is_file():
            self.skipTest("local original Data is not supplied")
        commands = ["m 100 0"] * 20 + ["i"] + ["m -100 0"] * 20 + ["i", "q"]
        result = subprocess.run(
            [sys.executable, str(ROOT / "tools/native_playable_session.py"),
             "--data", str(ROOT / "Data")],
            input="\n".join(commands) + "\n", text=True,
            capture_output=True, check=True,
        )
        self.assertIn("interaction unavailable", result.stdout)
        self.assertIn("map 1 admitted", result.stdout)


if __name__ == "__main__":
    unittest.main()
