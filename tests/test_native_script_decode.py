import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,ScriptControl,ScriptDecoded
from script_decode_cases import cases,native_result,control_array


class NativeScriptDecodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_normal_parser_branch(self):
        reference=json.loads((ROOT/'tests/fixtures/script-decode-original-vectors.json').read_text())
        digest=hashlib.sha256();count=0
        for case in cases():
            actual=native_result(self.lib,case)
            digest.update((json.dumps({**case,'output':actual},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        self.assertEqual(count,reference['cases']);self.assertEqual(digest.hexdigest(),reference['output_sha256'])

    def test_bounded_profile_preserves_outputs_on_failure(self):
        controls=control_array({'controls':[['#C',2]]});out=ScriptDecoded()
        for data,expected in ((b'#cg'+b'x'*18+b'\n#T0000\n\nBody$END',4),
                              (b'#cgshort',3),(b'%C00A01\n#T0000\n\nBody$END',3),
                              (b'#T0000#C1\n\nBody$END',3),(b'#T0000\n\nBody\0$END',3)):
            C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
            self.assertEqual(self.lib.dc_script_decode(data,len(data),0,0,controls,1,C.byref(out)),expected)
            self.assertEqual(bytes(out),before)

    def test_control_order_and_source_overlap(self):
        data=b'#T0000#C01A\n\nBody$END';out=ScriptDecoded()
        controls=control_array({'controls':[['#C',2],['#C',2]]})
        self.assertEqual(self.lib.dc_script_decode(data,len(data),0,0,controls,2,C.byref(out)),0)
        self.assertEqual(bytes(out.controls[0]).split(b'\0')[0],b'01A')
        self.assertEqual(bytes(out.controls[1]),bytes(37))
        source=C.create_string_buffer(data)
        self.assertEqual(self.lib.dc_script_decode(source,len(data),0,0,controls,2,C.cast(source,C.POINTER(ScriptDecoded))),1)
        self.assertEqual(self.lib.dc_script_decode(data,len(data),0,0,controls,12,C.byref(out)),4)
        for n in (0,36):
            controls[0].parameter_bytes=n
            self.assertEqual(self.lib.dc_script_decode(data,len(data),0,0,controls,1,C.byref(out)),4)


if __name__=='__main__':unittest.main()
