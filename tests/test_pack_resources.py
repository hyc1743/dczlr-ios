import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "pack_resources.py"

class PackResourcesTests(unittest.TestCase):
    def test_pack_verify_restore_crosses_part_and_file_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); data = root / "Data"; parts = root / "parts"; restored = root / "restored"
            (data / "sub").mkdir(parents=True)
            (data / "a.bin").write_bytes(bytes(range(100)))
            (data / "sub" / "b.bin").write_bytes(bytes(range(100, 256)))
            run = lambda *args: subprocess.run([sys.executable, str(TOOL), *args], check=True, capture_output=True, text=True)
            run("pack", "--data", str(data), "--out", str(parts), "--part-bytes", "128")
            run("verify", "--parts", str(parts), "--data", str(data))
            run("restore", "--parts", str(parts), "--out", str(restored))
            self.assertEqual((data / "a.bin").read_bytes(), (restored / "a.bin").read_bytes())
            self.assertEqual((data / "sub" / "b.bin").read_bytes(), (restored / "sub" / "b.bin").read_bytes())
            manifest = json.loads((parts / "DczlrData.manifest.json").read_text())
            self.assertTrue(all(part["size"] <= 128 for part in manifest["parts"]))

if __name__ == "__main__":
    unittest.main()
