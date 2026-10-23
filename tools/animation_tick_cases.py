"""Synthetic inputs for current/pending update ordering and blend deadlines."""
import itertools


def cases():
    clocks = ((100, 200, 99), (100, 200, 100), (100, 200, 150), (100, 200, 199),
              (100, 200, 200), (100, 200, 201), (200, 200, 100),
              (0xfffffffe, 498, 0xfffffffe), (0xfffffffe, 498, 0),
              (0, 0xffffffff, 0x80000000), (0x80000000, 0xffffffff, 1))
    for ordinal, (blend, delta, duration, reverse, fixed, clock) in enumerate(
            itertools.product((0.0, 0.5, 1.0), (0, 16, 1000), (0, 250),
                              (0, 1), (0, 1), clocks)):
        start, end, now = clock
        clips = [{"first_frame": float(i * 20), "last_frame": float(i * 20 + 8),
                  "blend_duration": duration, "loop": 0, "iterations": 17,
                  "reverse": reverse} for i in range(3)]
        timing = [{"duration_seconds": (0.3, 1.0)[ordinal % 2],
                   "next_clip": 2, "loop_limit": 0, "chain": 1} for _ in range(3)]
        yield {"state": {"previous": 2, "current": 0, "pending": 1,
                         "blend_start": start, "blend_end": end, "blend": blend,
                         "frame": 4.0, "pending_frame": 24.0, "fixed_frame": fixed},
               "clips": clips, "timing": timing, "delta": delta,
               "speed": (0.3, 1.0, 1.7)[ordinal % 3], "now": now}


def native_result(lib, case):
    import ctypes as C
    from native_core import AnimationState, AnimationClip, AnimationTiming, AnimationTickResult
    state = AnimationState(**case["state"])
    clips = (AnimationClip * len(case["clips"]))(*(AnimationClip(**clip) for clip in case["clips"]))
    timing = (AnimationTiming * len(case["timing"]))(*(AnimationTiming(**item) for item in case["timing"]))
    output = AnimationTickResult()
    status = lib.dc_animation_tick(C.byref(state), clips, timing, len(clips),
        case["delta"], case["speed"], case["now"], C.byref(output))
    if status:
        raise ValueError(f"Native tick rejected input with status {status}: {case}")
    return {"state": state.record(), "iterations": [clip.iterations for clip in clips],
            "previous_frame": output.previous_frame, "samples": list(output.samples[:output.sample_count])}
