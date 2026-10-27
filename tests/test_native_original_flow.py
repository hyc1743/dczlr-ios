import ctypes as C
import unittest
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from original_flow_cases import (library,FlowState,Meta,Chapter,Result,ExitMetrics,
    Selection,Masks,state,write_scheduler_rows,RAW_BYTES,STRIDE)

class OriginalFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.lib=library()

    def test_profile_includes_post_25_descriptors(self):
        p=Chapter(); self.assertEqual(self.lib.dc_flow_chapter_profile(28,C.byref(p)),0)
        self.assertEqual((p.callback,p.scene_type,p.script,p.last_frame,p.map,p.stage),(0x605510,3,18,2,255,255))
        self.assertNotEqual(self.lib.dc_flow_chapter_profile(29,C.byref(p)),0)

    def test_state_init_preserves_unknown_meta_and_initial_flag(self):
        m=Meta(0,3,0,255,255,255,255,254); s=FlowState()
        self.assertEqual(self.lib.dc_flow_state_init(C.byref(s),C.byref(m)),0)
        self.assertEqual(s.raw[STRIDE],1)
        self.assertEqual(bytes(s.meta),bytes(m))

    def test_scheduler_mutates_only_canonical_state_and_preserves_tail(self):
        s=state(9); rows=[[0,0,1,21,255,255],[0,0,0,0,0,0],[0,0,0,0,0,0]];write_scheduler_rows(s,rows)
        tail=bytes(s.raw[0x2198*3-8:0x2198*3]); result=C.c_uint32(); self.assertEqual(self.lib.dc_flow_scheduler(C.byref(s),C.byref(result)),0)
        self.assertEqual(result.value,1); self.assertEqual(bytes(s.raw[0x2198*3-8:0x2198*3]),tail)
        self.assertEqual((s.raw[0x22],s.raw[0x35],s.raw[0x36],s.raw[0x37]),(5,23,255,255))

    def test_type5_progress_nonzero_routes_selector_24_without_fabricated_timer(self):
        s=state(4,19,5,0);s.raw[0x23]=1;s.raw[0x22]=0
        r=Result(); self.assertEqual(self.lib.dc_flow_scene_exit(C.byref(s),C.byref(ExitMetrics(2,1,1,0,0)),C.byref(r)),0)
        self.assertEqual((s.meta.chapter,s.meta.scene_type,r.callback,r.destination_type),(24,5,0x51abb0,2))

    def test_type6_night_history_is_separate_from_exit(self):
        s=state(5,21,6,2);before=bytes(s.raw);old_a=int.from_bytes(s.raw[2*STRIDE+0xc:2*STRIDE+0xe],'little');old_b=int.from_bytes(s.raw[2*STRIDE+0xe:2*STRIDE+0x10],'little');self.assertEqual(self.lib.dc_flow_night_commit(C.byref(s),2,3),0)
        self.assertEqual((int.from_bytes(s.raw[2*STRIDE+0xc:2*STRIDE+0xe],'little'),int.from_bytes(s.raw[2*STRIDE+0xe:2*STRIDE+0x10],'little')), ((old_a+2)&0xffff,(old_b+3)&0xffff))
        self.assertNotEqual(bytes(s.raw),before)

    def test_selector_requires_shape_and_returns_original_type(self):
        s=state(7,24,2,255);selection=Selection(1,0,1,0,0);r=Result()
        self.assertEqual(self.lib.dc_flow_selector_route(C.byref(s),C.byref(selection),C.byref(r)),0)
        self.assertEqual((s.meta.chapter,s.meta.map,s.meta.stage,r.callback,r.destination_type),(24,0,2,0x489f20,5))
        invalid=Selection(4,0,1,0,0);self.assertNotEqual(self.lib.dc_flow_selector_route(C.byref(s),C.byref(invalid),C.byref(r)),0)

    def test_script_25_and_26_depart_title(self):
        for chapter in (25,26):
            s=state(2,chapter,3,255);r=Result();self.assertEqual(self.lib.dc_flow_script_finish(C.byref(s),C.byref(r)),0)
            self.assertEqual((r.callback,r.destination_type),(0x512370,10))

if __name__=='__main__':unittest.main()
