"""Self-authored camera inputs; no game presets or media."""
import itertools
from native_core import CameraOrbit, CameraLens
from scene_cases import matrix


def cases():
    bases=[matrix(),matrix(.37,.75,(4,-8,12)),matrix(-.23,1.3,(-10,2,7))]
    bases[-1].values[1]+=.125
    bases[-1].values[8]=.2
    for index,(base,distance,height,pitch,yaw) in enumerate(itertools.product(
            bases,(-5,0,80),(-2,10),(-.7,0,.8),(-1.2,.2))):
        yield CameraOrbit(base,distance,height,pitch,yaw), CameraLens(
            (.3,1.1,2.6)[index%3],(.5,.01,2)[index%3],(10000,200,3)[index%3],
            (1024,1920,640,1,0xffffffff)[index%5],(768,1080,480,3,0xfffffffe)[index%5])
