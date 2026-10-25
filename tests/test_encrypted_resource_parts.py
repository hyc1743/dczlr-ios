from pathlib import Path
import hashlib
import json
import tempfile
import unittest

from tools.encrypted_resource_parts import pack_bundle, unpack_bundle


class EncryptedResourcePartsTests(unittest.TestCase):
    def test_roundtrip_and_authentication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parts = root / "parts"
            parts.mkdir()
            payload = b"resource-fixture" * 1000
            name = "DczlrData.part001.dczdata"
            (parts / name).write_bytes(payload)
            (parts / "DczlrData.manifest.json").write_text(json.dumps({
                "schema": 1, "format": "dczlr-resource-parts-v1", "game": "dczlr",
                "part_bytes": len(payload), "file_count": 1, "total_bytes": len(payload),
                "parts": [{"name": name, "size": len(payload),
                           "sha256": hashlib.sha256(payload).hexdigest()}],
            }), encoding="utf-8")
            key = bytes(range(32))
            bundle = root / "resources.dczenc"
            pack_bundle(parts, bundle, key)
            restored = root / "restored"
            unpack_bundle(bundle, restored, key)
            self.assertEqual((restored / name).read_bytes(), payload)
            corrupted = bytearray(bundle.read_bytes())
            corrupted[-1] ^= 1
            bundle.write_bytes(corrupted)
            with self.assertRaises(ValueError):
                unpack_bundle(bundle, root / "corrupt", key)


if __name__ == "__main__":
    unittest.main()
