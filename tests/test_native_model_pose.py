import ctypes as C
import math
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import AnimationState, MaterialValue, Matrix, MeshVertex, PPArchive, library
from model_cases import fixture
from scene_cases import matrix


class NativeModelPoseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def test_node_visible_reflects_recursive_hide_and_reveal(self):
        xx, xa = fixture(skinned=True)
        model = C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx, len(xx), xa, len(xa), C.byref(model)), 0)
        self.addCleanup(self.lib.dc_model_close, model)
        vis = C.c_uint32()
        self.assertEqual(self.lib.dc_model_node_visible(model, 0, C.byref(vis)), 0)
        self.assertEqual(vis.value, 1)
        self.assertEqual(self.lib.dc_model_node_visible(model, 1, C.byref(vis)), 0)
        self.assertEqual(vis.value, 1)
        self.assertEqual(self.lib.dc_model_hide_node(model, 0, 1), 0)
        self.assertEqual(self.lib.dc_model_node_visible(model, 1, C.byref(vis)), 0)
        self.assertEqual(vis.value, 0)
        self.assertEqual(self.lib.dc_model_hide_node(model, 1, 0), 0)
        self.assertEqual(self.lib.dc_model_node_visible(model, 1, C.byref(vis)), 0)
        self.assertEqual(vis.value, 1)

    def test_node_extra_modifiers_and_refresh_pose_update_skin_without_clock_step(self):
        xx, xa = fixture(skinned=True)
        model = C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx, len(xx), xa, len(xa), C.byref(model)), 0)
        self.addCleanup(self.lib.dc_model_close, model)
        world = matrix(translation=(5.0, 2.0, -3.0))
        self.assertEqual(self.lib.dc_model_tick(model, 100, 100, C.byref(world)), 0)
        before_anim = AnimationState()
        self.assertEqual(self.lib.dc_model_get_animation(model, C.byref(before_anim)), 0)
        before_global = Matrix()
        self.assertEqual(self.lib.dc_model_global(model, 1, C.byref(before_global)), 0)

        # Modifier 1 rotates orientation in world space while preserving pivot translation.
        rot_z = matrix()
        c = math.cos(0.5)
        s = math.sin(0.5)
        rot_z.values[0] = c
        rot_z.values[1] = s
        rot_z.values[4] = -s
        rot_z.values[5] = c
        self.assertEqual(self.lib.dc_model_set_node_extra(model, 1, 1, C.byref(rot_z)), 0)
        self.assertEqual(self.lib.dc_model_refresh_pose(model, C.byref(world)), 0)
        mod1_global = Matrix()
        self.assertEqual(self.lib.dc_model_global(model, 1, C.byref(mod1_global)), 0)
        for idx in (12, 13, 14):
            self.assertAlmostEqual(mod1_global.values[idx], before_global.values[idx], places=5)
        self.assertNotAlmostEqual(mod1_global.values[0], before_global.values[0], places=3)

        # Modifier 2 pre-multiplies local space (e.g. breast squash scale/offset).
        squash = matrix(translation=(0.1, -0.2, 0.0))
        squash.values[0] = 0.86
        squash.values[5] = 0.52
        squash.values[10] = 0.90
        self.assertEqual(self.lib.dc_model_set_node_extra(model, 1, 2, C.byref(squash)), 0)
        self.assertEqual(self.lib.dc_model_refresh_pose(model, C.byref(world)), 0)
        mod2_global = Matrix()
        self.assertEqual(self.lib.dc_model_global(model, 1, C.byref(mod2_global)), 0)
        self.assertNotAlmostEqual(mod2_global.values[12], before_global.values[12], places=3)

        after_anim = AnimationState()
        self.assertEqual(self.lib.dc_model_get_animation(model, C.byref(after_anim)), 0)
        self.assertAlmostEqual(after_anim.frame, before_anim.frame, places=6)

        # Clearing modifier 0 restores original animated pose.
        self.assertEqual(self.lib.dc_model_set_node_extra(model, 1, 0, None), 0)
        self.assertEqual(self.lib.dc_model_refresh_pose(model, C.byref(world)), 0)
        restored = Matrix()
        self.assertEqual(self.lib.dc_model_global(model, 1, C.byref(restored)), 0)
        for a, b in zip(restored.values, before_global.values):
            self.assertAlmostEqual(a, b, places=5)

    def test_scrub_clip_interpolates_frames_and_locks_fixed_frame(self):
        xx, xa = fixture(skinned=True)
        model = C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx, len(xx), xa, len(xa), C.byref(model)), 0)
        self.addCleanup(self.lib.dc_model_close, model)
        world = matrix()

        self.assertEqual(self.lib.dc_model_scrub_clip(model, 2, 0.0, 0.0, C.byref(world)), 0)
        mat0 = MaterialValue()
        g0 = Matrix()
        self.assertEqual(self.lib.dc_model_material(model, 0, C.byref(mat0)), 0)
        self.assertEqual(self.lib.dc_model_global(model, 1, C.byref(g0)), 0)

        self.assertEqual(self.lib.dc_model_scrub_clip(model, 2, 0.5, 0.25, C.byref(world)), 0)
        anim = AnimationState()
        self.assertEqual(self.lib.dc_model_get_animation(model, C.byref(anim)), 0)
        self.assertEqual(anim.current, 2)
        self.assertEqual(anim.fixed_frame, 1)
        self.assertAlmostEqual(anim.frame, 4.25, places=5)

        # While fixed_frame == 1, ticking does not advance or chain away from scrubbed frame.
        self.assertEqual(self.lib.dc_model_tick(model, 500, 500, C.byref(world)), 0)
        self.assertEqual(self.lib.dc_model_get_animation(model, C.byref(anim)), 0)
        self.assertEqual(anim.current, 2)
        self.assertAlmostEqual(anim.frame, 4.25, places=5)

        self.assertEqual(self.lib.dc_model_scrub_clip(model, 2, 1.0, 0.0, C.byref(world)), 0)
        mat1 = MaterialValue()
        g1 = Matrix()
        self.assertEqual(self.lib.dc_model_material(model, 0, C.byref(mat1)), 0)
        self.assertEqual(self.lib.dc_model_global(model, 1, C.byref(g1)), 0)
        self.assertGreater(mat1.components[3], mat0.components[3])
        self.assertGreater(g1.values[12], g0.values[12])

    def test_real_chikan_clothing_scrub_clips_if_archive_present(self):
        archive_path = ROOT / "Data" / "RPP_08.pp"
        if not archive_path.is_file():
            self.skipTest("Data/RPP_08.pp not present")
        with PPArchive(archive_path) as pp:
            names = {pp.entry(i).name_bytes.decode("ascii", "ignore").lower(): i for i in range(pp.count)}
            xx = pp.read(names["bm00_01.xx"])
            xa = pp.read(names["bn00_03.xa"])
        model = C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx, len(xx), xa, len(xa), C.byref(model)), 0)
        self.addCleanup(self.lib.dc_model_close, model)
        world = matrix()
        for clip in (39, 250, 254, 258, 260, 264, 266, 268, 270, 272):
            self.assertEqual(self.lib.dc_model_scrub_clip(model, clip, 0.0, 0.0, C.byref(world)), 0)
            self.assertEqual(self.lib.dc_model_scrub_clip(model, clip, 0.5, 0.15, C.byref(world)), 0)
            self.assertEqual(self.lib.dc_model_scrub_clip(model, clip, 1.0, 0.0, C.byref(world)), 0)


if __name__ == "__main__":
    unittest.main()
