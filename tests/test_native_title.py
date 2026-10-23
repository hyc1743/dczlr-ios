import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,TitleState,TitleInput,TitlePlan
from title_cases import cases,native_result


class NativeTitleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_title_routing(self):
        reference=json.loads((ROOT/'tests/fixtures/title-original-vectors.json').read_text())
        digest=hashlib.sha256();count=0
        for case in cases():
            actual=native_result(self.lib,case)
            digest.update((json.dumps({**case,'output':actual},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        self.assertEqual(count,reference['cases'])
        self.assertEqual(digest.hexdigest(),reference['output_sha256'])

    def test_selection_waits_for_both_transition_and_sound(self):
        state=[1,1,0]
        for ready,busy in ((0,0),(0,1),(1,1)):
            result=native_result(self.lib,{'state':state,'input':[ready,busy,3,1,4]})
            self.assertEqual(result,{'state':state,'departed':0,'commands':[]})
        result=native_result(self.lib,{'state':state,'input':[1,0,0,-1,-1]})
        self.assertEqual(result['commands'],[[1,0],[2,1],[3,0]])
        self.assertEqual(result['departed'],1)

    def test_options_ignores_selection_busy_and_keeps_hover(self):
        result=native_result(self.lib,{'state':[6,1,4],'input':[1,1,0,-1,-1]})
        self.assertEqual(result,{'state':[0,1,4],'departed':1,'commands':[[4,2],[5,1],[2,6],[6,0]]})

    def test_initial_transition_can_accept_selection_same_frame(self):
        result=native_result(self.lib,{'state':[0,1,255],'input':[1,0,0,1,0]})
        self.assertEqual(result,{'state':[1,1,0],'departed':0,'commands':[[7,0],[8,2]]})
        result=native_result(self.lib,{'state':[0,0,255],'input':[0,0,0,3,0]})
        self.assertEqual(result,{'state':[0,0,0],'departed':0,'commands':[]})

    def test_invalid_fields_preserve_output(self):
        state=TitleState(0,0,255);input=TitleInput(0,0,0,-1,-1);out=TitlePlan()
        for owner,field,value in ((state,'action',7),(state,'waiting',2),(state,'hover',5),
                                  (input,'selection_busy',2),(input,'transition_ready',2),
                                  (input,'escape_code',256),(input,'menu_result',4)):
            previous=getattr(owner,field);setattr(owner,field,value)
            C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
            self.assertEqual(self.lib.dc_title_build_plan(C.byref(state),C.byref(input),C.byref(out)),4)
            self.assertEqual(bytes(out),before);setattr(owner,field,previous)
        self.assertEqual(self.lib.dc_title_build_plan(None,C.byref(input),C.byref(out)),1)


if __name__=='__main__':unittest.main()
