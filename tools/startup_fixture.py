"""Self-authored PP/XX/XA/EMA resources exercising the actual startup host.

Resource identifiers mirror host lookups; all pixels, geometry, keys and PP
bytes are generated here. This fixture never reads local original resources.
"""
import hashlib
import json
from pathlib import Path
import struct
import math
from xx_cases import diagnostic_fixture, name, u32
from pose_cases import key

TITLE_NAMES=(b'k_defo.ema',b'Title_base.ema',b'Title_start.ema',b'Title_load.ema',
             b'Title_edit.ema',b'Title_extra.ema',b'Title_end.ema',b'Title_edit_mono.ema',b'Title_extra_mono.ema')


def pp(entries):
    names=b''.join(label.ljust(32,b'\0') for label,_ in entries)
    payload=b''.join(data for _,data in entries)
    encode=lambda data:bytes((-v)&255 for v in data)
    return struct.pack('<2I',len(entries),len(payload))+encode(names)+b''.join(u32(len(data)) for _,data in entries)+encode(payload)


def ema(color):
    width,height=64,48
    pixels=bytearray()
    for y in range(height):
        for x in range(width):
            c=color if (x//8+y//8)%2 else tuple(min(255,v+45) for v in color)
            pixels+=bytes(reversed(c))
    bitmap=b'BM'+struct.pack('<IHHI',54+len(pixels),0,0,54)
    bitmap+=struct.pack('<IiiHHIIiiII',40,width,-height,1,24,0,len(pixels),0,0,0,0)+pixels
    return struct.pack('<2I',width,height)+b'.bmp\0'+bitmap


def resources():
    xx=diagnostic_fixture()
    keys=[]
    for frame,alpha in ((0,0),(8,0),(10,0),(20,0),(30,0),(60,1),(70,1),(80,1),(90,1),(120,0)):
        values=[1.0]*17;values[3]=alpha
        keys.append(struct.pack('<17fi',*values,frame))
    xa=b'\1'+u32(1)+name(b'diagnostic\0')+u32(len(keys))+b''.join(keys)+bytes(2)+b'\1'
    clips=bytearray(512*108)
    for i,first,last,loop,chain,next_clip in ((1,10,20,1,0,0),(2,30,60,0,1,3),(3,70,80,1,0,0),(4,90,120,0,1,1)):
        at=i*108
        struct.pack_into('<f',clips,at+64,.4 if chain else .8)
        struct.pack_into('<2f',clips,at+72,first,last)
        clips[at+80]=loop;clips[at+82]=chain;struct.pack_into('<I',clips,at+83,next_clip)
    pose=name(b'synthetic-node\0')+u32(2)+u32(0)+bytes(key(0))+bytes(key(360))
    xa+=clips+u32(1)+pose
    cards=[(b'illusion.ema',ema((20,110,180))),(b'warning.ema',ema((180,80,20)))]
    cards += [(n,ema((20+i*12,60+i*7,30+i*6))) for i,n in enumerate(TITLE_NAMES)]
    return {'RPP_02.pp':pp(cards),'RPP_17.pp':pp([(b'mm_B_W.xx',xx),(b'mm_B_W.xa',xa)]),
            'RPP_01.pp':pp([(b'bgm000.wav',wave(220,2))]),'RPP_14.pp':pp([(b'se100.wav',wave(440,.08))])}


def wave(frequency,seconds):
    rate=22050;count=int(rate*seconds)
    pcm=b''.join(struct.pack('<h',int(1000*math.sin(2*math.pi*frequency*i/rate))) for i in range(count))
    return b'RIFF'+u32(36+len(pcm))+b'WAVEfmt '+u32(16)+struct.pack('<HHIIHH',1,1,rate,rate*2,2,16)+b'data'+u32(len(pcm))+pcm


def install(directory):
    directory=Path(directory)
    if directory.exists():raise ValueError('Startup fixture destination must be new')
    directory.mkdir(parents=True)
    entries=resources()
    for name,data in entries.items():(directory/name).write_bytes(data)
    return {'content':'self-authored generated fixtures; no original payloads',
            'files':{name:{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in entries.items()}}
