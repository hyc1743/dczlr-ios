import ctypes as C
import math
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import PPArchive, XLInfo, XLLight, library


def encoded(value):
    if isinstance(value, str):
        value = value.encode("ascii")
    return bytes(byte ^ 255 for byte in value) + b"\xff"


def record(name=b"Light_00", target=b"z_Nz_light", values=None, tag=b"\x02\x01\x00\x00\x00"):
    if values is None:
        values = [float(index) for index in range(41)]
    return (struct.pack("<I", len(encoded(name))) + encoded(name) +
            struct.pack("<I", len(encoded(target))) + encoded(target) + tag +
            struct.pack("<41f", *values))


def fixture(count=2):
    return b"LLL\0" + bytes([count]) + b"".join(
        record(f"Light_{index:02d}", values=[index + value / 10 for value in range(41)])
        for index in range(count)
    )


class NativeXLTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def test_probe_and_light_view_preserve_encoded_spans_and_float_groups(self):
        data = fixture()
        info = XLInfo()
        self.assertEqual(self.lib.dc_xl_probe(data, len(data), C.byref(info)), 0)
        self.assertEqual((info.lights, info.parsed_bytes), (2, len(data)))
        view = XLLight()
        self.assertEqual(self.lib.dc_xl_light_at(data, len(data), 1, C.byref(view)), 0)
        self.assertEqual((view.name.length, view.target.length), (9, 11))
        self.assertEqual((view.kind, view.enabled, list(view.flags)), (2, 1, [0, 0, 0]))
        for actual, expected in zip(view.diffuse, [1.0, 1.1, 1.2, 1.3]):
            self.assertAlmostEqual(actual, expected, places=6)
        for actual, expected in zip(view.parameters, [3.0, 3.1, 3.2, 3.3, 3.4, 3.5]):
            self.assertAlmostEqual(actual, expected, places=6)
        for actual, expected in zip(view.transform, [3.5 + index / 10 for index in range(16)]):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_probe_rejects_invalid_count_strings_nonfinite_and_tail_atomically(self):
        valid = fixture()
        info = XLInfo(0xaaaaaaaa, 0xbbbbbbbbbb)
        before = bytes(info)
        invalid = [
            valid[:4] + b"\x00" + valid[5:],
            valid + b"\0",
            valid[:-1],
            valid[:5] + struct.pack("<I", 0) + valid[9:],
            valid[:5] + struct.pack("<I", 65) + valid[9:],
        ]
        nonfinite = bytearray(valid)
        # First record: header is 5 + 28 bytes, five tag bytes, then 41 floats.
        struct.pack_into("<f", nonfinite, 5 + 28 + 5, math.nan)
        invalid.append(bytes(nonfinite))
        for data in invalid:
            with self.subTest(length=len(data)):
                self.assertIn(self.lib.dc_xl_probe(data, len(data), C.byref(info)), (3, 4))
                self.assertEqual(bytes(info), before)

    def test_light_output_is_atomic_for_bad_index_and_alias(self):
        data = fixture()
        view = XLLight()
        C.memset(C.byref(view), 0xa5, C.sizeof(view))
        before = bytes(view)
        self.assertEqual(self.lib.dc_xl_light_at(data, len(data), 2, C.byref(view)), 4)
        self.assertEqual(bytes(view), before)
        source = C.create_string_buffer(data)
        self.assertEqual(self.lib.dc_xl_light_at(source, len(data), 0,
            C.cast(source, C.POINTER(XLLight))), 1)
        self.assertEqual(source.raw[:len(data)], data)

    @unittest.skipUnless((ROOT / "Data/RPP_07.pp").is_file(), "local game resources are not present")
    def test_all_local_xl_entries_match_the_native_profile(self):
        with PPArchive(ROOT / "Data/RPP_07.pp") as archive:
            seen = 0
            for index in range(archive.count):
                entry = archive.entry(index)
                if not entry.name_bytes.lower().endswith(b".xl"):
                    continue
                data = archive.read(index)
                info = XLInfo()
                self.assertEqual(self.lib.dc_xl_probe(data, len(data), C.byref(info)), 0,
                                 entry.name_bytes)
                self.assertEqual(info.lights, 4)
                for light_index in range(info.lights):
                    light = XLLight()
                    self.assertEqual(self.lib.dc_xl_light_at(data, len(data), light_index,
                                                             C.byref(light)), 0)
                    self.assertEqual(light.name.length, 9)
                    self.assertEqual(light.target.length, 11)
                    self.assertTrue(all(math.isfinite(value) for value in light.transform))
                seen += 1
            self.assertEqual(seen, 31)

    @unittest.skipUnless((ROOT / "Data/RPP_10.pp").is_file(), "local game resources are not present")
    def test_map_specific_xl_variants_use_the_same_record_decoder(self):
        with PPArchive(ROOT / "Data/RPP_10.pp") as archive:
            seen = 0
            for index in range(archive.count):
                entry = archive.entry(index)
                if not entry.name_bytes.lower().endswith(b".xl"):
                    continue
                data = archive.read(index)
                info, light = XLInfo(), XLLight()
                self.assertEqual(self.lib.dc_xl_probe(data, len(data), C.byref(info)), 0,
                                 entry.name_bytes)
                self.assertEqual(info.lights, 1)
                self.assertEqual(self.lib.dc_xl_light_at(data, len(data), 0, C.byref(light)), 0)
                self.assertIn(light.name.length, (9, 11))
                self.assertEqual(light.target.length, 1)
                seen += 1
            self.assertEqual(seen, 8)


if __name__ == "__main__":
    unittest.main()
