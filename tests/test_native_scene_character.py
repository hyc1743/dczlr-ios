import ctypes as C
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import (library,SceneCharacterState,SceneCharacterEvent,AnimationClip,
    AnimationTiming,AnimationState,Matrix,PPArchive)

class CharacterActionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def select(self,state,option):
        out=SceneCharacterEvent()
        self.assertEqual(self.lib.dc_scene_character_select(C.byref(state),4,0,option,C.byref(out)),0)
        return out
    def step(self,state,delta,busy=0):
        out=SceneCharacterEvent()
        self.assertEqual(self.lib.dc_scene_character_step(C.byref(state),delta,busy,C.byref(out)),0)
        return out
    def test_original_delay_boundary_and_separate_sound_wait(self):
        state=SceneCharacterState();event=self.select(state,0)
        self.assertEqual((event.configure_animation,event.request_clip,event.play_slot),(1,0xffffffff,0xffffffff))
        self.assertEqual(self.step(state,1499).request_clip,0xffffffff)
        event=self.step(state,1)
        self.assertEqual((event.request_clip,event.play_slot,event.request_transition),(2,22,0))
        self.assertEqual(self.step(state,10000).request_clip,0xffffffff)
        self.assertEqual(self.select(state,1).play_slot,28)
        for delta in (0,6000,600000):self.assertEqual(self.step(state,delta,1).request_transition,0)
        self.assertEqual(self.step(state,0,0).request_transition,2)
        self.assertEqual(self.step(state,10000,0).request_transition,0)
    def test_repeated_activation_resets_delay_and_saturates_counter(self):
        state=SceneCharacterState(9999,0,0,0,0,0)
        for _ in range(2):
            self.select(state,0);self.step(state,1000)
        self.assertEqual((state.activation_count,state.delay_ms),(10000,1000))
        self.assertEqual(self.step(state,500).request_clip,2)
    def test_unsupported_profile_preserves_all_outputs(self):
        for scene,progress,option in ((5,0,0),(4,1,0),(4,0,2)):
            state=SceneCharacterState(12,345,1,0,0,0);out=SceneCharacterEvent(9,9,9,9)
            before=(bytes(state),bytes(out))
            self.assertNotEqual(self.lib.dc_scene_character_select(C.byref(state),scene,progress,option,C.byref(out)),0)
            self.assertEqual((bytes(state),bytes(out)),before)
    def test_effect_slot_order_and_empty_tail(self):
        for slot,expected in ((0,'se100.wav'),(16,'se321.wav'),(22,'se021.wav'),(28,'se030.wav'),(29,'se031.wav')):
            name=C.create_string_buffer(16)
            self.assertEqual(self.lib.dc_scene_effect_name(slot,name,len(name)),0)
            self.assertEqual(name.value.decode(),expected)
        for slot in range(30,36):
            name=C.create_string_buffer(b'unchanged',16);before=name.raw
            self.assertEqual(self.lib.dc_scene_effect_name(slot,name,len(name)),6 if slot<35 else 4)
            self.assertEqual(name.raw,before)
    def test_recorded_original_animation_configuration(self):
        fixture=json.loads((ROOT/'tests/fixtures/animation-config-original-vectors.json').read_text())
        for row in fixture['vectors']:
            clips=(AnimationClip*512)();timing=(AnimationTiming*512)()
            clips[0].loop=timing[0].loop_limit=timing[0].chain=0xa5;timing[0].next_clip=0xa5a5a5a5
            if row['operation']=='chain':status=self.lib.dc_animation_set_chain(timing,512,0,row['value'])
            else:status=self.lib.dc_animation_set_loop(clips,timing,512,0,row['value'])
            self.assertEqual(status,0)
            self.assertEqual([clips[0].loop,timing[0].loop_limit,timing[0].chain,timing[0].next_clip],row['expected'])
    def test_actual_initial_asset_chain_returns_to_idle(self):
        if not (ROOT/'Data/RPP_08.pp').exists():self.skipTest('private original resource gate')
        with PPArchive(ROOT/'Data/RPP_08.pp') as pp:
            ids={pp.entry(i).name_bytes.decode():i for i in range(pp.count)}
            for prefix in 'bca':
                xx=pp.read(ids[prefix+'m00_01.xx']);xa=pp.read(ids[prefix+'n00_02.xa']);model=C.c_void_p()
                self.assertEqual(self.lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(model)),0)
                try:
                    self.assertEqual(self.lib.dc_model_set_chain(model,6,7),0)
                    self.assertEqual(self.lib.dc_model_set_loop(model,5,1),0)
                    self.assertEqual(self.lib.dc_model_request(model,2,1500),0)
                    world=Matrix((C.c_float*16)(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1));observed=[]
                    for tick in range(1500,10001,50):
                        self.assertEqual(self.lib.dc_model_tick(model,50,tick,C.byref(world)),0)
                        state=AnimationState();self.lib.dc_model_get_animation(model,C.byref(state))
                        if not observed or observed[-1]!=state.current:observed.append(state.current)
                    self.assertEqual(observed,[2,5,6,7,1])
                finally:self.lib.dc_model_close(model)

if __name__=='__main__':unittest.main()
