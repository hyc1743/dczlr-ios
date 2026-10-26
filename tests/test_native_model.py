import ctypes as C
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,Matrix,MaterialValue,Viewport,SpriteVertex,MeshVertex,XXModel,AnimationState,XAInfo
from model_cases import fixture
from scene_cases import matrix
from xx_cases import diagnostic_fixture,fixture as xx_fixture


class NativeModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def open(self,**kwargs):
        xx,xa=fixture(**kwargs);handle=C.c_void_p()
        self.assertEqual(self.lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(handle)),0)
        self.addCleanup(self.lib.dc_model_close,handle)
        return handle,xx,xa

    def test_clipped_projection_uses_rigid_and_skinned_vertex_spaces(self):
        rigid,xx1,xa1=self.open();skinned,xx2,xa2=self.open(skinned=True)
        world=matrix(.3,1.2,(.1,-.2,.25));view=Viewport(0,0,100,100,0,1)
        vp=matrix(translation=(0,0,.5));results=[]
        for model in (rigid,skinned):
            self.assertEqual(self.lib.dc_model_tick(model,100,100,C.byref(world)),0)
            count=C.c_size_t(999)
            args=(model,0,C.byref(vp),C.byref(view),0xffffffff)
            self.assertEqual(self.lib.dc_model_project_clipped(*args,None,0,C.byref(count)),0)
            out=(SpriteVertex*count.value)()
            self.assertEqual(self.lib.dc_model_project_clipped(*args,out,len(out),C.byref(count)),0)
            results.append(out)
        self.assertGreater(len(results[0]),0);self.assertEqual(len(results[0]),len(results[1]))
        for a,b in zip(*results):
            for name in ('x','y','z','rhw','u','v'):self.assertAlmostEqual(getattr(a,name),getattr(b,name),delta=2e-5)

    def test_skinned_and_rigid_node_transform_match_without_double_world(self):
        rigid,xx1,xa1=self.open();skinned,xx2,xa2=self.open(skinned=True)
        world=matrix(.3,1.2,(.1,-.2,.25));view=Viewport(0,0,100,100,0,1);vp=matrix(translation=(0,0,.5))
        a=(SpriteVertex*6)();b=(SpriteVertex*6)();space=C.c_uint32();old=None
        for delta,now in ((0,0),(100,100),(200,300)):
            for model in (rigid,skinned):self.assertEqual(self.lib.dc_model_tick(model,delta,now,C.byref(world)),0)
            self.assertEqual(self.lib.dc_model_project(rigid,0,C.byref(vp),C.byref(view),0xffffffff,a,6),0)
            self.assertEqual(self.lib.dc_model_project(skinned,0,C.byref(vp),C.byref(view),0xffffffff,b,6),0)
            for left,right in zip(a,b):
                for name in ('x','y','z','rhw','u','v'):self.assertAlmostEqual(getattr(left,name),getattr(right,name),places=5)
            self.assertEqual(self.lib.dc_model_vertex_space(rigid,0,C.byref(space)),0);self.assertEqual(space.value,0)
            self.assertEqual(self.lib.dc_model_vertex_space(skinned,0,C.byref(space)),0);self.assertEqual(space.value,1)
            vertices=(MeshVertex*4)();self.assertEqual(self.lib.dc_model_load_vertices(skinned,0,vertices,4),0)
            if old is not None:self.assertNotEqual(bytes(vertices),old)
            old=bytes(vertices)

    def test_failed_skin_tick_preserves_deformed_vertices_and_controller(self):
        model,xx,xa=self.open(skinned=True);world=matrix();self.assertEqual(self.lib.dc_model_tick(model,0,0,C.byref(world)),0)
        before=(MeshVertex*4)();after=(MeshVertex*4)()
        self.assertEqual(self.lib.dc_model_load_vertices(model,0,before,4),0)
        singular=matrix();singular.values[0]=0
        self.assertEqual(self.lib.dc_model_tick(model,100,100,C.byref(singular)),4)
        self.assertEqual(self.lib.dc_model_load_vertices(model,0,after,4),0);self.assertEqual(bytes(before),bytes(after))
        self.assertEqual(self.lib.dc_model_tick(model,100,100,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_load_vertices(model,0,after,4),0);self.assertNotEqual(bytes(before),bytes(after))

    def test_hidden_ancestor_visibility_and_static_skinned_baseline(self):
        xx=diagnostic_fixture(skinned=True);data=bytearray(xx)
        with XXModel(xx) as source:offset=source.at('node',0).matrix_offset+116
        data[offset]=1;source_bytes=bytes(data);model=C.c_void_p()
        self.assertEqual(self.lib.dc_model_open_static(source_bytes,len(source_bytes),C.byref(model)),0)
        self.addCleanup(self.lib.dc_model_close,model);world=matrix();self.assertEqual(self.lib.dc_model_tick(model,0,0,C.byref(world)),0)
        visible=C.c_uint32(123);self.assertEqual(self.lib.dc_model_mesh_visible(model,0,C.byref(visible)),0);self.assertEqual(visible.value,0)
        self.assertEqual(self.lib.dc_model_mesh_visible(model,1,C.byref(visible)),4);self.assertEqual(visible.value,0)

    def test_outfit_parent_visibility_is_inherited_and_reversible(self):
        model,xx,xa=self.open();world=matrix();visible=C.c_uint32()
        self.assertEqual(self.lib.dc_model_tick(model,0,0,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_hide_node(model,0,1),0)
        self.assertEqual(self.lib.dc_model_mesh_visible(model,0,C.byref(visible)),0);self.assertEqual(visible.value,0)
        self.assertEqual(self.lib.dc_model_tick(model,33,33,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_mesh_visible(model,0,C.byref(visible)),0);self.assertEqual(visible.value,0)
        self.assertEqual(self.lib.dc_model_hide_node(model,0,0),0)
        self.assertEqual(self.lib.dc_model_tick(model,33,66,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_mesh_visible(model,0,C.byref(visible)),0);self.assertEqual(visible.value,1)
        self.assertEqual(self.lib.dc_model_hide_node(model,0,2),4)
        self.assertEqual(self.lib.dc_model_hide_node(model,0xffffffff,1),4)

    def test_static_model_uses_baseline_and_world_without_inventing_animation(self):
        xx=diagnostic_fixture();m=C.c_void_p()
        self.assertEqual(self.lib.dc_model_open_static(xx,len(xx),C.byref(m)),0)
        self.addCleanup(self.lib.dc_model_close,m)
        world=matrix(translation=(.2,.3,0));before=Matrix();after=Matrix();material=MaterialValue()
        self.assertEqual(self.lib.dc_model_tick(m,0,0,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(before)),0)
        self.assertEqual(list(before.values),list(world.values))
        self.assertEqual(self.lib.dc_model_material(m,0,C.byref(material)),0)
        self.assertEqual(material.components[3],.625)
        current,ready=C.c_uint32(),C.c_uint32()
        self.assertEqual(self.lib.dc_model_query(m,C.byref(current),C.byref(ready)),0)
        self.assertEqual((current.value,ready.value),(0xffffffff,1))
        state=AnimationState();C.memset(C.byref(state),0xa5,C.sizeof(state));snapshot=bytes(state)
        self.assertEqual(self.lib.dc_model_get_animation(m,C.byref(state)),6);self.assertEqual(bytes(state),snapshot)
        self.assertEqual(self.lib.dc_model_request(m,1,50),6)
        self.assertEqual(self.lib.dc_model_request(m,512,50),1)
        self.assertEqual(self.lib.dc_model_tick(m,0xffffffff,0xffffffff,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(after)),0)
        self.assertEqual(bytes(before),bytes(after))
        vp=matrix(translation=(0,0,.5));view=Viewport(0,0,100,100,0,1);out=(SpriteVertex*6)()
        self.assertEqual(self.lib.dc_model_project(m,0,C.byref(vp),C.byref(view),0xffffffff,out,6),0)
        self.assertAlmostEqual(out[0].x,35,places=5);self.assertAlmostEqual(out[0].y,10,places=5)

    def test_static_failures_remain_atomic_and_animated_entry_stays_strict(self):
        for xx in (diagnostic_fixture()[:-1],xx_fixture(bones=1)):
            m=C.c_void_p(123)
            self.assertIn(self.lib.dc_model_open_static(xx,len(xx),C.byref(m)),(3,4));self.assertFalse(m)
        xx=diagnostic_fixture();m=C.c_void_p(123)
        self.assertEqual(self.lib.dc_model_open(xx,len(xx),None,0,C.byref(m)),1);self.assertFalse(m)
        source=C.create_string_buffer(xx);before=source.raw
        self.assertEqual(self.lib.dc_model_open_static(source,len(xx),C.cast(source,C.POINTER(C.c_void_p))),1)
        self.assertEqual(source.raw,before)
        m=C.c_void_p();self.assertEqual(self.lib.dc_model_open_static(xx,len(xx),C.byref(m)),0)
        self.addCleanup(self.lib.dc_model_close,m);world=matrix();self.assertEqual(self.lib.dc_model_tick(m,0,0,C.byref(world)),0)
        original=Matrix();self.assertEqual(self.lib.dc_model_global(m,1,C.byref(original)),0)
        world.values[0]=float('nan');self.assertEqual(self.lib.dc_model_tick(m,1,1,C.byref(world)),4)
        after=Matrix();self.assertEqual(self.lib.dc_model_global(m,1,C.byref(after)),0);self.assertEqual(bytes(after),bytes(original))

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

    def test_framed_event_tracks_are_admitted_while_pose_controller_runs(self):
        m,xx,xa=self.open(events=True);info=XAInfo()
        self.assertEqual(self.lib.dc_xa_probe(xa,len(xa),C.byref(info)),0)
        self.assertEqual(info.event_tracks,1)
        world=matrix();before=Matrix();after=Matrix();vertices_before=(MeshVertex*4)();vertices_after=(MeshVertex*4)()
        self.assertEqual(self.lib.dc_model_tick(m,0,0,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(before)),0)
        self.assertEqual(self.lib.dc_model_load_vertices(m,0,vertices_before,4),0)
        self.assertEqual(self.lib.dc_model_tick(m,100,100,C.byref(world)),0)
        self.assertEqual(self.lib.dc_model_global(m,1,C.byref(after)),0)
        self.assertEqual(self.lib.dc_model_load_vertices(m,0,vertices_after,4),0)
        self.assertNotEqual(bytes(before),bytes(after))
        self.assertAlmostEqual(vertices_after[0].uv[1]-vertices_before[0].uv[1],100.0/33.0*0.001,places=6)
        snapshot=bytes(vertices_after);world.values[0]=float('nan')
        self.assertEqual(self.lib.dc_model_tick(m,100,200,C.byref(world)),4)
        self.assertEqual(self.lib.dc_model_load_vertices(m,0,vertices_after,4),0)
        self.assertEqual(bytes(vertices_after),snapshot)
        m_u,_,_=self.open(events=True,event_type=1)
        self.assertEqual(self.lib.dc_model_tick(m_u,0,0,C.byref(matrix())),0)
        u_before=(MeshVertex*4)();u_after=(MeshVertex*4)()
        self.assertEqual(self.lib.dc_model_load_vertices(m_u,0,u_before,4),0)
        self.assertEqual(self.lib.dc_model_tick(m_u,100,100,C.byref(matrix())),0)
        self.assertEqual(self.lib.dc_model_load_vertices(m_u,0,u_after,4),0)
        self.assertAlmostEqual(u_after[0].uv[0]-u_before[0].uv[0],100.0/33.0*0.001,places=6)

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
