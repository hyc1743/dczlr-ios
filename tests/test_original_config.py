import ctypes as C
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library

class OriginalConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=library()
        for name,args in {
            'default':[C.c_void_p],'reset':[C.c_void_p],
            'decode':[C.c_void_p,C.c_size_t,C.c_void_p],
            'encode':[C.c_void_p,C.c_void_p,C.c_size_t],
            'slider_apply':[C.c_void_p,C.c_uint32,C.c_float],
            'switch_toggle':[C.c_void_p,C.c_uint32],
        }.items():
            fn=getattr(cls.lib,'dc_config_'+name);fn.argtypes=args;fn.restype=C.c_int
        cls.reference=json.loads((ROOT/'tests/fixtures/config-slider-original-vectors.json').read_text())
    def test_all_sliders_match_original_instruction_vectors_bit_for_bit(self):
        names=[s['name'] for s in self.reference['specs']]
        initial=bytes.fromhex(self.reference['reset']['actual_hex'])
        for row in self.reference['vectors']:
            state=C.create_string_buffer(initial,48);offset=row['cfg_offset']
            self.assertEqual(self.lib.dc_config_slider_apply(state,names.index(row['name']),row['requested_center_f32']),0)
            self.assertEqual(state.raw[offset:offset+4].hex(),row['value_bits'],row)
            self.assertEqual(state.raw[:offset],initial[:offset]);self.assertEqual(state.raw[offset+4:],initial[offset+4:])
    def test_reset_preserves_original_structure_padding(self):
        row=self.reference['reset'];state=C.create_string_buffer(bytes.fromhex(row['initial_hex']),48)
        self.assertEqual(self.lib.dc_config_reset(state),0);self.assertEqual(state.raw.hex(),row['actual_hex'])
    def test_raw_config_round_trip_keeps_opaque_padding_and_rejects_invalid_values_atomically(self):
        raw=bytes.fromhex(self.reference['reset']['actual_hex']);state=C.create_string_buffer(48);out=C.create_string_buffer(52)
        self.assertEqual(self.lib.dc_config_decode(raw+b'extra',53,state),0)
        self.assertEqual(self.lib.dc_config_encode(state,out,52),0);self.assertEqual(out.raw[:48],raw)
        for value in (float('nan'),float('inf'),-1,11):
            invalid=raw[:44]+struct.pack('<f',value);before=state.raw
            self.assertEqual(self.lib.dc_config_decode(invalid,48,state),3);self.assertEqual(state.raw,before)
        self.assertEqual(self.lib.dc_config_decode(raw,47,state),4)
    def test_switches_change_only_their_original_bytes(self):
        raw=bytes.fromhex(self.reference['reset']['actual_hex'])
        for index,offset in enumerate((27,28,29,25,24,26)):
            state=C.create_string_buffer(raw,48);self.assertEqual(self.lib.dc_config_switch_toggle(state,index),0)
            expected=bytearray(raw);expected[offset]^=1;self.assertEqual(state.raw,bytes(expected))
            self.assertEqual(self.lib.dc_config_switch_toggle(state,index),0);self.assertEqual(state.raw,raw)
        before=state.raw
        self.assertEqual(self.lib.dc_config_switch_toggle(state,6),4);self.assertEqual(state.raw,before)

if __name__=='__main__':unittest.main()
