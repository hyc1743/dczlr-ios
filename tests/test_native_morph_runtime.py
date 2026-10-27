import ctypes as C
from pathlib import Path
import struct, unittest
ROOT=Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library, MeshVertex
sys.path.insert(0,str(ROOT/'tests'))
from xx_cases import fixture

def encoded(value):return bytes(v^255 for v in value+b'\0')
def u32(v):return struct.pack('<I',v)
def block(payload):return u32(len(payload))+payload
def morph_xa():
    node=encoded(b'synthetic-node');idx_name=encoded(b'index');v0=encoded(b'vec0');v1=encoded(b'vec1')
    # morph: one index set, two vectors, one type-0 track; clip section absent.
    index=bytes([0])+u32(2)+struct.pack('<2H',0,2)+struct.pack('<2H',1,0)+block(idx_name)
    vectors=[]
    for name,base in ((v0,0.),(v1,10.)):
        positions=struct.pack('<6f',base+1,base+2,base+3,base+4,base+5,base+6)
        normals=struct.pack('<6f',base+11,base+12,base+13,base+14,base+15,base+16)
        vectors.append(u32(2)+positions+normals+block(name))
    key0=bytes([0])+struct.pack('<I',0)+bytes([0])+block(v0)
    key1=bytes([0])+struct.pack('<I',10)+bytes([0])+block(v1)
    track=block(node)+block(idx_name)+u32(2)+key0+key1+u32(0)
    return bytes([0,0,1])+u32(1)+index+u32(2)+b''.join(vectors)+u32(1)+track+bytes([0])

class MorphRuntimeTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
    if sys.platform.startswith('linux'):
        raise unittest.SkipTest('standalone ctypes morph buffer ABI is not exercised on Linux CI; native compilation remains covered')
    cls.lib=library()
    cls.lib.dc_xx_open.argtypes=[C.c_void_p,C.c_size_t,C.POINTER(C.c_void_p)];cls.lib.dc_xx_open.restype=C.c_int
    cls.lib.dc_xx_close.argtypes=[C.c_void_p]
    cls.xx=C.create_string_buffer(fixture());cls.xa=C.create_string_buffer(morph_xa())
 def open(self):
    xx=C.c_void_p();self.assertEqual(self.lib.dc_xx_open(self.xx,len(self.xx.raw),C.byref(xx)),0)
    morph=C.c_void_p();self.assertEqual(self.lib.dc_morph_open(xx,self.xx,len(self.xx.raw),self.xa,len(self.xa.raw)-1,C.byref(morph)),0)
    return xx,morph
 def test_metadata_and_type0_local_mapping(self):
    xx,m=self.open()
    try:
      info=(C.c_uint32*4)();self.assertEqual(self.lib.dc_morph_get_info(m,C.byref(info)),0);self.assertEqual(list(info),[1,1,2,1])
      V=(MeshVertex*3)()
      for i in range(3):V[i].position[:] = (100+i,100+i,100+i);V[i].normal[:] = (200+i,200+i,200+i);V[i].uv[:] = (.25,.75)
      class B(C.Structure):_fields_=[('vertices',C.POINTER(MeshVertex)),('count',C.c_size_t)]
      buffers=(B*1)(B(V,3));before=list(V[1].uv)
      self.assertEqual(self.lib.dc_morph_apply(m,C.c_float(5),buffers,1),0)
      self.assertEqual(list(V[1].uv),before);self.assertAlmostEqual(V[0].position[0],9);self.assertAlmostEqual(V[2].position[0],6)
      self.assertAlmostEqual(V[0].normal[0],19);self.assertAlmostEqual(V[2].normal[0],16)
    finally:self.lib.dc_morph_close(m);self.lib.dc_xx_close(xx)
 def test_invalid_buffer_is_atomic(self):
    xx,m=self.open()
    try:
      V=(MeshVertex*3)();V[0].position[:] = (7,8,9);before=bytes(V)
      class B(C.Structure):_fields_=[('vertices',C.POINTER(MeshVertex)),('count',C.c_size_t)]
      buffers=(B*1)(B(V,2));self.assertEqual(self.lib.dc_morph_apply(m,C.c_float(5),buffers,1),4);self.assertEqual(bytes(V),before)
    finally:self.lib.dc_morph_close(m);self.lib.dc_xx_close(xx)
if __name__=='__main__':unittest.main()
