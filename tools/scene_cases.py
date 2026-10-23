"""Self-authored hierarchy matrices and transform modifiers."""
import ctypes as C
import math
from native_core import Matrix, SceneNode


def matrix(angle=0, scale=1, translation=(0,0,0)):
    c,s=math.cos(angle)*scale,math.sin(angle)*scale
    return Matrix((C.c_float*16)(c,s,0,0,-s,c,0,0,0,0,scale,0,*translation,1))


def cases():
    for parents in ((0xffffffff,), (0xffffffff,0,1,2), (0xffffffff,0,0,1,1,2)):
        for modifier in (0,1,2):
            for hidden in (-1,0,len(parents)-1):
                nodes=(SceneNode*len(parents))()
                for i,parent in enumerate(parents):
                    nodes[i]=SceneNode(parent,modifier,int(i==hidden),0,(C.c_uint8*2)(),
                        matrix(.17*i,1+i*.125,(i*.3,-i*.4,i*.25)),
                        matrix(-.2,1.2,(.5,.25,-.5)))
                yield nodes, matrix(.3,.75,(10,20,30))
