"""Self-authored material keys for original numeric-function comparisons."""
import ctypes as C
import itertools
from native_core import MaterialKey, MaterialValue


def value(values):
    return MaterialValue((C.c_float * 17)(*values))


def cases():
    clocks = ((0, 8), (10, 10), (-8, 8), (2147483646, 2147483647),
              (-2147483648, 2147483647), (8, 0), (16777216, 16777217))
    frames = (-16.0, 0.0, 4.0, 8.0, 10.0, 12.0, 16.0, 16777216.0, 2147483648.0)
    for first_last, frame, pattern in itertools.product(clocks, frames, range(3)):
        first, last = first_last
        left = [[i * 0.125 for i in range(17)], [-i * 1.3 for i in range(17)], [0.3 + i * 0.17 for i in range(17)]][pattern]
        right = [[2 - i * 0.25 for i in range(17)], [i * 0.11 for i in range(17)], [0.7 - i * 0.13 for i in range(17)]][pattern]
        yield {"keys": [{"frame": first, "values": left}, {"frame": last, "values": right}],
               "frame": frame, "baseline": [10 + i for i in range(17)], "initial": [1000 + i for i in range(17)]}
    for timestamps, frame in itertools.product(((), (4,), (0, 8, 8, 16), (8, 0, 16), (0, 8, 4, 12)), (-1.0, 0.0, 4.0, 8.0, 12.0, 16.0, 17.0)):
        yield {"keys": [{"frame": timestamp, "values": [i * 0.3 + j * 0.7 for j in range(17)]} for i, timestamp in enumerate(timestamps)],
               "frame": frame, "baseline": [10 + i for i in range(17)], "initial": [1000 + i for i in range(17)]}


def native_result(lib, case, pair=False):
    keys = (MaterialKey * len(case["keys"]))(*(MaterialKey(value(k["values"]), k["frame"]) for k in case["keys"]))
    baseline, output = value(case["baseline"]), value(case["initial"])
    if pair:
        status = lib.dc_material_interpolate(C.byref(keys[0]), C.byref(keys[1]), case["frame"], C.byref(output))
    else:
        status = lib.dc_material_sample(keys, len(keys), C.byref(baseline), case["frame"], C.byref(output))
    if status:
        raise ValueError(f"Native material sampling failed: {status}, {case}")
    return bytes(output).hex()
