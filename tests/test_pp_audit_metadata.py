import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from audit_native_pp import audit


class ArchiveInventoryTests(unittest.TestCase):
    def test_format_inventory_counts_only_recognized_entries_and_exports_no_payload(self):
        entries = [(b"sample.BMP", b"abcdefg"), (b"empty.xx", b""), (b"sample.WAV", b"hi")]
        names = b"".join(name.ljust(32, b"\0") for name, _ in entries)
        payload = b"".join(data for _, data in entries)
        archive = (struct.pack("<II", len(entries), len(payload)) +
                   bytes((-value) & 255 for value in names) +
                   struct.pack("<3I", 7, 0, 2) + bytes((-value) & 255 for value in payload))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "known.pp").write_bytes(archive)
            (root / "unknown.pp").write_bytes(b"unknown")
            result = audit(root)
        self.assertEqual((result["recognized_archives"], result["total_archives"],
                          result["recognized_entries"]), (1, 2, 3))
        self.assertEqual(result["entry_formats"], {"bmp": 1, "wav": 1, "xx": 1})
        self.assertEqual(result["format_payload_bytes"], {"bmp": 7, "wav": 2, "xx": 0})
        self.assertEqual(result["game_playability"], "not_verified")
        self.assertNotIn("abcdefg", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
