import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,IntroState,IntroDescriptor,IntroPlan
from intro_cases import table,finish_cases,transition_cases,native_result


class NativeIntroTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_chapter_end_and_transition_dispatch(self):
        reference=json.loads((ROOT/'tests/fixtures/intro-routing-original-vectors.json').read_text())
        for name,source,finish in (('finish',finish_cases,True),('transition',transition_cases,False)):
            digest=hashlib.sha256();count=0
            for case in source():
                actual=native_result(self.lib,case,finish)
                digest.update((json.dumps({**case,'output':actual},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
            self.assertEqual(count,reference['results'][name]['cases'])
            self.assertEqual(digest.hexdigest(),reference['results'][name]['output_sha256'])

    def test_special_script_crosses_fade_out_load_and_fade_in(self):
        descriptors=table();descriptors[1]=[1,31]
        finished=native_result(self.lib,{'state':[0,0,0,0],'table':descriptors},True)
        self.assertEqual(finished,{'state':[1,4,1,0],'departed':0,'commands':[[1,0],[2,2]]})
        pending=native_result(self.lib,{'state':finished['state'],'table':descriptors,'ready':0})
        self.assertEqual(pending['commands'],[])
        loaded=native_result(self.lib,{'state':pending['state'],'table':descriptors,'ready':1})
        self.assertEqual(loaded,{'state':[1,0,1,0],'departed':0,'commands':[[2,4],[3,1]]})
        entered=native_result(self.lib,{'state':loaded['state'],'table':descriptors,'ready':1})
        self.assertEqual(entered,{'state':[1,0,0,0],'departed':0,'commands':[]})

    def test_chapter_progress_and_terminal_flags_remain_distinct(self):
        result=native_result(self.lib,{'state':[24,1,1,0],'table':table(),'ready':1})
        self.assertEqual(result['commands'],[[5,0],[6,24],[11,1]])
        self.assertEqual(result['state'][3],1)
        result=native_result(self.lib,{'state':[25,0,0,2],'table':table()},True)
        self.assertEqual(result,{'state':[25,6,1,2],'departed':0,'commands':[[1,0],[2,2],[4,0]]})

    def test_invalid_descriptors_state_and_wait_leave_output_unchanged(self):
        descriptors=(IntroDescriptor*26)(*(IntroDescriptor(*v) for v in table()))
        s=IntroState(0,0,0,0);p=IntroPlan();C.memset(C.byref(p),0xa5,C.sizeof(p));before=bytes(p)
        descriptors[25].script=-2
        self.assertEqual(self.lib.dc_intro_finish(C.byref(s),descriptors,26,C.byref(p)),4)
        descriptors[25].script=0;s.waiting=1
        self.assertEqual(self.lib.dc_intro_finish(C.byref(s),descriptors,26,C.byref(p)),4)
        self.assertEqual(self.lib.dc_intro_transition(C.byref(s),descriptors,26,2,C.byref(p)),4)
        self.assertEqual(self.lib.dc_intro_transition(C.byref(s),descriptors,25,1,C.byref(p)),4)
        self.assertEqual(bytes(p),before)


if __name__=='__main__':unittest.main()
