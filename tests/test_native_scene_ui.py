"""Static original context-menu vectors, not a full original gameplay oracle."""
import ctypes as C
from pathlib import Path
import sys
import unittest
import json
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,PPArchive,SceneActionPlan

class Item(C.Structure):
    _fields_=[('resource_id',C.c_int32),('arrangement',C.c_uint32),('x',C.c_float),('y',C.c_float)]
class Menu(C.Structure):
    _fields_=[('icon',C.c_uint32),('count',C.c_uint32),('opening_right',C.c_uint32),('hover',C.c_int32),('items',Item*7)]
class Input(C.Structure):
    _fields_=[(n,C.c_uint32) for n in ('scene_type','icon','stage_progress','animation','camera_mode','secondary_camera_mode')]+[('x',C.c_float),('y',C.c_float)]
class Event(C.Structure):
    _fields_=[('close_code',C.c_uint32),('selected',C.c_int32)]

class SceneUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=library();l=cls.lib
        l.dc_scene_context_build.argtypes=[C.POINTER(Input),C.POINTER(Menu)]
        l.dc_scene_context_hit.argtypes=[C.POINTER(Menu),C.c_float,C.c_float,C.POINTER(C.c_int32)]
        l.dc_scene_context_step.argtypes=[C.POINTER(Menu),C.c_float,C.c_float,C.c_uint32,C.c_uint32,C.POINTER(Event)]
        l.dc_scene_context_resource.argtypes=[C.c_uint32,C.c_uint32,C.c_int32,C.c_uint32,C.c_void_p,C.c_size_t]
        l.dc_scene_icon_uv.argtypes=[C.c_uint32,C.c_uint32,C.POINTER(C.c_float),C.POINTER(C.c_float)]
    def test_outfit_atlas_uses_one_quarter_for_each_original_stage(self):
        for stage,left in enumerate((.5,.25,0)):
            for row in range(1,5):
                u0=C.c_float();u1=C.c_float()
                self.assertEqual(self.lib.dc_scene_icon_uv(stage,row,C.byref(u0),C.byref(u1)),0)
                self.assertEqual((u0.value,u1.value),(left,left+.25) if row==2 else (0,1))
    def test_original_camera_and_system_dispatch_vectors(self):
        evidence=json.loads((ROOT/'tests/fixtures/scene-action-original-vectors.json').read_text())
        self.assertEqual(evidence['cases'],729)
        for row in evidence['vectors']:
            out=SceneActionPlan()
            self.assertEqual(self.lib.dc_scene_action_build(*row['input'],C.byref(out)),0)
            self.assertEqual(out.record(),row['result'])
    def test_unsupported_action_does_not_mutate_the_plan(self):
        out=SceneActionPlan.from_buffer_copy(bytes([0xa5])*C.sizeof(SceneActionPlan));before=bytes(out)
        for args,status in (((4,1,0,0,0),6),((5,3,0,0,0),6),((4,3,7,0,0),4),((4,4,2,0,0),4),((4,3,0,3,0),4)):
            self.assertEqual(self.lib.dc_scene_action_build(*args,C.byref(out)),status)
            self.assertEqual(bytes(out),before)
    def build(self,icon=3,**kw):
        inp=Input(scene_type=4,icon=icon,animation=1,x=968,y=600)
        for k,v in kw.items():setattr(inp,k,v)
        menu=Menu();self.assertEqual(self.lib.dc_scene_context_build(C.byref(inp),C.byref(menu)),0);return menu
    def step(self,menu,x=500,y=384,left=0,right=0):
        event=Event();self.assertEqual(self.lib.dc_scene_context_step(C.byref(menu),x,y,left,right,C.byref(event)),0);return event
    def test_initial_profiles_match_original_generators(self):
        for icon,ids,positions in ((1,[1,2],[6,0]),(2,[],[]),(3,[1,2,4,8,5,7,9],list(range(7))),(4,[1,2],[3,0])):
            m=self.build(icon)
            self.assertEqual([i.resource_id for i in m.items[:m.count]],ids)
            self.assertEqual([i.arrangement for i in m.items[:m.count]],positions)
        self.assertEqual(self.build(1,animation=2).count,0)
        self.assertEqual(self.build(1,animation=11).count,2)
        self.assertEqual(self.build(1,animation=13).count,2)
    def test_camera_disabled_entries_keep_their_original_slots(self):
        m=self.build(camera_mode=2,secondary_camera_mode=2)
        self.assertEqual([i.resource_id for i in m.items],[-1,-1,44,-1,-1,47,9])
        hit=C.c_int32();self.lib.dc_scene_context_hit(C.byref(m),900,495,C.byref(hit));self.assertEqual(hit.value,-1)
    def test_105_35_fan_uses_sprite_pivot_for_hits(self):
        m=self.build()
        self.assertEqual([(i.x,i.y) for i in m.items],[(968,495),(933,530),(898,565),(863,600),(898,635),(933,670),(968,705)])
        hit=C.c_int32()
        for index,item in enumerate(m.items):
            for x,y in ((item.x-216,item.y-16),(item.x+24,item.y+16),(item.x-96,item.y)):
                self.assertEqual(self.lib.dc_scene_context_hit(C.byref(m),x,y,C.byref(hit)),0);self.assertEqual(hit.value,index)
        self.lib.dc_scene_context_hit(C.byref(m),993,705,C.byref(hit));self.assertEqual(hit.value,-1)
    def test_opening_right_press_does_not_dismiss_until_released(self):
        m=self.build()
        for right in (3,1,1):self.assertEqual(self.step(m,right=right).close_code,0)
        self.assertEqual(self.step(m,right=2).close_code,0)
        e=self.step(m,right=3);self.assertEqual((e.close_code,e.selected),(1,-1))
    def test_left_selection_is_context_index_and_dismissal_is_not_a_story_action(self):
        m=self.build(4)
        e=self.step(m,x=872,y=600,left=3)
        self.assertEqual((e.close_code,e.selected),(2,0))
        m=self.build(4);e=self.step(m,x=500,y=600,left=3)
        self.assertEqual((e.close_code,e.selected),(1,-1))
        m=self.build();e=self.step(m,x=872,y=705,left=3)
        self.assertEqual((e.close_code,e.selected),(2,6))
    def test_unknown_states_are_atomic_instead_of_showing_guessed_options(self):
        for change,expected in (({'scene_type':5},6),({'stage_progress':1,'icon':1},6),({'icon':5},4),({'x':float('nan')},4)):
            inp=Input(scene_type=4,icon=3,animation=1,x=968,y=600)
            for k,v in change.items():setattr(inp,k,v)
            menu=Menu.from_buffer_copy(bytes([0xa5])*C.sizeof(Menu));before=bytes(menu)
            self.assertEqual(self.lib.dc_scene_context_build(C.byref(inp),C.byref(menu)),expected);self.assertEqual(bytes(menu),before)
    def test_every_admitted_resource_resolves_in_original_archive(self):
        if not (ROOT/'Data/RPP_02.pp').exists():self.skipTest('private original resource gate')
        with PPArchive(ROOT/'Data/RPP_02.pp') as pp:
            names={pp.entry(i).name_bytes.decode('ascii') for i in range(pp.count)}
        for icon,ids in ((1,[1,2]),(3,[1,2,4,8,5,7,9,44,47]),(4,[1,2])):
            for id in ids:
                for state in range(2):
                    name=C.create_string_buffer(32)
                    self.assertEqual(self.lib.dc_scene_context_resource(4,icon,id,state,name,32),0)
                    self.assertIn(name.value.decode(),names)
        for icon in ('chara','fuku','cam','sys'):
            for state in 'SN':self.assertIn(f'P_{icon}_{state}.ema',names)

if __name__=='__main__':unittest.main()
