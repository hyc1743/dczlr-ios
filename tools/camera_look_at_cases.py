"""Portable synthetic world matrices, with no game resource dependency."""
from scene_cases import matrix

def cases():
    eyes=((0,0,0),(22,4,-1),(-10,17,30),(.01,-.02,.03))
    directions=((0,0,-50),(0,3,50),(4,0,2),(-3,5,9),(7,-8,-4),(.001,.002,-.003),
                (30,40,50),(-.5,-8,.25),(3,100,2),(.125,0,-.25),(-80,7,-9),(1,-20,0))
    for index,eye in enumerate(eyes):
        for offset in directions:
            yield matrix(.2+index*.1,.5,(eye)),matrix(translation=tuple(x+y for x,y in zip(eye,offset)))
