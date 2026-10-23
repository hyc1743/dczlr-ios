import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from animation_cases import cases
from native_core import library, AnimationClip, AnimationState


class NativeAnimationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def request(self, state, clips, requested, force=0, now=0):
        self.assertEqual(self.lib.dc_animation_request(
            C.byref(state), clips, len(clips), requested, force, now), 0)

    def query(self, state, clips):
        current, ready = C.c_uint32(999), C.c_uint32(999)
        self.assertEqual(self.lib.dc_animation_query(C.byref(state), clips, len(clips),
            C.byref(current), C.byref(ready)), 0)
        return [current.value, ready.value]

    def test_all_recorded_original_request_and_query_outputs(self):
        fixture = json.loads((ROOT / "tests/fixtures/animation-original-vectors.json").read_text())
        digest, count = hashlib.sha256(), 0
        for case in cases():
            state = AnimationState(**case["state"])
            clips = (AnimationClip * len(case["clips"]))(*(AnimationClip(**clip) for clip in case["clips"]))
            self.request(state, clips, case["requested"], case["force"], case["now"])
            output = {"state": state.record(), "iterations": [clip.iterations for clip in clips],
                      "query": self.query(state, clips)}
            digest.update((json.dumps({**case, "output": output}, sort_keys=True, separators=(",", ":")) + "\n").encode())
            count += 1
        self.assertEqual(count, fixture["cases"])
        self.assertEqual(digest.hexdigest(), fixture["output_sha256"])

    def test_immediate_switch_uses_outgoing_duration_and_preserves_pending(self):
        clips = (AnimationClip * 3)(AnimationClip(0, 10, 0, 1, 23),
                                   AnimationClip(20, 40, 1000, 0, 57, 1), AnimationClip())
        state = AnimationState(previous=2, current=0, pending=2, blend_start=123,
                               blend_end=456, blend=0.25, frame=3, pending_frame=91, fixed_frame=1)
        self.request(state, clips, 1, now=999)
        self.assertEqual(state.record(), {"previous": 0, "current": 1, "pending": 2,
            "blend_start": 0, "blend_end": 456, "blend": 1.0, "frame": 40.0,
            "pending_frame": 91.0, "fixed_frame": 0})
        self.assertEqual([c.iterations for c in clips], [23, 0, 0])

    def test_crossfade_keeps_current_and_query_uses_its_loop_flag(self):
        clips = (AnimationClip * 2)(AnimationClip(0, 10, 500, 2, 23),
                                   AnimationClip(20, 40, 0, 0, 57, 2))
        state = AnimationState(previous=1, current=0, pending=0, frame=3, pending_frame=91, fixed_frame=255)
        self.request(state, clips, 1, now=0xfffffffe)
        self.assertEqual((state.previous, state.current, state.pending, state.frame), (1, 0, 1, 3))
        self.assertEqual((state.blend_start, state.blend_end, state.blend, state.pending_frame),
                         (0xfffffffe, 498, 0.0, 20.0))
        self.assertEqual(self.query(state, clips), [0, 1])
        self.assertEqual([c.iterations for c in clips], [23, 0])

    def test_duplicate_requests_clear_fixed_frame_even_when_forced(self):
        clips = (AnimationClip * 2)(AnimationClip(0, 10, 25, 1, 23), AnimationClip(20, 40, 0, 0, 57))
        for current, pending, requested, force in ((0, 1, 1, 0), (0, 1, 1, 255), (0, 1, 0, 0)):
            state = AnimationState(1, current, pending, 10, 35, 0.5, 3, 22, 1)
            expected = state.record()
            expected["fixed_frame"] = 0
            before = bytes(clips)
            self.request(state, clips, requested, force, now=1234)
            self.assertEqual(state.record(), expected)
            self.assertEqual(bytes(clips), before)
        # Force bypasses current==requested only when the pending gate admits it.
        state = AnimationState(current=0, pending=1, frame=3)
        self.request(state, clips, 0, force=1, now=100)
        self.assertEqual((state.current, state.pending, state.pending_frame, state.blend_end), (0, 0, 0, 125))

    def test_last_table_slot_and_optional_query_output(self):
        clips = (AnimationClip * 512)()
        clips[511] = AnimationClip(2, 3, 0, 255, 17, 1)
        state = AnimationState()
        self.request(state, clips, 511)
        self.assertEqual((state.current, state.frame, clips[511].iterations), (511, 3, 0))
        ready = C.c_uint32()
        self.assertEqual(self.lib.dc_animation_query(C.byref(state), clips, 512, None, C.byref(ready)), 0)
        self.assertEqual(ready.value, 1)

    def test_invalid_arguments_preserve_state_records_and_query_outputs(self):
        clips = (AnimationClip * 2)(AnimationClip(0, 10, 25, 1, 23), AnimationClip(20, 40, 0, 0, 57))
        for count, current, requested in ((0, 0, 1), (513, 0, 1), (2, 2, 1), (2, 0, 2)):
            state = AnimationState(current=current, fixed_frame=1)
            before = bytes(state), bytes(clips)
            self.assertEqual(self.lib.dc_animation_request(C.byref(state), clips, count, requested, 1, 0), 1)
            self.assertEqual((bytes(state), bytes(clips)), before)
        state, selected, ready = AnimationState(current=2), C.c_uint32(999), C.c_uint32(998)
        self.assertEqual(self.lib.dc_animation_query(C.byref(state), clips, 2, C.byref(selected), C.byref(ready)), 1)
        self.assertEqual((selected.value, ready.value), (999, 998))
        self.assertEqual(self.lib.dc_animation_request(None, clips, 2, 1, 0, 0), 1)
        self.assertEqual(self.lib.dc_animation_request(C.byref(state), None, 2, 1, 0, 0), 1)
        self.assertEqual(self.lib.dc_animation_query(C.byref(state), clips, 2, C.byref(selected), None), 1)


if __name__ == "__main__":
    unittest.main()
