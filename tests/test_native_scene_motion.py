import ctypes as C
import sys
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,SceneMotionState,SceneMotionInput,SceneMotionEvent


class SceneMotionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=library()

    def test_type5_requires_hit_then_metric_then_audio_gate(self):
        state=SceneMotionState();self.assertEqual(self.lib.dc_scene_motion_init(C.byref(state),5,0,0,1),0)
        out=SceneMotionState();event=SceneMotionEvent()
        self.assertEqual(self.lib.dc_scene_motion_step(C.byref(state),C.byref(SceneMotionInput(10,0,0,0,0,3,0,0,0,2)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.clip,out.phase,event.request_clip),(4,2,4))
        state=SceneMotionState.from_buffer_copy(out)
        self.assertEqual(self.lib.dc_scene_motion_step(C.byref(state),C.byref(SceneMotionInput(11,0,80,0,0,1,0,0,0,-1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.clip,out.phase,event.request_clip,event.metric_ready),(1,1,1,1))
        state=SceneMotionState.from_buffer_copy(out)
        self.assertEqual(self.lib.dc_scene_motion_step(C.byref(state),C.byref(SceneMotionInput(12,0,0,0,0,0,0,0,0,-1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.completed,event.completed,event.transition_action),(0,0,0))
        state=SceneMotionState.from_buffer_copy(out)
        self.assertEqual(self.lib.dc_scene_motion_step(C.byref(state),C.byref(SceneMotionInput(13,1,0,0,0,0,0,0,0,-1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.completed,event.completed,event.transition_action),(1,1,2))

    def test_type6_context_counters_and_motion_chain(self):
        state=SceneMotionState();self.assertEqual(self.lib.dc_scene_motion_init(C.byref(state),6,2,0,1),0)
        event=SceneMotionEvent();self.assertEqual(self.lib.dc_scene_motion_context(C.byref(state),0,C.byref(event)),0)
        self.assertEqual((state.clip,state.outcome_a,event.request_clip),(2,1,2))
        state.clip=0x0a
        out=SceneMotionState();self.assertEqual(self.lib.dc_scene_motion_step(C.byref(state),C.byref(SceneMotionInput(0,0,0,0,0,1,0,0,0,-1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.clip,out.pointer_mode,event.request_clip),(0x0b,3,0x0b))

    def test_type6_final_context_is_only_exit_gate(self):
        state=SceneMotionState();self.assertEqual(self.lib.dc_scene_motion_init(C.byref(state),6,1,0,0x37),0)
        event=SceneMotionEvent();self.assertEqual(self.lib.dc_scene_motion_context(C.byref(state),2,C.byref(event)),0)
        self.assertEqual((state.history_committed,state.transition_pending,state.completed,event.history_commit,event.transition_action),(1,1,1,1,2))


if __name__=='__main__':unittest.main()
