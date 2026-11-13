import ctypes as C
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import (
    EyeNeckController,
    EyeNeckInfo,
    EyeNeckSlot,
    EyeNeckSpan,
    EyeNeckTremorState,
    Matrix,
    PPArchive,
    SpringNodeState,
    library,
)


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

    @unittest.skipUnless((ROOT / "Data/RPP_04.pp").is_file(),
                         "local game resources are not present")
    def test_real_rpp04_slots_lookat_slerp_tremor_and_springs(self):
        with PPArchive(ROOT / "Data/RPP_04.pp") as archive:
            eyes_data = archive.read(0)
            neck_data = archive.read(1)
        slot0 = EyeNeckSlot()
        slot1 = EyeNeckSlot()
        self.assertEqual(self.lib.dc_eyeneck_slot_at(eyes_data, len(eyes_data), 0, C.byref(slot0)), 0)
        self.assertEqual(self.lib.dc_eyeneck_slot_at(eyes_data, len(eyes_data), 1, C.byref(slot1)), 0)
        self.assertEqual(slot0.slot_index, 0)
        self.assertEqual(slot1.slot_index, 1)
        self.assertEqual(slot1.behavior_mode, 7)
        self.assertEqual(slot1.interp_ms, 500)
        self.assertAlmostEqual(slot1.max_yaw_rad, 0.20944, places=3)

        neck_slot = EyeNeckSlot()
        self.assertEqual(self.lib.dc_eyeneck_slot_at(neck_data, len(neck_data), 1, C.byref(neck_slot)), 0)
        self.assertEqual((neck_slot.slot_index, neck_slot.behavior_mode), (3, 7))
        self.assertAlmostEqual(neck_slot.weight, 0.3, places=3)

        ctrl_l = EyeNeckController()
        ctrl_r = EyeNeckController()
        self.lib.dc_eyeneck_controller_init(C.byref(ctrl_l))
        self.lib.dc_eyeneck_controller_init(C.byref(ctrl_r))
        self.lib.dc_eyeneck_controller_set_slot(C.byref(ctrl_l), C.byref(slot1))
        self.lib.dc_eyeneck_controller_set_slot(C.byref(ctrl_r), C.byref(slot1))

        ident = Matrix((1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1))
        target = (C.c_float * 3)(2.0, 1.0, 10.0)
        out_l, out_r = Matrix(), Matrix()
        self.assertEqual(self.lib.dc_eyeneck_controller_step(
            C.byref(ctrl_l), C.byref(ident), target, 0.5, 250, C.byref(out_l)), 0)
        halfway_yaw = out_l.values[8]
        self.assertGreater(halfway_yaw, 0.01)
        self.assertEqual(self.lib.dc_eyeneck_controller_step(
            C.byref(ctrl_l), C.byref(ident), target, 0.5, 250, C.byref(out_l)), 0)
        self.assertEqual(self.lib.dc_eyeneck_controller_step(
            C.byref(ctrl_r), C.byref(ident), target, -0.5, 500, C.byref(out_r)), 0)
        self.assertGreater(out_l.values[8], halfway_yaw)
        # Left eye (+0.5 convergence) turns slightly further inward (+X) than right eye (-0.5)
        self.assertGreater(out_l.values[8], out_r.values[8])

        tremor = EyeNeckTremorState()
        self.lib.dc_eyeneck_tremor_init(C.byref(tremor))
        tm1, tm2 = Matrix(), Matrix()
        self.assertEqual(self.lib.dc_eyeneck_tremor_step(C.byref(tremor), 20, 99.0, 0, C.byref(tm1)), 0)
        self.assertEqual(self.lib.dc_eyeneck_tremor_step(C.byref(tremor), 20, 99.0, 0, C.byref(tm2)), 0)
        self.assertGreater(tm1.values[8], 0.04)
        self.assertLess(tm2.values[8], -0.04)

        spring = SpringNodeState()
        self.lib.dc_spring_node_init(C.byref(spring))
        sm = Matrix()
        self.assertEqual(self.lib.dc_spring_breast_step(C.byref(spring), C.byref(ident), 16, 0, 0, C.byref(sm)), 0)
        moved = Matrix((1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.8, 1.2, 0.0, 1))
        self.assertEqual(self.lib.dc_spring_breast_step(C.byref(spring), C.byref(moved), 16, 0, 0, C.byref(sm)), 0)
        self.assertEqual(self.lib.dc_spring_breast_step(C.byref(spring), C.byref(moved), 16, 0, 0, C.byref(sm)), 0)
        self.assertNotAlmostEqual(sm.values[5], 1.0, places=5)
        locked = Matrix()
        self.assertEqual(self.lib.dc_spring_breast_step(C.byref(spring), C.byref(moved), 16, 0, 1, C.byref(locked)), 0)
        self.assertAlmostEqual(locked.values[0], 1.0, places=6)
        self.assertAlmostEqual(locked.values[5], 1.0, places=6)


if __name__ == "__main__":
    unittest.main()
