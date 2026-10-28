import ctypes as C
import sys
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,SceneMotionState,SceneMotionInput,SceneMotionEvent
from original_flow_cases import FlowState,Meta,Chapter,Result,ExitMetrics,Selection,library as flow_library


class LongStoryFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=library()
        cls.flow=flow_library()

    def flow_state(self,chapter,scene_type,stage=255,map_value=255):
        state=FlowState();meta=Meta(chapter,scene_type,3,map_value,stage,255,255,254)
        self.assertEqual(self.flow.dc_flow_state_init(C.byref(state),C.byref(meta)),0)
        return state

    def test_all_29_chapter_descriptors_and_script_boundaries(self):
        expected_types=(3,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,2,3,3,3,3)
        for chapter,expected in enumerate(expected_types):
            profile=Chapter()
            self.assertEqual(self.flow.dc_flow_chapter_profile(chapter,C.byref(profile)),0)
            self.assertEqual(profile.scene_type,expected)
        for chapter in (0,1,2,4,6,8,9,11,13,15,16,18,20,22,23,25,26,27,28):
            state=self.flow_state(chapter,3)
            result=Result()
            self.assertEqual(self.flow.dc_flow_script_finish(C.byref(state),C.byref(result)),0)
            if chapter<25:self.assertEqual(state.meta.chapter,chapter+1)
            else:self.assertIn(state.meta.chapter,(24,25,26))

    def test_scene_chapters_route_to_the_next_original_descriptor(self):
        scenes=((3,4,2,0),(5,5,2,0),(7,6,2,0),(10,4,1,0),(12,5,1,0),(14,6,1,0),
                (17,4,0,0),(19,5,0,0),(21,6,0,0))
        for chapter,scene_type,stage,progress in scenes:
            state=self.flow_state(chapter,scene_type,stage,0 if chapter in (3,17) else 1)
            state.raw[stage*0x2198+0x23]=progress
            result=Result();metrics=ExitMetrics(2,1,1,1,0)
            self.assertEqual(self.flow.dc_flow_scene_exit(C.byref(state),C.byref(metrics),C.byref(result)),0)
            self.assertIn(state.meta.chapter,(chapter+1,24,25))
            self.assertNotEqual(result.destination_type,0)

    def test_type5_and_type6_input_states_feed_long_flow_metrics(self):
        motion=SceneMotionState();event=SceneMotionEvent();out=SceneMotionState()
        self.assertEqual(self.lib.dc_scene_motion_init(C.byref(motion),5,2,0,1),0)
        self.assertEqual(self.lib.dc_scene_motion_step(C.byref(motion),C.byref(SceneMotionInput(1,0,0,0,0,3,0,0,0,2)),C.byref(out),C.byref(event)),0)
        motion=SceneMotionState.from_buffer_copy(out)
        self.assertEqual(self.lib.dc_scene_motion_step(C.byref(motion),C.byref(SceneMotionInput(2,0,80,0,0,1,0,0,0,-1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.phase,event.metric_ready), (1,1))
        motion=SceneMotionState();self.assertEqual(self.lib.dc_scene_motion_init(C.byref(motion),6,2,0,0x37),0)
        self.assertEqual(self.lib.dc_scene_motion_context(C.byref(motion),2,C.byref(event)),0)
        self.assertEqual((motion.transition_pending,motion.history_committed,event.transition_action),(1,1,2))


if __name__=='__main__':unittest.main()
