"""Native story dispatcher tables, chapter-end semantics and menu activation.

The reference digests record the verified native outputs; the isolated
original-function comparison lives in tools/oracle_story.py and requires the
locally supplied hash-pinned executable.
"""
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import (library,StoryState,StoryOutcomes,StoryPlan,StoryChapter,
                         GameMenuActivateInput,GameMenuActivateState,GameMenuActivateResult)
from story_cases import story_cases

class NativeStoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_chapter_profiles_match_recovered_tables(self):
        reference=json.loads((ROOT/'tests/fixtures/story-chapter-profiles.json').read_text())
        digest=hashlib.sha256();count=0
        for chapter in range(26):
            profile=StoryChapter()
            self.assertEqual(self.lib.dc_story_chapter_profile(chapter,C.byref(profile)),0)
            row=[profile.script,profile.last_frame,profile.map,profile.stage,profile.scene,profile.scene_type]
            digest.update((json.dumps([chapter,row],separators=(',',':'))+'\n').encode());count+=1
        self.assertEqual(count,reference['chapters'])
        self.assertEqual(digest.hexdigest(),reference['output_sha256'])

    def test_story_loop_cases(self):
        digest=hashlib.sha256();count=0
        for case in story_cases():
            kind=case[0]
            if kind=='profile':
                profile=StoryChapter()
                self.assertEqual(self.lib.dc_story_chapter_profile(case[1],C.byref(profile)),0)
                row=[profile.script,profile.last_frame,profile.map,profile.stage,profile.scene,profile.scene_type]
            elif kind=='finish_last':
                state=StoryState(chapter=case[1],map=2,stage=0);plan=StoryPlan()
                self.assertNotEqual(self.lib.dc_story_script_finish(C.byref(state),C.byref(plan)),0)
                row=['range']
            elif kind in ('finish_depart','finish_script'):
                chapter=case[1]
                state=StoryState(chapter=chapter,map=2,stage=0);plan=StoryPlan()
                self.assertEqual(self.lib.dc_story_script_finish(C.byref(state),C.byref(plan)),0)
                row=plan.record()
            elif kind=='advance':
                chapter,stage,fa,fb,action=case[1:]
                state=StoryState(chapter=chapter,map=2,stage=stage)
                state.stages[stage].flag_a=fa;state.stages[stage].flag_b=fb
                outcomes=StoryOutcomes(a=(C.c_int32*3)(1,0,0),b=(C.c_int32*3)(0,1,0));plan=StoryPlan()
                self.assertEqual(self.lib.dc_story_advance(C.byref(state),C.byref(outcomes),C.byref(plan)),0)
                row=plan.record()
            elif kind=='menu_action':
                chapter,stage,action=case[1:]
                state=StoryState(chapter=chapter,map=2,stage=stage);plan=StoryPlan()
                self.assertEqual(self.lib.dc_story_menu_action(C.byref(state),action,C.byref(plan)),0)
                row=plan.record()
            else:
                raise AssertionError('unknown case kind')
            digest.update((json.dumps([list(case),row],sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        reference=json.loads((ROOT/'tests/fixtures/story-loop-native-vectors.json').read_text())
        self.assertEqual(count,reference['cases'])
        self.assertEqual(digest.hexdigest(),reference['output_sha256'])

    def test_chapter24_unlock_and_save_roundtrip(self):
        state=StoryState(chapter=23,map=4,stage=0);plan=StoryPlan()
        self.assertEqual(self.lib.dc_story_script_finish(C.byref(state),C.byref(plan)),0)
        record=plan.record()
        self.assertEqual(record['state'][0],24)
        self.assertEqual(record['state'][4],1)
        for i in range(3):self.assertEqual(record['state'][3][i][2],1)
        buffer=C.create_string_buffer(72)
        saved=StoryState(chapter=24,map=0xff,stage=0xff,unlocked=1)
        saved.stages[0].flag_a=1;saved.stages[1].flag_b=1;saved.stages[2].progress=2
        self.assertEqual(self.lib.dc_story_save(C.byref(saved),buffer,72),0)
        loaded=StoryState()
        self.assertEqual(self.lib.dc_story_load(buffer,72,C.byref(loaded)),0)
        self.assertEqual(loaded.chapter,24);self.assertEqual(loaded.map,0xff);self.assertEqual(loaded.stage,0xff)
        self.assertEqual(loaded.unlocked,1);self.assertEqual(loaded.stages[0].flag_a,1)
        self.assertEqual(loaded.stages[1].flag_b,1);self.assertEqual(loaded.stages[2].progress,2)

    def test_menu_activate_dispatch(self):
        cases=[(4,0xffffffff,0,1,0,1,1,0),(4,4,0,1,0,1,2,3),(4,2,0,1,0,1,2,2),
               (4,1,0,1,0,1,2,1),(4,1,2,1,0,1,1,1),(4,3,0,0,0,0,0,0),(4,5,0,1,1,1,2,1)]
        for scene_type,row,counter,press,release,handled,stay,kind in cases:
            state=GameMenuActivateState(toggle_active=1)
            inp=GameMenuActivateInput(scene_type=scene_type,selected_row=row,
                interaction_count=counter,press_edge=press,release_edge=release)
            result=GameMenuActivateResult()
            self.assertEqual(self.lib.dc_game_menu_activate(C.byref(inp),C.byref(state),C.byref(result)),0)
            self.assertEqual((result.handled,result.stay,result.kind),(handled,stay,kind))
        state=GameMenuActivateState(toggle_active=1)
        inp=GameMenuActivateInput(scene_type=4,selected_row=6,interaction_count=0,press_edge=1,release_edge=0)
        result=GameMenuActivateResult()
        self.assertNotEqual(self.lib.dc_game_menu_activate(C.byref(inp),C.byref(state),C.byref(result)),0)

if __name__=='__main__':unittest.main()
