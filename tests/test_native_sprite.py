"""Native sprite submission against recorded isolated-original command digests."""
import ctypes as C
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from native_core import library, SpriteDraw, SpritePlan, SpritePose, SpriteVertex
from sprite_cases import cases


class NativeSpriteTests(unittest.TestCase):
    def test_original_sprite_entry_plan(self):
        vectors = json.loads((Path(__file__).parent / "fixtures/sprite-draw-original-vectors.json").read_text())
        result = SpritePlan()
        self.assertEqual(library().dc_sprite_begin_plan(C.byref(result)), 0)
        self.assertEqual(result.records(), vectors["begin_plan"]["commands"])
        self.assertEqual(result.next_mode, vectors["begin_plan"]["next_mode"])
        self.assertEqual(result.count, 8)
        self.assertNotEqual(library().dc_sprite_begin_plan(None), 0)

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


class NativeSpriteVertexTests(unittest.TestCase):
    def default_pose(self):
        return SpritePose(20, 10, 10.75, -3.75, 0.5, 0, 0, 1, 1, 0.5, 0,
                          1, 0.5, 0, 0.25, 0.75, 0.125, 0.875)

    def build(self, pose):
        output = (SpriteVertex * 4)()
        self.assertEqual(library().dc_sprite_build_vertices(C.byref(pose), output), 0)
        return output

    def test_recorded_original_vertices(self):
        report = json.loads((Path(__file__).parent / "fixtures/sprite-vertices-original-vectors.json").read_text())
        self.assertEqual(len(report["vectors"]), 48)
        for row in report["vectors"]:
            pose = SpritePose.from_buffer_copy(bytes.fromhex(row["pose_hex"]))
            actual = bytes(self.build(pose))
            expected = bytes.fromhex(row["original_vertices_hex"])
            if pose.rotation == 0:
                self.assertEqual(actual, expected)
            else:
                for i in range(4):
                    for a, b in zip(struct.unpack_from("<2f", actual, i * 32),
                                    struct.unpack_from("<2f", expected, i * 32)):
                        tolerance = report["rotated_absolute_tolerance"] + report["rotated_relative_tolerance"] * max(abs(a), abs(b))
                        self.assertLessEqual(abs(a - b), tolerance)
                    self.assertEqual(actual[i * 32 + 8:i * 32 + 32], expected[i * 32 + 8:i * 32 + 32])

    def test_snap_strip_order_uv_color_and_pivot_rotation(self):
        pose = self.default_pose()
        out = self.build(pose)
        self.assertEqual([(v.x, v.y) for v in out], [(10, -3), (10, 7), (30, -3), (30, 7)])
        self.assertEqual([(v.u, v.v) for v in out], [(0.25, 0.125), (0.25, 0.875), (0.75, 0.125), (0.75, 0.875)])
        self.assertTrue(all((v.z, v.rhw, v.diffuse, v.specular) == (0.5, 1, 0x7fff7f00, 0xff000000) for v in out))
        pose.x = pose.y = 0
        pose.origin_x = pose.origin_y = 0.5
        pose.rotation = math.pi / 2
        out = self.build(pose)
        for v, expected in zip(out, [(5, -10), (-5, -10), (5, 10), (-5, 10)]):
            self.assertAlmostEqual(v.x, expected[0], places=4)
            self.assertAlmostEqual(v.y, expected[1], places=4)

    def test_zero_extent_negative_scale_and_wrapping_color(self):
        pose = self.default_pose()
        pose.width = 0
        pose.scale_y = -2
        pose.alpha, pose.red, pose.green, pose.blue = 2, -1, 0, 1
        out = self.build(pose)
        self.assertTrue(all(v.x == 10 for v in out))
        self.assertEqual(out[1].y, -23)
        self.assertEqual(out[0].diffuse, 0xfe0100ff)

    def test_nonfinite_and_out_of_range_leave_output_unchanged(self):
        lib = library()
        output = (SpriteVertex * 4)()
        C.memset(output, 0xa5, C.sizeof(output))
        before = bytes(output)
        for field in [name for name, type_ in SpritePose._fields_]:
            for value in (float("nan"), float("inf"), -float("inf")):
                pose = self.default_pose()
                setattr(pose, field, value)
                self.assertNotEqual(lib.dc_sprite_build_vertices(C.byref(pose), output), 0)
                self.assertEqual(bytes(output), before)
        for field in ("alpha", "x", "y"):
            pose = self.default_pose()
            setattr(pose, field, 1e30)
            self.assertNotEqual(lib.dc_sprite_build_vertices(C.byref(pose), output), 0)
            self.assertEqual(bytes(output), before)
        pose = self.default_pose()
        pose.width, pose.scale_x = 3e38, 3e38
        self.assertNotEqual(lib.dc_sprite_build_vertices(C.byref(pose), output), 0)
        self.assertEqual(bytes(output), before)
        self.assertNotEqual(lib.dc_sprite_build_vertices(None, output), 0)
        self.assertNotEqual(lib.dc_sprite_build_vertices(C.byref(self.default_pose()), None), 0)


if __name__ == "__main__":
    unittest.main()
