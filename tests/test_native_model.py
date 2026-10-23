import ctypes as C
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,Matrix,MaterialValue,Viewport,SpriteVertex
from model_cases import fixture
from scene_cases import matrix


class NativeModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def open(self,**kwargs):
        xx,xa=fixture(**kwargs);handle=C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(handle)),0)
        self.addCleanup(self.lib.dc_model_close,handle)
        return handle,xx,xa

    def test_resource_to_controller_pose_material_hierarchy_and_mesh_projection(self):
        m,xx,xa=self.open();world=matrix();a,b=Matrix(),Matrix();material=MaterialValue()
        self.assertEqual(self.lib.dc_model_tick(m,0,0,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(a)),0)
        self.assertEqual(self.lib.dc_model_material(m,0,C.byref(material)),0)
        self.assertEqual(material.components[3],.25)
        self.assertEqual(self.lib.dc_model_tick(m,100,100,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(b)),0)
        self.assertNotEqual(bytes(a),bytes(b))
        self.assertEqual(self.lib.dc_model_material(m,0,C.byref(material)),0)
        self.assertAlmostEqual(material.components[3],.4375,places=6)
        view=Viewport(0,0,100,100,0,1);vp=matrix(translation=(0,0,.5));out=(SpriteVertex*6)()
        self.assertEqual(self.lib.dc_model_project(m,0,C.byref(vp),C.byref(view),0xffffffff,out,6),0)
        self.assertEqual([(v.u,v.v) for v in out],[(0,0),(1,0),(0,1),(0,1),(1,0),(1,1)])
        self.assertTrue(all(v.rhw==1 and v.z==.5 for v in out))

    def test_transition_clip_chain_and_failed_tick_are_atomic(self):
        m,xx,xa=self.open();world=matrix();before=Matrix();current,ready=C.c_uint32(),C.c_uint32()
        self.assertEqual(self.lib.dc_model_request(m,4,0),0)
        self.assertEqual(self.lib.dc_model_tick(m,500,500,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_query(m,C.byref(current),C.byref(ready)),0)
        self.assertEqual((current.value,ready.value),(1,1))
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(before)),0)
        world.values[0]=float('nan')
        self.assertEqual(self.lib.dc_model_tick(m,10,510,C.byref(world)),4)
        after=Matrix();self.assertEqual(self.lib.dc_model_global(m,1,C.byref(after)),0)
        self.assertEqual(bytes(before),bytes(after))
        self.assertEqual(self.lib.dc_model_request(m,512,0),1)
        self.assertEqual(self.lib.dc_model_query(m,C.byref(current),C.byref(ready)),0)
        self.assertEqual((current.value,ready.value),(1,1))

    def test_unsupported_pose_mode_and_truncated_files_do_not_create_model(self):
        for xx,xa in (fixture(mode=1),(fixture()[0][:-1],fixture()[1]),(fixture()[0],fixture()[1][:-1])):
            m=C.c_void_p(123)
            self.assertIn(self.lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(m)),(3,4))
            self.assertFalse(m)
        self.lib.dc_model_close(None)

    def test_source_overlap_rejected_and_crossfade_not_silently_ignored(self):
        xx,xa=fixture();source=C.create_string_buffer(xx);m=C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(source,len(xx),xa,len(xa),C.byref(m)),0)
        self.addCleanup(self.lib.dc_model_close,m)
        before=source.raw
        self.assertEqual(self.lib.dc_model_global(m,0,C.cast(source,C.POINTER(Matrix))),1)
        self.assertEqual(source.raw,before)
        xx,xa=fixture(blend=100);other=C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(other)),0)
        self.addCleanup(self.lib.dc_model_close,other)
        self.assertEqual(self.lib.dc_model_request(other,4,0),3)
        current,ready=C.c_uint32(),C.c_uint32()
        self.assertEqual(self.lib.dc_model_query(other,C.byref(current),C.byref(ready)),0)
        self.assertEqual((current.value,ready.value),(1,1))


if __name__=='__main__':unittest.main()
