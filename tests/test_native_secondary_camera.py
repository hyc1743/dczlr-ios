import ctypes as C
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,CameraOrbit,CameraPointerInput,CameraPointerLimits,Viewport
from secondary_camera_cases import cases
from scene_cases import matrix

class SecondaryCameraTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def test_original_pointer_instruction_vectors(self):
        inputs=list(cases());reference=json.loads((ROOT/'tests/fixtures/secondary-pointer-original-vectors.json').read_text(encoding='utf-8'))
        self.assertEqual(len(inputs),reference['cases'])
        for row in reference['vectors']:
            orbit,limits,motion=inputs[row['case']];out=CameraOrbit()
            self.assertEqual(self.lib.dc_camera_secondary_pointer(C.byref(orbit),C.byref(limits),C.byref(motion),C.byref(out)),0)
            for a,b in zip(list(out.base.values)+[out.stored_distance,out.height,out.pitch,out.yaw],row['result']):
                self.assertLess(abs(a-b),2e-5)
    def test_buttons_take_precedence_over_wheel_and_support_aliasing(self):
        source=CameraOrbit(matrix(),-20,0,.1,.2);limits=CameraPointerLimits(100,5,20,-30,4)
        with_wheel=CameraPointerInput(10,20,120,1,1,0,1);without=CameraPointerInput(10,20,0,1,1,0,1);expected=CameraOrbit()
        self.assertEqual(self.lib.dc_camera_secondary_pointer(C.byref(source),C.byref(limits),C.byref(without),C.byref(expected)),0)
        self.assertEqual(self.lib.dc_camera_secondary_pointer(C.byref(source),C.byref(limits),C.byref(with_wheel),C.byref(source)),0)
        self.assertEqual(bytes(source),bytes(expected))
    def test_invalid_controller_inputs_preserve_output(self):
        source=CameraOrbit(matrix(),-20,0,.1,.2);limits=CameraPointerLimits(100,5,20,-30,4);motion=CameraPointerInput()
        out=CameraOrbit(matrix(translation=(10,20,30)),-1,1,1,1);before=bytes(out)
        motion.left=4
        self.assertEqual(self.lib.dc_camera_secondary_pointer(C.byref(source),C.byref(limits),C.byref(motion),C.byref(out)),4)
        motion.left=0;limits.wheel_step=float('nan')
        self.assertEqual(self.lib.dc_camera_secondary_pointer(C.byref(source),C.byref(limits),C.byref(motion),C.byref(out)),4)
        self.assertEqual(bytes(out),before)
    def test_original_secondary_rectangle_with_integer_truncation(self):
        for width,height,expected in ((1024,768,(0,504,352,264)),(1280,960,(0,630,440,330)),
                                      (1524,1143,(0,750,523,392)),(640,480,(0,315,220,165))):
            main=Viewport(0,0,width,height,0,1);out=Viewport()
            self.assertEqual(self.lib.dc_camera_secondary_viewport(C.byref(main),C.byref(out)),0)
            self.assertEqual((out.x,out.y,out.width,out.height),expected)
            self.assertEqual((out.min_z,out.max_z),(0,1))
        main=Viewport(20,30,1024,768,0,1)
        self.assertEqual(self.lib.dc_camera_secondary_viewport(C.byref(main),C.byref(main)),0)
        self.assertEqual((main.x,main.y,main.width,main.height),(20,534,352,264))
    def test_invalid_viewport_is_atomic(self):
        out=Viewport(1,2,3,4,0,1);before=bytes(out)
        for main in (Viewport(0,0,0,768,0,1),Viewport(0,0,1024,10,0,1),Viewport(0,0,float('nan'),768,0,1)):
            self.assertEqual(self.lib.dc_camera_secondary_viewport(C.byref(main),C.byref(out)),4)
            self.assertEqual(bytes(out),before)

if __name__=='__main__':unittest.main()
