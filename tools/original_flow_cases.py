"""Portable bindings and bounded numeric cases for the canonical flow engine."""
import ctypes as C
import hashlib
import itertools
import os
from pathlib import Path
import random
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
RAW_BYTES=0xea38
STRIDE=0x2198
SCHEDULER_OFFSETS=(0x22,0x24,0x34,0x35,0x36,0x37)

class Meta(C.Structure):
    _fields_=[(name,C.c_uint8) for name in ('chapter','scene_type','previous_type','map','stage','selector0','selector1','script_frame')]
class FlowState(C.Structure):
    _fields_=[('raw',C.c_uint8*RAW_BYTES),('meta',Meta)]
class Chapter(C.Structure):
    _fields_=[('callback',C.c_uint32),('scene_type',C.c_uint32),('script',C.c_int32),
              ('last_frame',C.c_int32),('map',C.c_uint32),('stage',C.c_uint32)]
class Result(C.Structure):
    _fields_=[('callback',C.c_uint32),('destination_type',C.c_uint32),('flags',C.c_uint32),
              ('scheduler',C.c_uint32),('script',C.c_int32),('last_frame',C.c_int32)]
class ExitMetrics(C.Structure):
    _fields_=[(name,C.c_uint32) for name in ('level','flag_b','count','outcome_a','outcome_b')]
class Selection(C.Structure):
    _fields_=[(name,C.c_uint32) for name in ('category','map_index','stage_mask','first','second')]
class Masks(C.Structure):
    _fields_=[('disabled_categories',C.c_uint32),('disabled_maps',C.c_uint32*6),('disabled_stages',C.c_uint32*6)]


def library():
    from native_core import compiler_command
    sources=[ROOT/'native/game/dc_flow.c',ROOT/'native/game/dc_save.c']
    command=compiler_command()
    digest=hashlib.sha256('\0'.join(command).encode())
    for path in sources+[ROOT/'native/include/dc_flow.h',ROOT/'native/include/dc_save.h',ROOT/'native/include/dc_pp.h']:
        digest.update(path.read_bytes())
    extension='.dll' if sys.platform=='win32' else '.dylib' if sys.platform=='darwin' else '.so'
    target=ROOT/'out/native-core'/('original-flow-'+digest.hexdigest()[:16]+extension)
    target.parent.mkdir(parents=True,exist_ok=True)
    if not target.exists():
        flags=['-dynamiclib','-fPIC'] if sys.platform=='darwin' else ['-shared']+([] if sys.platform=='win32' else ['-fPIC'])
        env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.tools/zig-cache'))
        result=subprocess.run(command+['-std=c11','-O2','-Wall','-Wextra','-Werror','-DDC_NATIVE_SHARED',
            *flags,'-I'+str(ROOT/'native/include'),*(str(p) for p in sources),'-o',str(target)],
            env=env,capture_output=True,text=True,timeout=180)
        if result.returncode:raise RuntimeError(result.stderr[-8000:])
    lib=C.CDLL(str(target))
    specs={
        'dc_flow_state_init':[C.POINTER(FlowState),C.POINTER(Meta)],
        'dc_flow_chapter_profile':[C.c_uint32,C.POINTER(Chapter)],
        'dc_flow_scheduler':[C.POINTER(FlowState),C.POINTER(C.c_uint32)],
        'dc_flow_scene_exit':[C.POINTER(FlowState),C.POINTER(ExitMetrics),C.POINTER(Result)],
        'dc_flow_night_commit':[C.POINTER(FlowState),C.c_uint32,C.c_uint32],
        'dc_flow_script_finish':[C.POINTER(FlowState),C.POINTER(Result)],
        'dc_flow_selector_admission':[C.POINTER(FlowState),C.POINTER(Masks)],
        'dc_flow_selector_route':[C.POINTER(FlowState),C.POINTER(Selection),C.POINTER(Result)],
        'dc_flow_prompt_route':[C.POINTER(FlowState),C.c_uint32,C.POINTER(Result)]}
    for name,args in specs.items():getattr(lib,name).argtypes=args;getattr(lib,name).restype=C.c_int
    return lib


def state(seed=0,chapter=24,scene_type=2,stage=255):
    result=FlowState()
    C.memmove(C.addressof(result),bytes((i*17+seed)&255 for i in range(RAW_BYTES)),RAW_BYTES)
    for i in range(3):C.memset(C.addressof(result)+i*STRIDE,0,0x40)
    result.meta=Meta(chapter,scene_type,3,255,stage,255,255,254)
    return result

def scheduler_cases():
    blank=[0]*6
    for stage,outcome,state24,count,t36,t37 in itertools.product(
            range(3),(0,3,5),(0,1),(0,1,2,5,6,14,15,20,21,22,28,29,30),(0,6,255),(0,9,255)):
        rows=[blank.copy() for _ in range(3)]
        rows[stage]=[outcome,state24,1,count,t36,t37]
        yield rows
    generator=random.Random(0x47d2d0)
    for _ in range(200):
        yield [[generator.choice((0,1,2,3,4,5)),generator.randrange(2),generator.randrange(2),
                generator.choice((1,2,5,14,21,22,28,29)),generator.choice((6,255)),generator.choice((9,255))]
               for _ in range(3)]


def selection_cases():
    for category in range(6):
        choices=list(itertools.permutations(range(3),2)) if category==4 else ([(0,1,2)] if category==5 else [(i,) for i in range(3)])
        for map_index,selected,fade_ready,audio_playing in itertools.product(range(7),choices,range(2),range(2)):
            selection=Selection(category,map_index,sum(1<<i for i in selected),selected[0],selected[1] if len(selected)>1 else 0)
            yield selection,fade_ready,audio_playing


def exit_cases():
    for scene_type,stage,replay,progress,prior,metric_index in itertools.product(
            (4,5,6),range(3),range(2),range(3),(0,9999,10000,65535),range(3)):
        chapter=24 if replay else {4:(17,10,3),5:(19,12,5),6:(21,14,7)}[scene_type][stage]
        metrics=((0,0,0,0,0),(2,1,1,1,1),(255,255,65535,65535,65535))[metric_index]
        yield scene_type,stage,chapter,progress,prior,ExitMetrics(*metrics),0
    for scene_type,stage,which in itertools.product((4,5),range(3),(1,2)):
        yield scene_type,stage,24,1,0,ExitMetrics(2,1,1,0,0),which


def write_scheduler_rows(value,rows):
    for i,row in enumerate(rows):
        for offset,n in zip(SCHEDULER_OFFSETS,row):value.raw[i*STRIDE+offset]=n


def snapshot(value,callback=0):
    return {'raw_sha256':hashlib.sha256(bytes(value.raw)).hexdigest(),'meta':list(bytes(value.meta)),'callback':callback}


def record_digest(digest,row):
    import json
    digest.update((json.dumps(row,sort_keys=True,separators=(',',':'))+'\n').encode())
