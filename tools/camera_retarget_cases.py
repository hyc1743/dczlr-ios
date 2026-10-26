"""Self-authored numeric cases shared by offline oracle and portable replay."""
from native_core import CameraOrbit
from scene_cases import matrix

def cases():
    for rotation in (0,.4):
        for height in (0,3):
            for distance in (-20,-60):
                for pitch in (-.3,.2):
                    for target in ((0,2,0),(8,4,-2),(-10,8,4),(2,-3,-9)):
                        for primary in (0,1):
                            yield CameraOrbit(matrix(rotation,1,(2,1,-3)),distance,height,pitch,.5),matrix(translation=target),primary
