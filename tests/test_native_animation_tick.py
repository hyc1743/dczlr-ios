import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from animation_tick_cases import cases, native_result
from native_core import library, AnimationState, AnimationClip, AnimationTiming, AnimationTickResult
from native_core import StartupState, StartupInput, StartupPlan


class NativeAnimationTickTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def tick(self, state, clips, timing, delta=0, now=0):
        result = AnimationTickResult()
        self.assertEqual(self.lib.dc_animation_tick(C.byref(state), clips, timing, len(clips),
            delta, 1, now, C.byref(result)), 0)
        return result

    def test_all_recorded_original_animated_track_updates(self):
        fixture = json.loads((ROOT / "tests/fixtures/animation-tick-original-vectors.json").read_text())
        digest, count = hashlib.sha256(), 0
        for case in cases():
            output = native_result(self.lib, case)
            for control_word in fixture["x87_control_words"]:
                digest.update((json.dumps({**case, "control_word": control_word, "output": output},
                              sort_keys=True, separators=(",", ":")) + "\n").encode())
                count += 1
        self.assertEqual(count, fixture["cases"])
        self.assertEqual(digest.hexdigest(), fixture["output_sha256"])

    def test_blend_samples_both_lanes_before_promotion(self):
        clips = (AnimationClip * 2)(AnimationClip(0, 8), AnimationClip(20, 28))
        timing = (AnimationTiming * 2)(AnimationTiming(1), AnimationTiming(1))
        state = AnimationState(current=0, pending=1, blend_start=100, blend_end=200,
                               blend=0.5, frame=4, pending_frame=24)
        result = self.tick(state, clips, timing, delta=125, now=200)
        self.assertEqual((result.previous_frame, list(result.samples), result.sample_count), (4, [5, 25], 2))
        self.assertEqual((state.previous, state.current, state.pending, state.frame, state.blend), (0, 1, 0, 25, 1))

    def test_deadline_comparison_preserves_original_wrap_behavior(self):
        clips = (AnimationClip * 2)(AnimationClip(0, 8), AnimationClip(20, 28))
        timing = (AnimationTiming * 2)(AnimationTiming(1), AnimationTiming(1))
        state = AnimationState(current=0, pending=1, blend_start=0xfffffffe, blend_end=498,
                               blend=0.5, frame=4, pending_frame=24)
        self.tick(state, clips, timing, now=0xfffffffe)
        self.assertEqual((state.current, state.pending, state.blend), (1, 0, 1))

    def test_failure_in_pending_lane_rolls_back_current_and_result(self):
        clips = (AnimationClip * 2)(AnimationClip(0, 8), AnimationClip(20, 28))
        timing = (AnimationTiming * 2)(AnimationTiming(1), AnimationTiming(float("nan")))
        state = AnimationState(current=0, pending=1, blend=0.5, frame=4, pending_frame=24)
        result = AnimationTickResult()
        C.memset(C.byref(result), 0xa5, C.sizeof(result))
        before = bytes(state), bytes(clips), bytes(timing), bytes(result)
        self.assertEqual(self.lib.dc_animation_tick(C.byref(state), clips, timing, 2,
            125, 1, 100, C.byref(result)), 4)
        self.assertEqual((bytes(state), bytes(clips), bytes(timing), bytes(result)), before)

    def test_synthetic_transition_table_drives_complete_two_card_planner(self):
        # Self-authored numeric clips stand in for the host's future XA loader.
        # No assets, pose sampling or rendering are involved in this integration.
        clips = (AnimationClip * 5)(*(AnimationClip(0, 8) for _ in range(5)))
        timing = (AnimationTiming * 5)(*(AnimationTiming(0.25) for _ in range(5)))
        clips[1].loop = clips[3].loop = 1
        timing[2].chain, timing[2].next_clip = 1, 3
        timing[4].chain, timing[4].next_clip = 1, 1
        animation = AnimationState(current=1, blend=1)
        plan, startup, trace = StartupPlan(), StartupState(), []

        def apply(plan):
            nonlocal startup
            for action in plan.actions[:plan.count]:
                trace.append([action.kind, action.value])
                if action.kind == 1:
                    self.assertEqual(self.lib.dc_animation_request(C.byref(animation), clips, 5, action.value, 0, 0), 0)
            startup = StartupState.from_buffer_copy(plan.next)

        def update(delta=0, skip=0):
            current, ready = C.c_uint32(), C.c_uint32()
            self.assertEqual(self.lib.dc_animation_query(C.byref(animation), clips, 5,
                C.byref(current), C.byref(ready)), 0)
            input = StartupInput(delta, current.value, ready.value, skip)
            self.assertEqual(self.lib.dc_startup_build_plan(C.byref(startup), C.byref(input), C.byref(plan)), 0)
            apply(plan)

        self.assertEqual(self.lib.dc_startup_begin_plan(C.byref(plan)), 0)
        apply(plan)
        self.assertEqual(animation.current, 4)
        self.tick(animation, clips, timing, delta=251)
        self.assertEqual(animation.current, 1)
        update()
        update(delta=2000)
        self.assertEqual(animation.current, 2)
        self.tick(animation, clips, timing, delta=251)
        self.assertEqual(animation.current, 3)
        update()
        self.assertEqual((startup.card, animation.current), (1, 4))
        self.tick(animation, clips, timing, delta=251)
        update()
        update(skip=3)
        self.assertEqual(animation.current, 3)
        update()
        self.assertEqual(startup.advanced, 1)
        self.assertEqual(trace, [[1, 3], [2, 0], [1, 4], [1, 2], [2, 1], [1, 4], [1, 3], [3, 0], [4, 0]])


if __name__ == "__main__":
    unittest.main()
