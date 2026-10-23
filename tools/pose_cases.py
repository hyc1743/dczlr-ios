"""Self-authored node keys; no original names, motion, geometry or pixels."""
import ctypes as C
import math
from native_core import PoseKey


def key(frame, angle=0, translation=(0,0,0), scale=(1,1,1), axis=(0,0,1), sign=1):
    norm=math.sqrt(sum(x*x for x in axis))
    xyz=[sign*x/norm*math.sin(angle/2) for x in axis]
    return PoseKey(frame, (C.c_float * 12)(*xyz,sign*math.cos(angle/2),0,0,*translation,*scale))


def selection_cases():
    for frames in ((0,8), (-8,0,8), (0,4,8,12), (0,8,8,8,16), (4,4),
                   (-2147483648,2147483647), (16777215,16777216,16777217,16777218)):
        for frame in (-16,-8.9,-0.9,0,0.9,3.9,4,4.9,8,8.9,16,16777216,2147483520):
            yield frames, frame


def transform_cases():
    for frames in ((0,8), (-8,0,8), (0,8,8,16), (4,4)):
        for angle in (0, .001, .01, .03, .05, .07, .5, 2.5, 4.0):
            for at in (-1,0,2.25,4,8,9,16):
                yield [key(frame, angle*i, (i*.25, -i*.5, i*2), (1+i*.125,1-i*.125,1))
                       for i,frame in enumerate(frames)], at
    for axis in ((1,0,0),(1,2,3),(-3,2,1)):
        for sign in (-1,1):
            for frame in (-8,0,2.5,8,16):
                yield [key(0,.7,axis=axis),key(8,1.3,(2,3,4),(1,2,3),axis,sign)],frame
