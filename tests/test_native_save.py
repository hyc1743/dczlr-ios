import ctypes as C
import hashlib
import itertools
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,SaveUnlocks
from save_cases import cases


class NativeSaveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_codec_vectors_involution_and_trailing_bytes(self):
        reference=json.loads((ROOT/'tests/fixtures/save-codec-original-vectors.json').read_text())
        digest=hashlib.sha256();count=0
        for data in cases():
            out=C.create_string_buffer(data,len(data)+1)
            self.assertEqual(self.lib.dc_save_transform(out,len(data)),0)
            actual=out.raw[:len(data)];digest.update(len(data).to_bytes(4,'little')+actual);count+=1
            self.assertEqual(out.raw[len(data):],b'\0')
            tail=len(data)%4
            if tail:self.assertEqual(actual[-tail:],data[-tail:])
            self.assertEqual(self.lib.dc_save_transform(out,len(data)),0)
            self.assertEqual(out.raw[:len(data)],data)
        self.assertEqual((count,digest.hexdigest()),(reference['cases'],reference['output_sha256']))

    def test_unlock_offsets_and_flags_without_modifying_record(self):
        for a,b,c in itertools.product((0,1,2,255),repeat=3):
            data=bytearray(0x64c8);data[0x23]=a;data[0x21bb]=b;data[0x4353]=c
            encoded=C.create_string_buffer(bytes(data),len(data))
            self.assertEqual(self.lib.dc_save_transform(encoded,len(data)),0)
            before=encoded.raw;out=SaveUnlocks()
            self.assertEqual(self.lib.dc_save_get_unlocks(encoded,len(data),C.byref(out)),0)
            self.assertEqual((out.edit,out.extra),(int(a==b==c==2),int(a!=0)))
            self.assertEqual(encoded.raw,before)

    def test_invalid_record_arguments_and_overlap_are_atomic(self):
        out=SaveUnlocks(9,8);source=C.create_string_buffer(0x64c8)
        for size in (0,1,0x64c7):
            self.assertEqual(self.lib.dc_save_get_unlocks(source,size,C.byref(out)),3)
            self.assertEqual((out.edit,out.extra),(9,8))
        larger=bytearray(0xea40);larger[0x23]=larger[0x21bb]=larger[0x4353]=2^0x32
        self.assertEqual(self.lib.dc_save_get_unlocks(bytes(larger),len(larger),C.byref(out)),0)
        self.assertEqual((out.edit,out.extra),(1,1))
        self.assertEqual(self.lib.dc_save_get_unlocks(source,0x64c8,C.cast(source,C.POINTER(SaveUnlocks))),1)
        self.assertEqual(self.lib.dc_save_transform(None,1),1)
        self.assertEqual(self.lib.dc_save_transform(None,0),0)
        self.assertEqual(self.lib.dc_save_transform(source,0x80000000),1)

    def test_original_new_game_state_initialization_and_capacity_canary(self):
        reference=json.loads((ROOT/'tests/fixtures/game-state-original-vectors.json').read_text())
        length=reference['state_bytes']
        for pattern in reference['initial_patterns']:
            out=C.create_string_buffer(bytes([pattern])*(length+8),length+8)
            before=out.raw
            self.assertEqual(self.lib.dc_game_state_init(out,length-1),4)
            self.assertEqual(out.raw,before)
            self.assertEqual(self.lib.dc_game_state_init(out,length),0)
            self.assertEqual(hashlib.sha256(out.raw[:length]).hexdigest(),reference['output_sha256'])
            self.assertEqual(out.raw[length:],bytes([pattern])*8)
        self.assertEqual(self.lib.dc_game_state_init(None,length),1)


if __name__=='__main__':unittest.main()
