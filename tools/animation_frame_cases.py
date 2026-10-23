"""Synthetic inputs for isolated numeric animation advancement."""
import itertools


def native_result(lib, case):
    import ctypes as C
    from native_core import AnimationState, AnimationClip, AnimationTiming
    state = AnimationState(**case["state"])
    clips = (AnimationClip * len(case["clips"]))(*(AnimationClip(**clip) for clip in case["clips"]))
    timing = (AnimationTiming * len(case["timing"]))(*(AnimationTiming(**item) for item in case["timing"]))
    result = C.c_float()
    status = lib.dc_animation_advance(C.byref(state), clips, timing, len(clips), case["lane"],
        case["delta"], case["speed"], case["now"], C.byref(result))
    if status:
        raise ValueError(f"Native frame update rejected input with status {status}: {case}")
    current, ready = C.c_uint32(), C.c_uint32()
    if lib.dc_animation_query(C.byref(state), clips, len(clips), C.byref(current), C.byref(ready)):
        raise ValueError("Native query rejected resulting state")
    return {"state": state.record(), "iterations": [clip.iterations for clip in clips],
            "returned_frame": result.value, "query": [current.value, ready.value]}


def cases():
    for ordinal, (lane, blend, reverse, loop, chain, iterations, limit, delta) in enumerate(
            itertools.product((0, 1), (0.5, 1.0), (0, 1, 2), (0, 1, 2),
                              (0, 1, 2), (0, 254, 255), (1, 2), (0, 16, 1000))):
        clips = [{"first_frame": 2.0 + i * 20, "last_frame": 10.0 + i * 20,
                  "blend_duration": (0, 250)[ordinal % 2], "loop": 0,
                  "iterations": 17, "reverse": 0} for i in range(3)]
        clips[lane].update(loop=loop, iterations=iterations, reverse=reverse)
        timing = [{"duration_seconds": (0.0, 0.125, 0.3, 0.4, 0.5, 1.0)[ordinal % 6],
                   "next_clip": 2, "loop_limit": limit, "chain": chain} for _ in range(3)]
        first, last = clips[lane]["first_frame"], clips[lane]["last_frame"]
        selected_frame = (first - 17, first - 1, first, first + 4, last, last + 1, last + 17)[ordinal % 7]
        state = {"previous": 2, "current": 0, "pending": 1, "blend_start": 123,
                 "blend_end": 456, "blend": blend, "frame": 6.0,
                 "pending_frame": 26.0, "fixed_frame": 1 if ordinal % 17 == 0 else 255 if ordinal % 19 == 0 else 0}
        state["pending_frame" if lane else "frame"] = selected_frame
        yield {"state": state, "clips": clips, "timing": timing, "lane": lane,
               "delta": delta, "speed": (0.0, 0.3, 0.5, 1.0, 1.1, 1.7, 2.0, -1.0)[ordinal % 8],
               "now": (0, 0xfffffffe)[ordinal % 2]}
    # High-bit deltas exercise the unsigned load without an unbounded original
    # looping input. Synthetic chains use zero outgoing blend duration.
    for lane, reverse, delta, chain in itertools.product((0, 1), (0, 1), (0x80000000, 0xffffffff), (0, 1)):
        clips = [{"first_frame": float(i * 20), "last_frame": float(i * 20 + 8),
                  "blend_duration": 0, "loop": 0, "iterations": 0, "reverse": reverse} for i in range(3)]
        timing = [{"duration_seconds": 1.0, "next_clip": 2, "loop_limit": 0, "chain": chain} for _ in range(3)]
        yield {"state": {"previous": 2, "current": 0, "pending": 1, "blend_start": 123,
                         "blend_end": 456, "blend": 1.0, "frame": 4.0,
                         "pending_frame": 24.0, "fixed_frame": 0},
               "clips": clips, "timing": timing, "lane": lane, "delta": delta, "speed": 1.0, "now": 1234}
