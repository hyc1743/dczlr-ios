import ctypes as C
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import EyeNeckInfo, EyeNeckSpan, PPArchive, library


def encoded(value):
    return bytes(byte ^ 255 for byte in value)


def fixture(kind):
    if kind == "eyes":
        header = b"\0" + bytes([9]) + encoded(b"a_Np_me_R") + bytes([9]) + encoded(b"a_Np_me_L")
        return header + (5).to_bytes(4, "little") + b"\x04pvu" + bytes(326 - 25 - 4)
    header = b"\0" + bytes([10]) + encoded(b"a_Kp_kubi2")
    return header + (3).to_bytes(4, "little") + b"\x04pvu" + bytes(197 - 16 - 4)


class NativeEyeNeckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    @unittest.skipUnless((ROOT / "Data/RPP_04.pp").is_file(),
                         "local game resources are not present")
    def test_real_rpp04_profiles_and_target_spans(self):
        with PPArchive(ROOT / "Data/RPP_04.pp") as archive:
            for index, expected_kind, expected_targets, expected_records in (
                (0, 1, 2, 5), (1, 2, 1, 3), (2, 1, 2, 5),
                (3, 2, 1, 3), (4, 1, 2, 5), (5, 2, 1, 3)):
                data = archive.read(index)
                info = EyeNeckInfo()
                self.assertEqual(self.lib.dc_eyeneck_probe(data, len(data), C.byref(info)), 0)
                self.assertEqual((info.kind, info.targets, info.records, info.parsed_bytes),
                                 (expected_kind, expected_targets, expected_records, len(data)))
                for target in range(info.targets):
                    span = EyeNeckSpan()
                    self.assertEqual(self.lib.dc_eyeneck_target_at(data, len(data), target, C.byref(span)), 0)
                    self.assertNotEqual(data[span.offset + span.length - 1], 0)

    def test_profile_admission_and_output_are_atomic(self):
        for kind in ("eyes", "neck"):
            data = fixture(kind)
            info = EyeNeckInfo(0xaaaaaaaa, 0xbbbbbbbb, 0xcccccccc, 0xdddddddd, 0xeeeeeeee)
            before = bytes(info)
            self.assertEqual(self.lib.dc_eyeneck_probe(data, len(data), C.byref(info)), 0)
            self.assertNotEqual(bytes(info), before)
            span = EyeNeckSpan()
            self.assertEqual(self.lib.dc_eyeneck_target_at(data, len(data), info.targets, C.byref(span)), 4)
            bad = data[:-1]
            snapshot = bytes(info)
            self.assertEqual(self.lib.dc_eyeneck_probe(bad, len(bad), C.byref(info)), 3)
            self.assertEqual(bytes(info), snapshot)

    def test_aliasing_and_wrong_magic_are_rejected(self):
        data = fixture("eyes")
        source = C.create_string_buffer(data)
        self.assertEqual(self.lib.dc_eyeneck_probe(source, len(data), C.cast(source, C.POINTER(EyeNeckInfo))), 1)
        corrupted = b"x" + data[1:]
        info = EyeNeckInfo()
        self.assertEqual(self.lib.dc_eyeneck_probe(corrupted, len(corrupted), C.byref(info)), 3)


if __name__ == "__main__":
    unittest.main()
