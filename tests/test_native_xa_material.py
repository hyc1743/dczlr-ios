import ctypes as C
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import library, XAMaterialTrack, MaterialKey, MaterialValue
from xa_cases import block, u32


def fixture():
    keys = struct.pack("<17fi17fi", *([0] * 17), -8, *([1] * 17), 8)
    tracks = [block(b"\xffname\0") + u32(2) + keys, block(b"") + u32(0)]
    return b"\1" + u32(2) + b"".join(tracks) + b"\0\0\0", keys


class NativeXAMaterialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def test_track_offsets_and_decoded_keys_preserve_bytes_and_canary(self):
        data, expected = fixture()
        track = XAMaterialTrack()
        self.assertEqual(self.lib.dc_xa_material_track_at(data, len(data), 0, C.byref(track)), 0)
        self.assertEqual((track.name_offset, track.name_length, track.keys_offset, track.key_count), (9, 6, 19, 2))
        output = (MaterialKey * 3)()
        C.memset(output, 0xa5, C.sizeof(output))
        sentinel = bytes(output[2])
        self.assertEqual(self.lib.dc_xa_load_material_keys(data, len(data), 0, output, 3), 0)
        self.assertEqual(bytes(output)[:144], expected)
        self.assertEqual(bytes(output[2]), sentinel)
        sampled, baseline = MaterialValue(), MaterialValue()
        self.assertEqual(self.lib.dc_material_sample(output, 2, C.byref(baseline), 0, C.byref(sampled)), 0)
        self.assertEqual(sampled.components[3], 0.5)

    def test_empty_track_and_absent_track_are_distinct(self):
        data, _ = fixture()
        track = XAMaterialTrack()
        self.assertEqual(self.lib.dc_xa_material_track_at(data, len(data), 1, C.byref(track)), 0)
        self.assertEqual((track.name_length, track.key_count), (0, 0))
        self.assertEqual(self.lib.dc_xa_load_material_keys(data, len(data), 1, None, 0), 0)
        before = bytes(track)
        self.assertEqual(self.lib.dc_xa_material_track_at(data, len(data), 2, C.byref(track)), 6)
        self.assertEqual(bytes(track), before)

    def test_full_file_validation_before_returning_early_track(self):
        data, _ = fixture()
        track, keys = XAMaterialTrack(), (MaterialKey * 2)()
        C.memset(C.byref(track), 0xa5, C.sizeof(track))
        C.memset(keys, 0xa5, C.sizeof(keys))
        before = bytes(track), bytes(keys)
        for length in range(len(data)):
            self.assertEqual(self.lib.dc_xa_material_track_at(data, length, 0, C.byref(track)), 3)
            self.assertEqual(self.lib.dc_xa_load_material_keys(data, length, 0, keys, 2), 3)
            self.assertEqual((bytes(track), bytes(keys)), before)
        self.assertEqual(self.lib.dc_xa_load_material_keys(data + b"\0", len(data) + 1, 0, keys, 2), 3)

    def test_capacity_null_and_overlap_errors_preserve_outputs(self):
        data, _ = fixture()
        source, keys = C.create_string_buffer(data), (MaterialKey * 2)()
        self.assertEqual(self.lib.dc_xa_load_material_keys(source, len(data), 0, keys, 1), 4)
        self.assertEqual(self.lib.dc_xa_load_material_keys(source, len(data), 0, None, 2), 1)
        before = source.raw
        self.assertEqual(self.lib.dc_xa_load_material_keys(source, len(data), 0, C.cast(source, C.POINTER(MaterialKey)), 2), 1)
        self.assertEqual(self.lib.dc_xa_material_track_at(source, len(data), 0, C.cast(source, C.POINTER(XAMaterialTrack))), 1)
        self.assertEqual(source.raw, before)


if __name__ == "__main__":
    unittest.main()
