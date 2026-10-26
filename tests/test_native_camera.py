import ctypes as C
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,CameraOrbit,CameraLens,CameraMatrices,Matrix
from scene_cases import matrix
from camera_cases import cases


class NativeCameraTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_retarget_matches_original_instruction_vectors_with_math_boundaries(self):
        from camera_retarget_cases import cases
        source=list(cases());fixture=json.loads((ROOT/'tests/fixtures/camera-retarget-original-vectors.json').read_text())
        self.assertEqual(fixture['cases'],128)
        for row in fixture['vectors']:
            orbit,target,primary=source[row['case']];out=CameraOrbit()
            self.assertEqual(self.lib.dc_camera_retarget(C.byref(orbit),C.byref(target),primary,C.byref(out)),0)
            actual=list(out.base.values)+[out.stored_distance,out.height,out.pitch,out.yaw]
            for a,b in zip(actual,row['result']):self.assertLessEqual(abs(a-b),2e-4*(1+abs(b)))
    def test_retarget_rejects_invalid_values_atomically_and_supports_aliasing(self):
        source=CameraOrbit(matrix(),-20,2,.1,.3);target=matrix(translation=(3,4,5));expected=CameraOrbit()
        self.assertEqual(self.lib.dc_camera_retarget(C.byref(source),C.byref(target),1,C.byref(expected)),0)
        self.assertEqual(self.lib.dc_camera_retarget(C.byref(source),C.byref(target),1,C.byref(source)),0)
        self.assertEqual(bytes(source),bytes(expected));before=bytes(expected)
        target.values[12]=float('nan')
        self.assertEqual(self.lib.dc_camera_retarget(C.byref(source),C.byref(target),1,C.byref(expected)),4)
        self.assertEqual(bytes(expected),before)
        self.assertEqual(self.lib.dc_camera_retarget(C.byref(source),C.byref(target),2,C.byref(expected)),4)
        self.assertEqual(self.lib.dc_camera_retarget(None,C.byref(target),0,C.byref(expected)),1)
        zero=Matrix();self.assertEqual(self.lib.dc_camera_retarget(C.byref(source),C.byref(zero),1,C.byref(expected)),3)
        self.assertEqual(bytes(expected),before)
    def test_original_scene_camera_filenames_resolve_for_every_reachable_scene(self):
        from native_core import StoryChapter,PPArchive
        expected={3:'home_sh.cam',5:'trai_ch.cam',7:'toil_ta.cam',10:'home_sh.cam',12:'trai_ch.cam',14:'park_tc.cam',17:'home_sh.cam',19:'trai_ch.cam',21:'hote_tb.cam'}
        names=None
        if (ROOT/'Data/RPP_03.pp').exists():
            with PPArchive(ROOT/'Data/RPP_03.pp') as pp:names={pp.entry(i).name_bytes.decode('ascii') for i in range(pp.count)}
        for chapter,name in expected.items():
            profile=StoryChapter();self.lib.dc_story_chapter_profile(chapter,C.byref(profile));out=C.create_string_buffer(32)
            self.assertEqual(self.lib.dc_camera_scene_resource(profile.scene_type,profile.map,profile.stage,out,32),0)
            self.assertEqual(out.value.decode(),name)
            if names is not None:self.assertIn(name,names)

    def test_bind_pose_compensation_attaches_to_animated_neck_once(self):
        bind=matrix(.3,.9,(0,6.2,-.2));animated=matrix(-.2,1.1,(22,3.7,-.5))
        inverse=Matrix();world=Matrix();attached=Matrix()
        self.assertEqual(self.lib.dc_matrix_inverse_affine(C.byref(bind),C.byref(inverse)),0)
        self.assertEqual(self.lib.dc_matrix_multiply(C.byref(inverse),C.byref(animated),C.byref(world)),0)
        self.assertEqual(self.lib.dc_matrix_multiply(C.byref(bind),C.byref(world),C.byref(attached)),0)
        for a,b in zip(attached.values,animated.values):self.assertAlmostEqual(a,b,places=5)
        before=bytes(inverse);singular=matrix();singular.values[0]=0
        self.assertEqual(self.lib.dc_matrix_inverse_affine(C.byref(singular),C.byref(inverse)),4)
        self.assertEqual(bytes(inverse),before)
        self.assertEqual(self.lib.dc_matrix_inverse_affine(None,C.byref(inverse)),1)

    def test_original_orbit_and_projection_reference(self):
        source=list(cases())
        fixture=json.loads((ROOT/'tests/fixtures/camera-original-vectors.json').read_text())
        self.assertEqual(fixture['cases'],len(source))
        for row in fixture['vectors']:
            orbit,lens=source[row['case']];out=CameraMatrices()
            self.assertEqual(self.lib.dc_camera_build(C.byref(orbit),C.byref(lens),C.byref(out)),0)
            for name,raw in zip(('world','view','projection','view_projection'),row['matrix_hex']):
                for a,b in zip(getattr(out,name).values,struct.unpack('<16f',bytes.fromhex(raw))):
                    self.assertLessEqual(abs(a-b),5e-5*(1+abs(b)),(row['case'],name,a,b))

    def test_distance_sign_inverse_and_right_handed_depth(self):
        orbit=CameraOrbit(matrix(),-5,3,0,0);lens=CameraLens(.3,.5,10000,1024,768)
        out=CameraMatrices()
        self.assertEqual(self.lib.dc_camera_build(C.byref(orbit),C.byref(lens),C.byref(out)),0)
        self.assertEqual(list(out.world.values[12:15]),[0,3,5])
        self.assertEqual(list(out.view.values[12:15]),[0,-3,-5])
        p=out.projection.values
        for distance,depth in ((lens.near_z,0),(lens.far_z,1)):
            self.assertAlmostEqual((-distance*p[10]+p[14])/distance,depth,places=6)
        self.assertEqual(p[11],-1)

    def test_invalid_input_preserves_all_output(self):
        for kind in ('distance','pitch','height','yaw','base_nan','projective','singular',
                     'fov_zero','fov_pi','near_zero','far_same','lens_nan','width','height_zero'):
            orbit=CameraOrbit(matrix(),-5,3,.2,.4);lens=CameraLens(.3,.5,10000,1024,768)
            if kind in ('distance','pitch','height','yaw'):
                setattr(orbit,'stored_distance' if kind=='distance' else kind,float('nan'))
            elif kind=='base_nan':orbit.base.values[6]=float('nan')
            elif kind=='projective':orbit.base.values[3]=.25
            elif kind=='singular':orbit.base.values[0]=0
            elif kind=='fov_zero':lens.fov_y=0
            elif kind=='fov_pi':lens.fov_y=3.141592653589793
            elif kind=='near_zero':lens.near_z=0
            elif kind=='far_same':lens.far_z=lens.near_z
            elif kind=='lens_nan':lens.far_z=float('nan')
            elif kind=='width':lens.viewport_width=0
            elif kind=='height_zero':lens.viewport_height=0
            out=CameraMatrices();C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
            self.assertIn(self.lib.dc_camera_build(C.byref(orbit),C.byref(lens),C.byref(out)),(3,4),kind)
            self.assertEqual(bytes(out),before,kind)

    def test_null_and_input_aliasing(self):
        orbit=CameraOrbit(matrix(.2,.75,(4,5,6)),-20,3,.2,.7);lens=CameraLens(.3,.5,10000,1024,768)
        expected=CameraMatrices()
        self.assertEqual(self.lib.dc_camera_build(C.byref(orbit),C.byref(lens),C.byref(expected)),0)
        self.assertEqual(self.lib.dc_camera_build(None,C.byref(lens),C.byref(expected)),1)
        self.assertEqual(self.lib.dc_camera_build(C.byref(orbit),None,C.byref(expected)),1)
        self.assertEqual(self.lib.dc_camera_build(C.byref(orbit),C.byref(lens),None),1)
        for alias_orbit in (True,False):
            buffer=C.create_string_buffer(C.sizeof(CameraMatrices))
            value=orbit if alias_orbit else lens
            C.memmove(buffer,C.byref(value),C.sizeof(value))
            op=C.cast(buffer,C.POINTER(CameraOrbit)) if alias_orbit else C.byref(orbit)
            lp=C.byref(lens) if alias_orbit else C.cast(buffer,C.POINTER(CameraLens))
            self.assertEqual(self.lib.dc_camera_build(op,lp,C.cast(buffer,C.POINTER(CameraMatrices))),0)
            self.assertEqual(buffer.raw,bytes(expected))

    def test_cam_single_and_grouped_records_preserve_stored_sign(self):
        values=[(i+3,-float(i+5),i*.05,-i*.1,i+7,i+9,i+11) for i in range(9)]
        for count in (1,9):
            data=b''.join(struct.pack('<7f',*v) for v in values[:count])
            for i in range(count):
                out=CameraOrbit()
                self.assertEqual(self.lib.dc_camera_read_preset(data,len(data),i,C.byref(out)),0)
                p=struct.unpack_from('<7f',data,i*28)
                self.assertEqual((out.height,out.stored_distance,out.pitch,out.yaw),p[:4])
                self.assertEqual(list(out.base.values),list(matrix(translation=p[4:]).values))

    def test_cam_truncation_bounds_nonfinite_and_alias(self):
        data=struct.pack('<7f',3,-5,.2,.4,6,7,8);out=CameraOrbit()
        C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
        for raw,index in ((data[:-1],0),(data+b'x',0),(data,1),(data*9,9),
                          (data*8+struct.pack('<7f',float('inf'),0,0,0,0,0,0),0)):
            self.assertIn(self.lib.dc_camera_read_preset(raw,len(raw),index,C.byref(out)),(3,4))
            self.assertEqual(bytes(out),before)
        self.assertEqual(self.lib.dc_camera_read_preset(None,28,0,C.byref(out)),1)
        self.assertEqual(self.lib.dc_camera_read_preset(data,28,0,None),1)
        self.assertEqual(self.lib.dc_camera_read_preset(data,28,0,C.byref(out)),0)
        buffer=C.create_string_buffer(C.sizeof(out));C.memmove(buffer,data,len(data))
        self.assertEqual(self.lib.dc_camera_read_preset(buffer,28,0,C.cast(buffer,C.POINTER(CameraOrbit))),0)
        self.assertEqual(buffer.raw,bytes(out))


if __name__=='__main__':unittest.main()
