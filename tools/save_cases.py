"""Synthetic save transform and unlock oracle inputs."""
import random


def cases():
    rng=random.Random(0x45dc10)
    for size in (0,1,2,3,4,5,7,8,15,16,31,32,255,256,257,0x64c8):
        for pattern in range(3):
            yield bytes(size) if pattern==0 else bytes(i%256 for i in range(size)) if pattern==1 else rng.randbytes(size)
