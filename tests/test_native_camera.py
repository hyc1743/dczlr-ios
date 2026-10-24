import ctypes as C
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,CameraOrbit,CameraLens,CameraMatrices
from scene_cases import matrix
from camera_cases import cases


class NativeCameraTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

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
