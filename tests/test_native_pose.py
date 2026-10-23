import ctypes as C
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library, PoseKey, PoseSelection, Matrix, XAPoseTrack
from pose_cases import key, transform_cases
from xa_cases import u32, block


def fixture(mode=0, frames=(0,8)):
    keys=b''.join(bytes(key(f,.125*i,(i,0,0))) for i,f in enumerate(frames))
    return bytes(3)+b'\1'+bytes(512*108)+u32(1)+block(b'\x9b\x96\x9e\x98\xff')+u32(len(frames))+u32(mode)+keys, keys


class NativePoseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.lib=library()

    def test_original_integer_key_search_and_reference_math_vectors(self):
        reference=json.loads((ROOT/'tests/fixtures/pose-original-vectors.json').read_text())
        for row in reference['selection_vectors']:
            keys=(PoseKey*len(row['frames']))(*(key(f) for f in row['frames']))
            selected=PoseSelection()
            self.assertEqual(self.lib.dc_pose_select(keys,len(keys),row['frame'],C.byref(selected)),0)
            self.assertEqual([selected.left,selected.right],row['selection'])
        cases=list(transform_cases())
        for row in reference['matrix_vectors']:
            source,frame=cases[row['case']];keys=(PoseKey*len(source))(*source)
            result,selected=Matrix(),PoseSelection()
            self.assertEqual(self.lib.dc_pose_select(keys,len(keys),frame,C.byref(selected)),0)
            self.assertEqual(struct.pack('<f',selected.weight).hex(),row['weight_hex'])
            self.assertEqual(self.lib.dc_pose_sample(keys,len(keys),0,frame,C.byref(result)),0)
            for actual,expected in zip(result.values,struct.unpack('<16f',bytes.fromhex(row['matrix_hex']))):
                self.assertLessEqual(abs(actual-expected),5e-5*(1+abs(expected)))
        self.assertEqual(len(reference['matrix_vectors']),reference['matrix_comparisons'])

    def test_fractional_negative_frame_and_original_wrapping_span(self):
        keys=(PoseKey*3)(key(-8),key(0),key(8));out=PoseSelection()
        self.assertEqual(self.lib.dc_pose_select(keys,3,-.9,C.byref(out)),0)
        self.assertEqual((out.left,out.right),(1,2))
        self.assertLess(out.weight,0)
        keys=(PoseKey*2)(key(-2147483648),key(2147483647))
        self.assertEqual(self.lib.dc_pose_select(keys,2,0,C.byref(out)),0)
        self.assertEqual(out.weight,-2147483648)

    def test_xa_pose_keys_offsets_and_canary(self):
        for mode in (0,7):
            data,raw=fixture(mode)
            track=XAPoseTrack();keys=(PoseKey*3)()
            C.memset(keys,0xa5,C.sizeof(keys));before=bytes(keys[2])
            self.assertEqual(self.lib.dc_xa_pose_track_at(data,len(data),0,C.byref(track)),0)
            self.assertEqual((track.key_count,track.mode,track.name_length),(2,mode,5))
            self.assertEqual(data[track.keys_offset:track.keys_offset+104],raw)
            self.assertEqual(self.lib.dc_xa_load_pose_keys(data,len(data),0,keys,3),0)
            self.assertEqual(bytes(keys)[:104],raw)
            self.assertEqual(bytes(keys[2]),before)

    def test_xa_bad_tail_capacity_overlap_empty_and_absent_tracks(self):
        data,_=fixture();track=XAPoseTrack();keys=(PoseKey*2)()
        C.memset(C.byref(track),0xa5,C.sizeof(track));before=bytes(track)
        for size in (0,3,4,4+512*108,len(data)-1):
            self.assertEqual(self.lib.dc_xa_pose_track_at(data,size,0,C.byref(track)),3)
            self.assertEqual(bytes(track),before)
        self.assertEqual(self.lib.dc_xa_pose_track_at(data+b'\0',len(data)+1,0,C.byref(track)),3)
        self.assertEqual(self.lib.dc_xa_load_pose_keys(data,len(data),0,keys,1),4)
        source=C.create_string_buffer(data)
        self.assertEqual(self.lib.dc_xa_load_pose_keys(source,len(data),0,C.cast(source,C.POINTER(PoseKey)),2),1)
        self.assertEqual(self.lib.dc_xa_pose_track_at(data,len(data),1,C.byref(track)),6)
        empty,_=fixture(frames=())
        self.assertEqual(self.lib.dc_xa_load_pose_keys(empty,len(empty),0,None,0),0)

    def test_invalid_numeric_profiles_are_atomic_and_sources_immutable(self):
        keys=(PoseKey*2)(key(0),key(8));out=Matrix()
        C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
        for frame in (float('nan'),float('inf'),2147483648):
            self.assertEqual(self.lib.dc_pose_sample(keys,2,0,frame,C.byref(out)),4)
            self.assertEqual(bytes(out),before)
        self.assertEqual(self.lib.dc_pose_sample(keys,1,0,0,C.byref(out)),1)
        self.assertEqual(self.lib.dc_pose_sample(keys,2,1,0,C.byref(out)),3)
        self.assertEqual(self.lib.dc_pose_sample(keys,2,0,100,C.byref(out)),4)
        keys[1].frame=-1
        self.assertEqual(self.lib.dc_pose_sample(keys,2,0,0,C.byref(out)),4)
        keys[1].frame=8;keys[0].values[3]=0
        self.assertEqual(self.lib.dc_pose_sample(keys,2,0,0,C.byref(out)),4)
        keys[0]=key(0);keys[1].values[6]=float('nan')
        self.assertEqual(self.lib.dc_pose_sample(keys,2,0,0,C.byref(out)),4)
        self.assertEqual(bytes(out),before)
        keys[1]=key(8);original=bytes(keys)
        self.assertEqual(self.lib.dc_pose_sample(keys,2,0,0,C.cast(keys,C.POINTER(Matrix))),1)
        self.assertEqual(bytes(keys),original)
        self.assertEqual(self.lib.dc_pose_select(keys,1048577,0,C.byref(PoseSelection())),1)
        self.assertEqual(self.lib.dc_pose_select(keys,2,0,C.cast(keys,C.POINTER(PoseSelection))),1)
        self.assertEqual(bytes(keys),original)

    def test_row_vector_rotation_scale_translation_and_matrix_alias(self):
        keys=(PoseKey*2)(key(0,0,(2,3,4),(2,3,4)),key(8,0,(2,3,4),(2,3,4)))
        out=Matrix()
        self.assertEqual(self.lib.dc_pose_sample(keys,2,0,4,C.byref(out)),0)
        self.assertEqual(list(out.values),[2,0,0,0,0,3,0,0,0,0,4,0,2,3,4,1])
        parent=Matrix((C.c_float*16)(1,0,0,0,0,1,0,0,0,0,1,0,10,0,0,1))
        self.assertEqual(self.lib.dc_matrix_multiply(C.byref(out),C.byref(parent),C.byref(out)),0)
        self.assertEqual(list(out.values)[12:],[12,3,4,1])
        before=bytes(out);parent.values[0]=float('inf')
        self.assertEqual(self.lib.dc_matrix_multiply(C.byref(out),C.byref(parent),C.byref(out)),4)
        self.assertEqual(bytes(out),before)


if __name__=='__main__': unittest.main()
