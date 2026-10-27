"""Self-authored pointer cases; portable tests never import Unicorn."""
from native_core import CameraOrbit,CameraPointerLimits,CameraPointerInput
from scene_cases import matrix

def cases():
    moves=((0,0,0,0,0,0),(15,-8,0,3,0,0),(-40,20,0,1,0,0),(0,800,0,1,0,0),
           (100,-600,0,0,3,0),(-1000,600,0,0,1,0),(40,20,0,1,1,0),
           (20,-10,0,0,0,1),(2000,-2000,0,1,1,0),(0,0,120,0,0,0),
           (0,0,-120,0,0,0),(5,5,120,1,0,0),(0,0,120,2,2,0),
           (15,20,-120,0,1,1))
    for i in range(3):
        orbit=CameraOrbit(matrix(.1*i,1,(i*20-10,i*3,-i*10)),-(20+i*30),i*10-5,i*3.1,.2+i*2)
        for values in moves:
            for fast in (0,1):yield orbit,CameraPointerLimits(100,5,20,-30,4 if i<2 else 8),CameraPointerInput(*values,fast)
