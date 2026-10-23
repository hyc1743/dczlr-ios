import ctypes as C
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library, XXModel, MeshVertex, Matrix, Viewport, SpriteVertex
from xx_cases import fixture
from scene_cases import matrix


class NativeMeshTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_xx_vertex_offsets_ignore_id_weights_and_bone_indices(self):
        data=bytearray(fixture())
        with XXModel(bytes(data)) as model:mesh=model.at('submesh',0)
        expected=[]
        for i in range(3):
            pos=(i+.1,i+.2,i+.3);normal=(i+.4,i+.5,i+.6);uv=(i+.7,i+.8)
            expected.append(struct.pack('<8f',*pos,*normal,*uv))
            record=struct.pack('<I3f3f4B3f2f',0xdeadbeef,*pos,float('nan'),-99,500,255,255,255,255,*normal,*uv)
            data[mesh.vertices.offset+i*52:mesh.vertices.offset+(i+1)*52]=record
        with XXModel(bytes(data)) as model:
            out=(MeshVertex*4)();C.memset(out,0xa5,C.sizeof(out));canary=bytes(out[3])
            self.assertEqual(self.lib.dc_xx_load_mesh_vertices(model.handle,0,out,4),0)
            self.assertEqual(bytes(out)[:96],b''.join(expected));self.assertEqual(bytes(out[3]),canary)
            indices=(C.c_uint16*3)()
            self.assertEqual(self.lib.dc_xx_load_mesh_indices(model.handle,0,indices,3),0)
            self.assertEqual(list(indices),[0,1,2])

    def test_xx_mesh_bad_indices_nonfinite_and_overlap_are_atomic(self):
        data=bytearray(fixture())
        with XXModel(bytes(data)) as model:mesh=model.at('submesh',0)
        struct.pack_into('<H',data,mesh.indices.offset+4,99)
        struct.pack_into('<f',data,mesh.vertices.offset+2*52+44,float('nan'))
        with XXModel(bytes(data)) as model:
            out=(MeshVertex*3)();indices=(C.c_uint16*3)(9,9,9);C.memset(out,0xa5,C.sizeof(out));before=bytes(out)
            self.assertEqual(self.lib.dc_xx_load_mesh_indices(model.handle,0,indices,3),3)
            self.assertEqual(list(indices),[9,9,9])
            self.assertEqual(self.lib.dc_xx_load_mesh_vertices(model.handle,0,out,3),4)
            self.assertEqual(bytes(out),before)
            self.assertEqual(self.lib.dc_xx_load_mesh_vertices(model.handle,0,out,2),4)
            self.assertEqual(self.lib.dc_xx_load_mesh_vertices(model.handle,0,C.cast(model.source,C.POINTER(MeshVertex)),3),1)

    def test_indexed_projection_preserves_order_uv_and_reciprocal_w(self):
        vertices=(MeshVertex*3)()
        for v,xyz,uv in zip(vertices,((-1,1,.5),(1,1,.5),(-1,-1,.5)),((0,0),(1,0),(0,1))):
            v.position[:]=xyz;v.uv[:]=uv
        indices=(C.c_uint16*3)(2,0,1);mvp=matrix();view=Viewport(10,20,100,200,0,1);out=(SpriteVertex*3)()
        self.assertEqual(self.lib.dc_mesh_project(vertices,3,indices,3,C.byref(mvp),C.byref(view),0x80402010,out,3),0)
        self.assertEqual([(v.x,v.y,v.z,v.rhw,v.diffuse,v.u,v.v) for v in out],
            [(10,220,.5,1,0x80402010,0,1),(10,20,.5,1,0x80402010,0,0),(110,20,.5,1,0x80402010,1,0)])
        mvp.values[15]=2
        self.assertEqual(self.lib.dc_mesh_project(vertices,3,indices,3,C.byref(mvp),C.byref(view),0xffffffff,out,3),0)
        self.assertEqual((out[0].x,out[0].y,out[0].rhw),(35,170,.5))

    def test_projection_rejects_late_invalid_index_and_behind_eye_without_writes(self):
        vertices=(MeshVertex*3)();indices=(C.c_uint16*3)(0,1,99);mvp=matrix();view=Viewport(0,0,100,100,0,1)
        out=(SpriteVertex*3)();C.memset(out,0xa5,C.sizeof(out));before=bytes(out)
        args=(vertices,3,indices,3,C.byref(mvp),C.byref(view),0xffffffff,out,3)
        self.assertEqual(self.lib.dc_mesh_project(*args),4);self.assertEqual(bytes(out),before)
        indices[2]=2;mvp.values[15]=-1
        self.assertEqual(self.lib.dc_mesh_project(*args),4);self.assertEqual(bytes(out),before)
        mvp.values[15]=1;vertices[2].position[1]=float('nan')
        self.assertEqual(self.lib.dc_mesh_project(*args),4);self.assertEqual(bytes(out),before)
        vertices[2].position[1]=0
        self.assertEqual(self.lib.dc_mesh_project(vertices,3,indices,3,C.byref(mvp),C.byref(view),0xffffffff,C.cast(vertices,C.POINTER(SpriteVertex)),3),1)


if __name__=='__main__':unittest.main()
