import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,SaveSlotMeta
from save_slot_cases import cases

class OriginalSaveSlotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def test_matches_original_writer_bytes_and_restores_all_unknown_state(self):
        reference=json.loads((ROOT/'tests/fixtures/save-slot-original-vectors.json').read_text(encoding='utf-8'))
        self.assertEqual(len(list(cases())),reference['cases']);self.assertEqual(len(reference['vectors']),reference['cases'])
        for (seed,state,meta),row in zip(cases(),reference['vectors']):
            out=C.create_string_buffer(0xea40+4);out.raw=b'\xa5'*len(out);before=state
            self.assertEqual(self.lib.dc_save_slot_encode(state,len(state),C.byref(meta),out,len(out)),0)
            slot=out.raw[:0xea40]
            self.assertEqual(hashlib.sha256(slot).hexdigest(),row['sha256'])
            self.assertEqual(row['chunk_lengths'],[0x64c8,1,0x6414,0x215c,1,1,1,3,1])
            self.assertEqual(out.raw[0xea40:],b'\xa5'*4);self.assertEqual(state,before)
            restored=C.create_string_buffer(0xea38+4);restored.raw=b'\xa5'*len(restored);loaded=SaveSlotMeta()
            self.assertEqual(self.lib.dc_save_slot_decode(slot+b'ignored trailing data',len(slot)+21,restored,len(restored),C.byref(loaded)),0)
            self.assertEqual(restored.raw[:0xea38],state);self.assertEqual(bytes(loaded),bytes(meta))
            self.assertEqual(restored.raw[0xea38:],b'\xa5'*4)
    def test_chapter_insertion_restarts_the_next_xor_window(self):
        state=bytes(0xea38);meta=SaveSlotMeta(25,3,4,255,2,128,129,74);out=C.create_string_buffer(0xea40)
        self.lib.dc_save_slot_encode(state,len(state),C.byref(meta),out,len(out));slot=out.raw
        self.assertEqual(slot[0x64c4:0x64cd],b'\x2e\xcd\xb7\x32\x19\x2e\xcd\xb7\x32')
        self.assertEqual(slot[0xea39:],bytes((3,4,255,2,128,129,74)))
    def test_truncated_inputs_and_overlapping_outputs_are_atomic(self):
        state=C.create_string_buffer(bytes(0xea38));meta=SaveSlotMeta();out=C.create_string_buffer(b'\xa5'*0xea40,0xea40);before=out.raw
        self.assertEqual(self.lib.dc_save_slot_encode(state,0xea37,C.byref(meta),out,len(out)),4);self.assertEqual(out.raw,before)
        self.assertEqual(self.lib.dc_save_slot_encode(state,0xea38,C.byref(meta),state,len(state)),1)
        restored=C.create_string_buffer(b'\xa5'*0xea38,0xea38);meta=SaveSlotMeta.from_buffer_copy(bytes([0xa5])*8)
        self.assertEqual(self.lib.dc_save_slot_decode(out,0xea3f,restored,len(restored),C.byref(meta)),4)
        self.assertEqual(restored.raw,b'\xa5'*0xea38);self.assertEqual(bytes(meta),bytes([0xa5])*8)
        alias=C.cast(restored,C.POINTER(SaveSlotMeta))
        self.assertEqual(self.lib.dc_save_slot_decode(out,len(out),restored,len(restored),alias),1)
    def test_slot_names_follow_original_eighty_slot_sequence(self):
        for slot in range(80):
            name=C.create_string_buffer(16);self.assertEqual(self.lib.dc_save_slot_name(slot,name,len(name)),0)
            self.assertEqual(name.value.decode(),f'RP_{slot:02d}.sav')
        name=C.create_string_buffer(b'unchanged',16);before=name.raw
        self.assertEqual(self.lib.dc_save_slot_name(80,name,len(name)),4)
        self.assertEqual(self.lib.dc_save_slot_name(0,name,3),4);self.assertEqual(name.raw,before)

if __name__=='__main__':unittest.main()
