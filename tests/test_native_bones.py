import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,XXModel,XXWeights,Matrix
from bone_cases import cases,native_result,model as bone_model
from xx_cases import fixture,node,u32,material
from scene_cases import matrix


class NativeBoneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_bone_loader_and_binding(self):
        reference=json.loads((ROOT/'tests/fixtures/bones-original-vectors.json').read_text())
        digest=hashlib.sha256();count=0
        for case in cases():
            actual=native_result(case)
            digest.update((json.dumps({**case,'output':actual},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        self.assertEqual(count,reference['cases']);self.assertEqual(digest.hexdigest(),reference['output_sha256'])

    def test_per_node_ranges_shared_vertices_and_serialized_ids(self):
        records=[(b'synthetic-node\0',7,bytes(matrix())),(b'synthetic-node\0',19,bytes(matrix(translation=(1,2,3))))]
        shared=bytes((i*17+3)&255 for i in range(104))
        tree=node((node(uv_sets=0,bone_records=records[:1]),),uv_sets=0,bone_records=records,
            shared_vertices=shared,vertex_format=0x141c)
        data=u32(0x404c28f6)+bytes(17)+tree+bytes(4)+u32(1)+material()+u32(0)
        with XXModel(data) as xx:
            a,b=xx.at('skin',0),xx.at('skin',1)
            self.assertEqual((a.first_bone,a.bones,a.shared_count,a.vertex_format),(0,2,2,0x141c))
            self.assertEqual((b.first_bone,b.bones),(2,1));self.assertEqual(xx.span(a.shared_vertices),shared)
            self.assertEqual([xx.at('bone',i).index for i in range(3)],[7,19,7])
            out=Matrix();self.assertEqual(self.lib.dc_xx_bone_matrix(xx.handle,1,C.byref(out)),0)
            self.assertEqual(bytes(out),records[1][2])

    def test_weight_bytes_are_preserved_without_normalization(self):
        raw=b''
        for i,(weights,indices) in enumerate((((.2,.3,.1),(0,1,2,3)),((-.1,.5,.8),(255,0,7,128)),((2,0,-1),(5,5,5,5)))):
            raw+=struct.pack('<I3f3f4B3f2f',i,0,0,0,*weights,*indices,0,0,1,0,0)
        with XXModel(fixture(bones=0,vertices=raw)) as xx:
            out=(XXWeights*3)()
            self.assertEqual(self.lib.dc_xx_load_mesh_weights(xx.handle,0,out,3),0)
            self.assertEqual(bytes(out),b''.join(raw[i*52+16:i*52+32] for i in range(3)))

    def test_bad_names_matrices_weights_and_capacity_do_not_partially_write(self):
        records=[(b'synthetic-node\0',0,bytes(matrix())),(b'bad',1,bytes(matrix()))]
        with XXModel(bone_model(records)) as xx:
            out=(C.c_uint32*2)(123,456);before=bytes(out)
            self.assertEqual(self.lib.dc_xx_bind_bones(xx.handle,1,out,2),3);self.assertEqual(bytes(out),before)
            self.assertEqual(self.lib.dc_xx_bind_bones(xx.handle,1,out,1),4);self.assertEqual(bytes(out),before)
            self.assertEqual(self.lib.dc_xx_bind_bones(xx.handle,0,None,0),0)
            self.assertEqual(self.lib.dc_xx_bind_bones(xx.handle,1,C.cast(xx.source,C.POINTER(C.c_uint32)),2),1)
        transform=matrix();transform.values[15]=float('nan')
        with XXModel(bone_model([(b'carrier\0',0,bytes(transform))])) as xx:
            out=Matrix();C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
            self.assertEqual(self.lib.dc_xx_bone_matrix(xx.handle,0,C.byref(out)),4);self.assertEqual(bytes(out),before)
        raw=struct.pack('<I3f3f4B3f2f',0,0,0,0,0,0,float('nan'),0,0,0,0,0,0,1,0,0)
        with XXModel(fixture(bones=0,vertices=raw,indices=struct.pack('<3H',0,0,0))) as xx:
            out=(XXWeights*1)();C.memset(out,0xa5,C.sizeof(out));before=bytes(out)
            self.assertEqual(self.lib.dc_xx_load_mesh_weights(xx.handle,0,out,1),4);self.assertEqual(bytes(out),before)


if __name__=='__main__':unittest.main()
