import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,TextState,TextPlan,TextAdvancePlan
from text_cases import state,tick_cases,advance_cases,native_tick,native_advance


class NativeTextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_layout_fade_and_forward_input(self):
        reference=json.loads((ROOT/'tests/fixtures/text-original-vectors.json').read_text())
        for name,source,native in (('tick',tick_cases,native_tick),('advance',advance_cases,native_advance)):
            digest=hashlib.sha256();count=0
            for case in source():
                actual=native(self.lib,case)
                digest.update((json.dumps({**case,'output':actual},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
            self.assertEqual(count,reference['results'][name]['cases'])
            self.assertEqual(digest.hexdigest(),reference['results'][name]['output_sha256'])

    def test_draw_uses_previous_alpha_and_large_delta_advances_one_cell(self):
        body=b'ABCD\r\n';s=state(body);out=TextPlan()
        self.assertEqual(self.lib.dc_text_build_plan(C.byref(s),body,len(body),5000,1000,0,C.byref(out)),0)
        self.assertGreater(out.count,2);self.assertTrue(all((g.color>>24)==0 for g in out.glyphs[:out.count]))
        self.assertEqual(out.next.fade_index,1);self.assertEqual(list(out.next.alpha[:3]),[255,0,0])
        s=TextState.from_buffer_copy(out.next)
        self.assertEqual(self.lib.dc_text_build_plan(C.byref(s),body,len(body),33,1033,0,C.byref(out)),0)
        self.assertEqual(out.glyphs[0].color>>24,255);self.assertEqual(out.glyphs[1].color>>24,0)
        self.assertEqual(out.next.fade_index,2)

    def test_first_click_reveals_then_next_click_loads_following_record(self):
        body=b'ABCD\r\n';s=state(body,current_line=2);advance=TextAdvancePlan()
        self.assertEqual(self.lib.dc_text_advance(C.byref(s),0,C.byref(advance)),0)
        self.assertEqual(advance.load_record,0);self.assertEqual(advance.next.frame,0)
        self.assertEqual(list(advance.next.alpha[:3]),[255]*3);self.assertEqual(advance.next.wait_state,-2)
        tick=TextPlan();s=TextState.from_buffer_copy(advance.next)
        self.assertEqual(self.lib.dc_text_build_plan(C.byref(s),body,len(body),33,1000,0,C.byref(tick)),0)
        s=TextState.from_buffer_copy(tick.next)
        self.assertEqual(self.lib.dc_text_advance(C.byref(s),0,C.byref(advance)),0)
        self.assertEqual(advance.load_record,1);self.assertEqual(advance.next.frame,1)
        self.assertEqual(advance.next.body_bytes,0);self.assertEqual(list(advance.next.alpha),[0]*200)

    def test_initial_and_final_record_state(self):
        body=b'ABCD\r\n';s=state(body,current_line=-1,frame=-1);out=TextAdvancePlan()
        self.assertEqual(self.lib.dc_text_advance(C.byref(s),0,C.byref(out)),0)
        self.assertEqual((out.next.frame,out.next.current_line,out.load_record),(0,0,0))
        s=state(body,frame=2,current_line=2,alpha=[255]*200)
        self.assertEqual(self.lib.dc_text_advance(C.byref(s),0,C.byref(out)),0)
        self.assertEqual((out.finished,out.next.active,out.next.current_line),(1,0,-1))

    def test_invalid_profile_and_overlap_preserve_outputs(self):
        body=b'ABCD\r\n';s=state(body);out=TextPlan();C.memset(C.byref(out),0xa5,C.sizeof(out));before=bytes(out)
        for field,value in (('columns',40),('max_lines',6),('scale',float('nan')),('fade_index',201),('current_line',-2),('active',0)):
            old=getattr(s,field);setattr(s,field,value)
            self.assertEqual(self.lib.dc_text_build_plan(C.byref(s),body,len(body),33,1000,0,C.byref(out)),4)
            self.assertEqual(bytes(out),before);setattr(s,field,old)
        storage=C.create_string_buffer(C.sizeof(out));storage.raw=body+storage.raw[len(body):]
        self.assertEqual(self.lib.dc_text_build_plan(C.byref(s),storage,len(body),33,1000,0,C.cast(storage,C.POINTER(TextPlan))),1)
        self.assertEqual(self.lib.dc_text_build_plan(C.byref(s),body,len(body)-1,33,1000,0,C.byref(out)),4)


if __name__=='__main__':unittest.main()
