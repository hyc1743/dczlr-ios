import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from material_cases import cases, native_result, value
from native_core import library, MaterialValue, MaterialKey


class NativeMaterialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def sample(self, frames, at, initial=None):
        keys = (MaterialKey * len(frames))(*(MaterialKey(value([i * 10] * 17), frame) for i, frame in enumerate(frames)))
        output = value(initial if initial is not None else [1000] * 17)
        baseline = value([-10] * 17)
        self.assertEqual(self.lib.dc_material_sample(keys, len(keys), C.byref(baseline), at, C.byref(output)), 0)
        return list(output.components)

    def test_recorded_original_pair_and_selection_outputs(self):
        fixture = json.loads((ROOT / "tests/fixtures/material-original-vectors.json").read_text())
        digest, count = hashlib.sha256(), 0
        for case in cases():
            for pair in ((False, True) if len(case["keys"]) == 2 else (False,)):
                output = native_result(self.lib, case, pair)
                for control_word in fixture["x87_control_words"]:
                    digest.update((json.dumps({**case, "pair": pair, "control_word": control_word, "output": output},
                                  sort_keys=True, separators=(",", ":")) + "\n").encode())
                    count += 1
        self.assertEqual(count, fixture["cases"])
        self.assertEqual(digest.hexdigest(), fixture["output_sha256"])

    def test_inclusive_first_interval_preserves_three_destination_components(self):
        output = self.sample((0, 8, 8, 16), 8)
        self.assertEqual([output[i] for i in (0, 3, 16)], [10] * 3)
        self.assertEqual([output[i] for i in (7, 11, 15)], [1000] * 3)
        self.assertEqual(self.sample((8, 0, 16), 4)[0], 12.5)

    def test_zero_keys_leave_destination_one_key_and_outside_use_baseline(self):
        self.assertEqual(self.sample((), 1), [1000] * 17)
        self.assertEqual(self.sample((4,), 4), [-10] * 17)
        self.assertEqual(self.sample((0, 8), -1), [-10] * 17)
        self.assertEqual(self.sample((0, 8), 9), [-10] * 17)

    def test_signed_integer_timestamps_are_not_first_rounded_to_float(self):
        left = MaterialKey(value([0] * 17), 2147483646)
        right = MaterialKey(value([10] * 17), 2147483647)
        output = value([1000] * 17)
        self.assertEqual(self.lib.dc_material_interpolate(C.byref(left), C.byref(right), 2147483648, C.byref(output)), 0)
        self.assertEqual(output.components[0], 20)
        self.assertEqual(self.sample((2147483646, 2147483647), 2147483648), [-10] * 17)

    def test_coincident_pair_and_aliased_destination(self):
        left, right = MaterialKey(value([2] * 17), 3), MaterialKey(value([10] * 17), 3)
        self.assertEqual(self.lib.dc_material_interpolate(C.byref(left), C.byref(right), 100, C.byref(left.value)), 0)
        self.assertEqual(list(left.value.components), [2] * 17)
        right.frame = 11
        self.assertEqual(self.lib.dc_material_interpolate(C.byref(left), C.byref(right), 7, C.byref(right.value)), 0)
        self.assertEqual(right.value.components[0], 6)
        self.assertEqual(right.value.components[7], 10)

    def test_nonfinite_and_overflow_fail_atomically(self):
        for problem in ("frame", "key", "result"):
            left, right = MaterialKey(value([2] * 17), 0), MaterialKey(value([10] * 17), 1)
            output = value([999] * 17)
            frame = 0.5
            if problem == "frame": frame = float("nan")
            if problem == "key": right.value.components[16] = float("inf")
            if problem == "result":
                right.value.components[16] = 3e38
                frame = 100
            before = bytes(output)
            self.assertEqual(self.lib.dc_material_interpolate(C.byref(left), C.byref(right), frame, C.byref(output)), 4)
            self.assertEqual(bytes(output), before)
        # Preserved components can carry arbitrary float bytes without use.
        right.value.components[16] = 10
        right.value.components[7] = float("nan")
        self.assertEqual(self.lib.dc_material_interpolate(C.byref(left), C.byref(right), 0.5, C.byref(output)), 0)

    def test_argument_validation_leaves_output_unchanged(self):
        output, baseline = value([999] * 17), value([0] * 17)
        before = bytes(output)
        self.assertEqual(self.lib.dc_material_sample(None, 1, C.byref(baseline), 0, C.byref(output)), 1)
        self.assertEqual(self.lib.dc_material_sample(None, 0x80000000, C.byref(baseline), 0, C.byref(output)), 1)
        self.assertEqual(self.lib.dc_material_sample(None, 0, None, 0, C.byref(output)), 0)
        self.assertEqual(self.lib.dc_material_interpolate(None, None, 0, C.byref(output)), 1)
        self.assertEqual(bytes(output), before)


if __name__ == "__main__":
    unittest.main()
