"""Synthetic raw game-state windows and opaque context bytes."""
from native_core import SaveSlotMeta

def cases():
    for seed,meta in ((0,SaveSlotMeta(3,4,3,0,2,0,0,0)),
                      (0x55,SaveSlotMeta(25,3,2,255,255,128,129,13)),
                      (0xa5,SaveSlotMeta(14,6,3,6,1,7,8,42))):
        yield seed,bytes((i*17+seed)&255 for i in range(0xea38)),meta
