"""Native sprite submission against recorded isolated-original command digests."""
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from native_core import library, SpriteDraw, SpritePlan
from sprite_cases import cases


class NativeSpriteTests(unittest.TestCase):
    def plan(self, draw, cached):
        result = SpritePlan()
        self.assertEqual(library().dc_sprite_build_plan(C.byref(draw) if draw else None,
                                                       cached, C.byref(result)), 0)
        return result

    def test_original_function_command_matrix_and_cache(self):
        vectors = json.loads((Path(__file__).parent / "fixtures/sprite-draw-original-vectors.json").read_text())
        self.assertEqual(vectors["generator"], "sprite_cases.cases v1")
        hashes, counts = {}, {}
        for case in cases():
            draw = SpriteDraw(**case["draw"]) if case["draw"] else None
            plan = self.plan(draw, case["cached_mode"])
            actual = {"commands": plan.records(), "next_mode": plan.next_mode}
            key = str(case["cached_mode"])
            hashes.setdefault(key, hashlib.sha256()).update((json.dumps(actual, sort_keys=True, separators=(",", ":")) + "\n").encode())
            counts[key] = counts.get(key, 0) + 1
        self.assertEqual(sum(counts.values()), vectors["case_count"])
        self.assertEqual(set(hashes), set(vectors["groups"]))
        for key, digest in hashes.items():
            self.assertEqual(counts[key], vectors["groups"][key]["cases"])
            self.assertEqual(digest.hexdigest(), vectors["groups"][key]["original_commands_sha256"], key)

    def test_mode_three_restoration_and_same_mode_suppression(self):
        draw = SpriteDraw(7, 9, 0, 0, 0, 0)
        leaving = self.plan(draw, 3).records()
        self.assertEqual(leaving[:4], [[2, [0, 1, 4]], [2, [0, 2, 2]],
                                       [2, [0, 3, 1]], [2, [0, 4, 1]]])
        self.assertEqual(self.plan(draw, 0).count, 5)
        draw.blend_mode = 3
        self.assertEqual(self.plan(draw, 255).count, 13)
        self.assertEqual(self.plan(draw, 3).count, 5)

    def test_point_filter_wraps_actual_draw_and_restores_linear(self):
        draw = SpriteDraw(7, 9, 3, 0, 1, 1)
        plan = self.plan(draw, 255)
        self.assertEqual(plan.count, 17)
        commands = plan.records()
        self.assertEqual(commands[8:10], [[3, [0, 5, 1]], [3, [0, 6, 1]]])
        self.assertEqual(commands[-3:], [[8, [5, 0, 2]], [3, [0, 5, 2]], [3, [0, 6, 2]]])
        self.assertEqual(plan.next_mode, 3)

    def test_full_width_handles_and_skipped_draw(self):
        maximum = (1 << (C.sizeof(C.c_void_p) * 8)) - 1
        draw = SpriteDraw(maximum, maximum - 1, 1, 0, 0, 255)
        plan = self.plan(draw, 1)
        self.assertEqual(plan.records()[0], [4, [255]])
        self.assertEqual(plan.records()[1:3], [[5, [0, maximum - 1]], [6, [0, maximum, 0, 32]]])
        draw.hidden = 1
        self.assertEqual(self.plan(draw, 255).count, 0)
        self.assertEqual(self.plan(draw, 255).next_mode, 255)
        self.assertEqual(self.plan(None, 2).next_mode, 2)

    def test_invalid_inputs_leave_destination_and_guards_unchanged(self):
        lib = library()
        output = SpritePlan()
        C.memset(C.byref(output), 0xa5, C.sizeof(output))
        before = bytes(output)
        for mode, cached in [(4, 0), (255, 0), (0, 4), (0, 256), (0, 0xffffffff)]:
            draw = SpriteDraw(7, 9, mode, 0, 0, 0)
            self.assertNotEqual(lib.dc_sprite_build_plan(C.byref(draw), cached, C.byref(output)), 0)
            self.assertEqual(bytes(output), before)
        self.assertNotEqual(lib.dc_sprite_build_plan(None, 0, None), 0)
        class Guarded(C.Structure):
            _fields_ = [("before", C.c_uint64), ("plan", SpritePlan), ("after", C.c_uint64)]
        guarded = Guarded()
        guarded.before = guarded.after = 0xfedcba9876543210
        draw = SpriteDraw(7, 9, 3, 0, 1, 1)
        self.assertEqual(lib.dc_sprite_build_plan(C.byref(draw), 255, C.byref(guarded.plan)), 0)
        self.assertEqual((guarded.before, guarded.after), (0xfedcba9876543210,) * 2)


if __name__ == "__main__":
    unittest.main()
