import ctypes as C
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from native_core import (  # noqa: E402
    CameraLens,
    CameraMatrices,
    CameraOrbit,
    GlareInfo,
    LightRig,
    MaterialValue,
    Matrix,
    MeshVertex,
    PPArchive,
    SpriteVertex,
    Viewport,
    XLInfo,
    XLD3DLight,
    XXModel,
    library,
)


def _identity():
    m = Matrix()
    for i in range(16):
        m.values[i] = 1.0 if i in (0, 5, 10, 15) else 0.0
    return m


class NativeLightingTests(unittest.TestCase):
    def test_xl_ambient_and_glare_probe_and_bloom(self):
        lib = library()
        rpp10 = ROOT / "Data/RPP_10.pp"
        if not rpp10.exists():
            self.skipTest("Data/RPP_10.pp not present")
        with PPArchive(rpp10) as arc:
            names = {bytes(arc.entry(i).name).rstrip(b"\x00"): i for i in range(arc.count)}
            mp01 = arc.read(names[b"mp00_01.xl"])
            amb = (C.c_float * 3)()
            self.assertEqual(lib.dc_xl_ambient(mp01, len(mp01), amb), 0)
            self.assertAlmostEqual(amb[0], 204.0 / 255.0, places=4)
            self.assertAlmostEqual(amb[1], 204.0 / 255.0, places=4)
            self.assertAlmostEqual(amb[2], 204.0 / 255.0, places=4)

            glare_raw = arc.read(names[b"mm00_07.glare"])
            glare = GlareInfo()
            self.assertEqual(lib.dc_glare_probe(glare_raw, len(glare_raw), C.byref(glare)), 0)
            self.assertAlmostEqual(glare.scale, 1.1, places=4)
            self.assertAlmostEqual(glare.threshold, 0.6, places=4)
            self.assertAlmostEqual(glare.intensity, 0.8, places=4)
            self.assertAlmostEqual(glare.spread, 0.8, places=4)
            self.assertEqual(glare.passes, 2)

            w, h = 16, 16
            pixels = bytearray(w * h * 4)
            for p in range(w * h):
                pixels[p * 4 + 0] = 20
                pixels[p * 4 + 1] = 20
                pixels[p * 4 + 2] = 20
                pixels[p * 4 + 3] = 255
            # Bright lamp hotspot in center 2x2
            for py in (7, 8):
                for px in (7, 8):
                    idx = (py * w + px) * 4
                    pixels[idx + 0] = 250
                    pixels[idx + 1] = 240
                    pixels[idx + 2] = 220
            buf = (C.c_uint8 * len(pixels)).from_buffer(pixels)
            self.assertEqual(lib.dc_glare_apply_rgba(C.byref(glare), buf, w, h), 0)
            # Neighboring dark pixels around hotspot should receive additive bloom halo
            neighbor = (7 * w + 5) * 4
            self.assertGreater(pixels[neighbor + 0], 20)
            # Far corner remains near baseline
            self.assertEqual(pixels[0], 20)

    def test_xx_stage_tci_and_d3d9_lit_projection_on_real_actor(self):
        lib = library()
        rpp03 = ROOT / "Data/RPP_03.pp"
        rpp05 = ROOT / "Data/RPP_05.pp"
        rpp07 = ROOT / "Data/RPP_07.pp"
        if not (rpp03.exists() and rpp05.exists() and rpp07.exists()):
            self.skipTest("Real RPP_03/05/07 archives not present")

        with PPArchive(rpp03) as a3, PPArchive(rpp05) as a5, PPArchive(rpp07) as a7:
            n3 = {bytes(a3.entry(i).name).rstrip(b"\x00"): i for i in range(a3.count)}
            n5 = {bytes(a5.entry(i).name).rstrip(b"\x00"): i for i in range(a5.count)}
            n7 = {bytes(a7.entry(i).name).rstrip(b"\x00"): i for i in range(a7.count)}
            cam_idx = next(v for k, v in n3.items() if k.lower().endswith(b".cam"))
            cam_raw = a3.read(cam_idx)
            xx_raw = a5.read(n5[b"am00_02.xx"])
            xa_raw = a5.read(n5[b"an00_04.xa"])
            xl_raw = a7.read(n7[b"pp04_02.xl"])

        with XXModel(xx_raw) as xx:
            seen_tci = set()
            skin_mat_idx = None
            for m in range(xx.info().materials):
                op = C.c_uint8()
                tci = C.c_uint8()
                self.assertEqual(lib.dc_xx_material_stage_tci(xx.handle, m, 1, C.byref(op), C.byref(tci)), 0)
                if op.value != 0 and tci.value != 0:
                    seen_tci.add((op.value, tci.value))
                mt = xx.at("material", m)
                nm = bytes(b ^ 0xFF for b in xx.span(mt.name)).rstrip(b"\x00")
                if nm == b"a_Mn_momo_L":
                    skin_mat_idx = m
            # am00_02.xx has skin sphere-map (op=5,tci=1) and wet reflection sphere-map (op=2,tci=3)
            self.assertIn((5, 1), seen_tci)
            self.assertIn((2, 3), seen_tci)
            self.assertIsNotNone(skin_mat_idx)

        # Build camera and character light rig from hote_2p.cam + pp04_02.xl
        orbit = CameraOrbit()
        self.assertEqual(lib.dc_camera_read_preset(cam_raw, len(cam_raw), 0, C.byref(orbit)), 0)
        orbit.base = _identity()
        lens = CameraLens(0.3, 0.5, 10000.0, 1024, 768)
        cam = CameraMatrices()
        self.assertEqual(lib.dc_camera_build(C.byref(orbit), C.byref(lens), C.byref(cam)), 0)

        rig = LightRig()
        xl_info = XLInfo()
        self.assertEqual(lib.dc_xl_probe(xl_raw, len(xl_raw), C.byref(xl_info)), 0)
        rig.count = xl_info.lights
        amb = (C.c_float * 3)()
        lib.dc_xl_ambient(xl_raw, len(xl_raw), amb)
        for c in range(3):
            rig.global_ambient[c] = amb[c]
            rig.camera_eye[c] = cam.world.values[12 + c]
        rig.view_matrix = cam.view
        rig.shading_mode = 0
        rig.enable_specular = 1
        rig.sheen_tci = 1
        for k in range(xl_info.lights):
            lt = XLD3DLight()
            self.assertEqual(lib.dc_xl_d3d_light_at(xl_raw, len(xl_raw), k, C.byref(lt)), 0)
            rig.lights[k].d3d_type = lt.d3d_type
            for c in range(3):
                rig.lights[k].diffuse[c] = lt.diffuse[c]
                rig.lights[k].specular[c] = lt.specular[c]
                rig.lights[k].ambient[c] = lt.ambient[c]
                rig.lights[k].position[c] = lt.position[c]
                rig.lights[k].direction[c] = lt.direction[c]
                rig.lights[k].attenuation[c] = lt.attenuation[c]
            rig.lights[k].range = lt.range
            rig.lights[k].falloff = lt.falloff
            rig.lights[k].theta = lt.theta
            rig.lights[k].phi = lt.phi

        model = C.c_void_p()
        xx_buf = C.create_string_buffer(xx_raw)
        xa_buf = C.create_string_buffer(xa_raw)
        self.assertEqual(lib.dc_model_open(xx_buf, len(xx_raw), xa_buf, len(xa_raw), C.byref(model)), 0)
        try:
            world = _identity()
            self.assertEqual(lib.dc_model_request(model, 1, 0), 0)
            self.assertEqual(lib.dc_model_tick(model, 0, 0, C.byref(world)), 0)
            vp = Viewport(0.0, 0.0, 1024.0, 768.0, 0.0, 1.0)
            # Project mesh 4 (a_Mn_momo_L skinned mesh)
            mat = MaterialValue()
            self.assertEqual(lib.dc_model_material(model, skin_mat_idx, C.byref(mat)), 0)
            written = C.c_size_t()
            self.assertEqual(
                lib.dc_model_project_lit_clipped(
                    model, 4, C.byref(cam.view_projection), C.byref(vp),
                    C.byref(mat), C.byref(rig), None, None, None, 0, C.byref(written), None
                ),
                0,
            )
            self.assertGreater(written.value, 0)
            cap = written.value
            base_v = (SpriteVertex * cap)()
            spec_v = (SpriteVertex * cap)()
            sheen_v = (SpriteVertex * cap)()
            has_spec = C.c_uint32()
            self.assertEqual(
                lib.dc_model_project_lit_clipped(
                    model, 4, C.byref(cam.view_projection), C.byref(vp),
                    C.byref(mat), C.byref(rig), base_v, spec_v, sheen_v,
                    cap, C.byref(written), C.byref(has_spec)
                ),
                0,
            )
            # Gouraud lighting produces non-uniform vertex shading across curved thigh mesh
            colors = {base_v[i].diffuse for i in range(written.value)}
            self.assertGreater(len(colors), 3)
            # Sheen UVs lie in [0, 1] and vary with view-space normal
            sheen_us = {round(sheen_v[i].u, 3) for i in range(written.value)}
            self.assertGreater(len(sheen_us), 3)
            for i in range(written.value):
                self.assertGreaterEqual(sheen_v[i].u, 0.0)
                self.assertLessEqual(sheen_v[i].u, 1.0)
                self.assertGreaterEqual(sheen_v[i].v, 0.0)
                self.assertLessEqual(sheen_v[i].v, 1.0)
        finally:
            lib.dc_model_close(model)

    def test_synthetic_specular_and_toon_modes(self):
        lib = library()
        verts = (MeshVertex * 3)(
            MeshVertex((-0.5, -0.5, 0.5), (0.0, 0.0, -1.0), (0.0, 1.0)),
            MeshVertex((0.5, -0.5, 0.5), (0.0, 0.0, -1.0), (1.0, 1.0)),
            MeshVertex((0.0, 0.5, 0.5), (0.0, 0.0, -1.0), (0.5, 0.0)),
        )
        idx = (C.c_uint16 * 3)(0, 1, 2)
        mvp = _identity()
        vp = Viewport(0.0, 0.0, 640.0, 480.0, 0.0, 1.0)
        mat = MaterialValue()
        for i, val in enumerate([1, 1, 1, 1, 1, 1, 1, 1, 0.8, 0.8, 0.8, 1, 0, 0, 0, 1, 32.0]):
            mat.components[i] = float(val)
        rig = LightRig()
        rig.count = 1
        rig.camera_eye[2] = -5.0
        rig.view_matrix = _identity()
        rig.enable_specular = 1
        rig.sheen_tci = 3  # reflection vector
        rig.lights[0].d3d_type = 3  # directional shining +Z onto -Z normal
        rig.lights[0].direction[2] = 1.0
        rig.lights[0].diffuse[0] = rig.lights[0].diffuse[1] = rig.lights[0].diffuse[2] = 0.8
        rig.lights[0].specular[0] = rig.lights[0].specular[1] = rig.lights[0].specular[2] = 1.0

        out_b = (SpriteVertex * 6)()
        out_s = (SpriteVertex * 6)()
        out_sh = (SpriteVertex * 6)()
        written = C.c_size_t()
        has_spec = C.c_uint32()
        self.assertEqual(
            lib.dc_mesh_clip_project_lit(
                verts, 3, idx, 3, None, C.byref(mvp), C.byref(vp),
                C.byref(mat), C.byref(rig), out_b, out_s, out_sh,
                6, C.byref(written), C.byref(has_spec)
            ),
            0,
        )
        self.assertEqual(written.value, 3)
        self.assertEqual(has_spec.value, 1)
        self.assertGreater(out_s[0].diffuse & 0xFF, 100)

        # Switch to TOON ramp with grazing angle
        verts[0].normal[0] = 0.9
        verts[0].normal[2] = -0.3
        rig.shading_mode = 1
        self.assertEqual(
            lib.dc_mesh_clip_project_lit(
                verts, 3, idx, 3, None, C.byref(mvp), C.byref(vp),
                C.byref(mat), C.byref(rig), out_b, out_s, out_sh,
                6, C.byref(written), C.byref(has_spec)
            ),
            0,
        )
        self.assertEqual(written.value, 3)


if __name__ == "__main__":
    unittest.main()
