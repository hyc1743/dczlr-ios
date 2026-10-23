"""Native parser boundary tests; original-game oracle coverage is separate."""
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import random
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from native_core import PPArchive, Source, READ_AT, library


def fixture(entries):
    names = b"".join(name.ljust(32, b"\0") for name, _ in entries)
    sizes = b"".join(struct.pack("<I", len(data)) for _, data in entries)
    payload = b"".join(data for _, data in entries)
    encode = lambda data: bytes((-v) & 255 for v in data)
    return struct.pack("<II", len(entries), len(payload)) + encode(names) + sizes + encode(payload)


class NativePPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def test_entry_reads_are_bounded_and_support_offsets(self):
        payload = fixture([(b"first.bin", bytes(range(256))), (b"second.bin", b"hello")])
        with PPArchive(payload) as archive:
            self.assertEqual(archive.count, 2)
            self.assertEqual(archive.entry(0).name_bytes, b"first.bin")
            self.assertEqual(archive.read(0), bytes(range(256)))
            self.assertEqual(archive.read(1, 1, 3), b"ell")
            self.assertEqual(archive.read(1, 5, 0), b"")
            for args in [(0, 250, 7), (1, 5, 1), (1, 6, 0), (1, -1, 1)]:
                with self.subTest(args=args), self.assertRaises(ValueError):
                    archive.read(*args)

    def test_recorded_original_decoder_vectors(self):
        path = Path(__file__).parent / "fixtures/pp-codec-original-vectors.json"
        source = json.loads(path.read_text(encoding="utf-8"))
        generator = random.Random(source["generator_seed"])
        for vector in source["generated_vectors"]:
            data = bytes(range(256)) if vector["label"] == "all-byte-values" else generator.randbytes(vector["length"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), vector["input_sha256"])
            output = C.create_string_buffer(data, len(data) + 1)
            self.assertEqual(self.lib.dc_pp_decode_bytes(output, len(data)), 0)
            self.assertEqual(hashlib.sha256(output.raw[:len(data)]).hexdigest(),
                             vector["original_output_sha256"], vector["label"])

    def test_file_source_and_full_width_name(self):
        name = b"a" * 32
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.pp"
            path.write_bytes(fixture([(name, b"\0\xff\x80")]))
            with PPArchive(path) as archive:
                self.assertEqual(archive.entry(0).name_bytes, name)
                self.assertEqual(archive.read(0), b"\0\xff\x80")

    def test_malformed_geometry_and_unknown_profiles_are_rejected(self):
        valid = fixture([(b"a", b"abc")])
        mutations = [valid[:7], valid[:-1], valid + b"extra",
            struct.pack("<II", 0xffffffff, 0), b"\x1f" * 64,
            struct.pack("<II", 1, 4) + valid[8:],
            valid[:40] + struct.pack("<I", 0xffffffff) + valid[44:]]
        for data in mutations:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                PPArchive(data)

    def test_io_failure_clears_output_and_empty_archive_is_valid(self):
        callback = READ_AT(lambda *_: 0)
        source = Source(None, 8, callback)
        handle = C.c_void_p(123)
        self.assertEqual(self.lib.dc_pp_open(C.byref(source), C.byref(handle)), 2)
        self.assertIsNone(handle.value)
        with PPArchive(struct.pack("<II", 0, 0)) as archive:
            self.assertEqual(archive.count, 0)
            with self.assertRaises(ValueError):
                archive.entry(0)

    def test_c_read_rejects_cross_entry_access_without_writing_output(self):
        with PPArchive(fixture([(b"a", b"abc"), (b"b", b"XYZ")])) as archive:
            result = C.create_string_buffer(b"sentinel")
            self.assertEqual(self.lib.dc_pp_read(archive._handle, 0, 2, result, 2), 4)
            self.assertEqual(result.value, b"sentinel")


if __name__ == "__main__":
    unittest.main()
