"""Self-authored model/animation fixture for runtime connection tests."""
import struct
from xx_cases import diagnostic_fixture,name,u32
from pose_cases import key


def fixture(mode=0,blend=0):
    xx=diagnostic_fixture()
    values=[1.0]*17
    materials=name(b'diagnostic\0')+u32(2)
    for i in range(2):
        v=values[:];v[3]=.25+i*.75
        materials+=struct.pack('<17fi',*v,i*8)
    clips=bytearray(512*108)
    for i in (1,2,3,4):
        at=i*108
        struct.pack_into('<f',clips,at+64,.4)
        struct.pack_into('<2f',clips,at+72,0,8)
        clips[at+80]=int(i in (1,3))
        clips[at+82]=int(i in (2,4))
        struct.pack_into('<I',clips,at+83,3 if i==2 else 1)
        struct.pack_into('<I',clips,at+88,blend)
    poses=name(b'synthetic-node\0')+u32(2)+u32(mode)
    poses+=bytes(key(0,-.6,(-.2,0,0),(.85,.85,1)))+bytes(key(8,1.8,(.2,0,0),(1.15,1.15,1)))
    xa=b'\1'+u32(1)+materials+bytes(2)+b'\1'+clips+u32(1)+poses
    return xx,bytes(xa)
