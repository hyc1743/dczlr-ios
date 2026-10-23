import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from animation_frame_cases import cases, native_result
from native_core import library, AnimationState, AnimationClip, AnimationTiming


class NativeAnimationFrameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def setup_records(self, loop=0, chain=0, iterations=0, limit=0, duration=0):
        clips = (AnimationClip * 3)(AnimationClip(0, 8, duration, loop, iterations),
            AnimationClip(20, 28, 0), AnimationClip(40, 48, 0))
        timing = (AnimationTiming * 3)(*(AnimationTiming(1, 2, limit, chain) for _ in range(3)))
        return clips, timing

    def advance(self, state, clips, timing, lane=0, delta=0, speed=1, now=0):
        result = C.c_float(-12345)
        self.assertEqual(self.lib.dc_animation_advance(C.byref(state), clips, timing, len(clips),
            lane, delta, speed, now, C.byref(result)), 0)
        return result.value

    def test_all_recorded_original_frame_outputs(self):
        fixture = json.loads((ROOT / "tests/fixtures/animation-frames-original-vectors.json").read_text())
        digest, count = hashlib.sha256(), 0
        for case in cases():
            output = native_result(self.lib, case)
            for control_word in fixture["x87_control_words"]:
                digest.update((json.dumps({**case, "control_word": control_word, "output": output},
                              sort_keys=True, separators=(",", ":")) + "\n").encode())
                count += 1
        self.assertEqual(count, fixture["cases"])
        self.assertEqual(digest.hexdigest(), fixture["output_sha256"])

    def test_blending_clamps_without_chaining_and_endpoint_equality_does_not_cross(self):
        clips, timing = self.setup_records(loop=1, chain=1, iterations=7, limit=8)
        state = AnimationState(current=0, pending=1, blend=0.5, frame=6)
        self.assertEqual(self.advance(state, clips, timing, delta=1000), 8)
        self.assertEqual((state.current, clips[0].iterations), (0, 7))
        state.blend = 1
        self.assertEqual(self.advance(state, clips, timing), 8)
        self.assertEqual((state.current, clips[0].iterations), (0, 7))

    def test_multiple_spans_increment_limited_loop_only_once_and_byte_wrap_is_preserved(self):
        clips, timing = self.setup_records(loop=1, chain=1, iterations=5, limit=255)
        state = AnimationState(current=0, pending=1, blend=1, frame=7)
        self.assertEqual(self.advance(state, clips, timing, delta=4000), 7)
        self.assertEqual((state.current, clips[0].iterations), (0, 6))
        clips[0].iterations = 255
        timing[0].loop_limit = 2
        state.frame = 7
        self.assertEqual(self.advance(state, clips, timing, delta=1000), 7)
        self.assertEqual((state.current, clips[0].iterations), (0, 0))

    def test_plain_loop_does_not_change_iteration_byte_and_reverse_wraps(self):
        clips, timing = self.setup_records(loop=1, chain=0, iterations=57)
        state = AnimationState(current=0, pending=1, blend=1, frame=7)
        self.assertEqual(self.advance(state, clips, timing, delta=1000), 7)
        self.assertEqual(clips[0].iterations, 57)
        clips[0].reverse = 1
        state.frame = 1
        self.assertEqual(self.advance(state, clips, timing, delta=1000), 1)
        self.assertEqual(clips[0].iterations, 57)

    def test_pending_lane_chain_preserves_original_return_pointer_behavior(self):
        for duration, expected in ((0, 36), (250, 40)):
            clips, timing = self.setup_records(duration=duration)
            timing[1].chain = 1
            state = AnimationState(current=0, pending=1, blend=1, frame=6, pending_frame=28)
            self.assertEqual(self.advance(state, clips, timing, lane=1, delta=1000), expected)
            if duration:
                self.assertEqual((state.current, state.pending, state.frame, state.pending_frame), (0, 2, 6, 40))
            else:
                self.assertEqual((state.current, state.pending, state.frame, state.pending_frame), (2, 1, 40, 36))

    def test_exact_frozen_flag_returns_current_even_for_pending_lane(self):
        clips, timing = self.setup_records()
        state = AnimationState(current=0, pending=999, blend=1, frame=3, pending_frame=27, fixed_frame=1)
        before = bytes(state), bytes(clips), bytes(timing)
        self.assertEqual(self.advance(state, clips, timing, lane=1, delta=0xffffffff, speed=float("nan")), 3)
        self.assertEqual((bytes(state), bytes(clips), bytes(timing)), before)
        state.pending = 1
        state.fixed_frame = 255
        self.assertEqual(self.advance(state, clips, timing, lane=1, delta=125), 28)

    def test_invalid_or_nonprogressing_wraps_fail_atomically(self):
        for scenario in ("bad_chain", "nan_target", "zero_span", "wrap_limit", "nan_speed", "bad_lane"):
            clips, timing = self.setup_records(loop=1)
            state = AnimationState(current=0, pending=1, blend=1, frame=7)
            delta, speed, lane = 1000, 1, 0
            if scenario == "bad_chain":
                timing[0].chain, timing[0].next_clip = 1, 3
                clips[0].loop = 0
            elif scenario == "nan_target":
                timing[0].chain = 1
                clips[0].loop, clips[2].first_frame = 0, float("nan")
            elif scenario == "zero_span":
                clips[0].last_frame = 0
            elif scenario == "wrap_limit":
                delta = 5000000
            elif scenario == "nan_speed":
                speed = float("nan")
            else:
                lane = 2
            result = C.c_float(-12345)
            before = bytes(state), bytes(clips), bytes(timing), bytes(result)
            status = self.lib.dc_animation_advance(C.byref(state), clips, timing, 3,
                lane, delta, speed, 0, C.byref(result))
            self.assertIn(status, (1, 4))
            self.assertEqual((bytes(state), bytes(clips), bytes(timing), bytes(result)), before, scenario)


if __name__ == "__main__":
    unittest.main()
