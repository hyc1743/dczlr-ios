import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,MenuState,MenuButton
from menu_cases import cases,native_result


class NativeMenuTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_recorded_original_menu_behavior(self):
        reference=json.loads((ROOT/'tests/fixtures/menu-original-vectors.json').read_text())
        digest=hashlib.sha256();count=0
        for case in cases():
            result=native_result(self.lib,case)
            digest.update((json.dumps({**case,'output':result},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        self.assertEqual(count,reference['cases']);self.assertEqual(digest.hexdigest(),reference['output_sha256'])

    def test_invalid_geometry_and_overlapping_outputs_are_atomic(self):
        state=MenuState();buttons=(MenuButton*1)(MenuButton(0,0,10,10));result=C.c_int32(99)
        for scale in (0,-1,float('nan')):
            self.assertEqual(self.lib.dc_menu_step(C.byref(state),buttons,1,0,0,scale,0,C.byref(result)),4)
            self.assertEqual(result.value,99);self.assertEqual(state.active,0)
        self.assertEqual(self.lib.dc_menu_step(C.byref(state),buttons,33,0,0,1,0,C.byref(result)),1)
        self.assertEqual(self.lib.dc_menu_step(C.byref(state),buttons,1,0,0,1,0,C.cast(C.byref(state),C.POINTER(C.c_int32))),1)

    def test_pointer_release_requires_prior_hover_for_original_activation_code(self):
        state=MenuState(selected=-1,hover=-1);button=(MenuButton*1)(MenuButton(0,0,10,10));result=C.c_int32()
        self.assertEqual(self.lib.dc_menu_step(C.byref(state),button,1,10,10,1,3,C.byref(result)),0)
        self.assertEqual(result.value,3)
        self.assertEqual(self.lib.dc_menu_step(C.byref(state),button,1,10,10,1,3,C.byref(result)),0)
        self.assertEqual(result.value,1)
        self.assertEqual(self.lib.dc_menu_step(C.byref(state),button,1,11,10,1,0,C.byref(result)),0)
        self.assertEqual((result.value,state.active,state.hover),(-1,0,0))


if __name__=='__main__':unittest.main()
