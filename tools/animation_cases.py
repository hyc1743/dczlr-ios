"""Self-authored request inputs; no original animation records or resources."""
import itertools


def cases():
    for ordinal, (current, pending, requested, force, duration, reverse, now) in enumerate(
            itertools.product(range(3), range(3), range(3), (0, 1, 255),
                              (0, 1, 500, 0xffffffff), range(3), (0, 0xfffffffe, 0xffffffff))):
        clips = [{"first_frame": -5.5 + i * 10, "last_frame": 20.25 + i * 20,
                  "blend_duration": 23 + i, "loop": (0, 1, 2, 255)[(ordinal + i) % 4],
                  "iterations": (17 + i * 57 + ordinal) % 256,
                  "reverse": (i + reverse) % 3} for i in range(3)]
        clips[current]["blend_duration"] = duration
        clips[requested]["reverse"] = reverse
        yield {"state": {"previous": 0xfffffffe, "current": current, "pending": pending,
                         "blend_start": 123, "blend_end": 456, "blend": 0.375,
                         "frame": 7.25 + current * 0.125, "pending_frame": 91.5,
                         "fixed_frame": (0, 1, 255)[ordinal % 3]},
               "clips": clips, "requested": requested, "force": force, "now": now}
