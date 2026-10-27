"""Compare canonical raw flow with isolated hash-pinned original instructions.

Requires a caller-supplied local PE. No original process, real file I/O,
resource loader, graphics, sound, network, or host platform code executes.
Cleanup, transition readiness, audio query, and resource calls are synthetic
boundaries. This does not establish the scene's gameplay exit condition.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

from oracle_animation import OriginalAnimation,OBJECT,STACK,STOP,TARGET_SHA256
from original_flow_cases import (RAW_BYTES,STRIDE,FlowState,Meta,Result,state,library,
    scheduler_cases,selection_cases,exit_cases,write_scheduler_rows,snapshot,record_digest)
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_EBP

SCENE=0x24000000
META_OFFSETS=(0x13535,0x1352d,0x1352f,0x13533,0x13530,0x13531,0x13532,0x13534)
RANGES={0x47d2d0:0x24b,0x47d090:0x65,0x47d100:0xa3,0x47d000:0x85,
        0x47ceb0:0x142,0x52a990:0x55f,0x52a430:0x554,0x523380:0x506,
        0x52c230:0x615,0x606440:0x4b3,0x52bcf0:0x532}


class OriginalFlow(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,RANGES)
        self.uc.mem_map(OBJECT+0x11000,0x1f000,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_map(SCENE,0x30000,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_protect(0x87d000,0x3000,UC_PROT_READ|UC_PROT_WRITE)
        self.ready=1;self.playing=0

    def write_guard(self,uc,access,address,size,value,context):
        if any(base<=address and address+size<=base+length for base,length in
               ((0x10000000,0x10000),(OBJECT,0x30000),(SCENE,0x30000),(0x87de88,0xbe4))):return
        raise RuntimeError(f'Original flow wrote outside admitted contexts {address:x}/{size}')

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp)
        if ret not in self.instructions:raise RuntimeError('Synthetic return leaves admitted original instructions')
        noop={0x513320,0x48a5b0,0x483bc0,0x51bca0,0x61dd61,0x420a60,0x420e60,
              0x591cf0,0x58e500,0x464a60,0x605b20,0x465080}
        if address in noop:pass
        elif address==0x464ab0:uc.reg_write(UC_X86_REG_EAX,self.ready)
        elif address==0x4025a0:uc.reg_write(UC_X86_REG_EAX,self.playing)
        elif address==0x593780:uc.reg_write(UC_X86_REG_EAX,0)
        elif address==0x61dcd0:
            dest,value,length=(self.word(sp+i)for i in(4,8,12))
            if not (0x10000000<=dest and dest+length<=0x10010000 or 0x87de88<=dest and dest+length<=0x87ea6c):raise RuntimeError('Unadmitted memset')
            uc.mem_write(dest,bytes([value&255])*length);uc.reg_write(UC_X86_REG_EAX,dest)
        elif address in(0x61dd70,0x61dd80,0x61ebbe):
            dest=self.word(sp+4)
            if not 0x10000000<=dest<0x10010000:raise RuntimeError('Unadmitted path buffer')
            uc.mem_write(dest,b'\0');uc.reg_write(UC_X86_REG_EAX,dest)
        elif address==0x605390:self.loads+=1
        else:raise RuntimeError(f'Unadmitted flow target {address:x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4);uc.reg_write(UC_X86_REG_EIP,ret)

    def prepare(self,value):
        self.uc.mem_write(OBJECT,bytes(0x30000));self.uc.mem_write(SCENE,bytes(0x30000))
        self.uc.mem_write(OBJECT+0x13538,bytes(value.raw))
        for offset,n in zip(META_OFFSETS,bytes(value.meta)):self.uc.mem_write(OBJECT+offset,bytes([n]))
        self.loads=0;self.ready=1;self.playing=0

    def invoke(self,entry,*args):
        self.uc.mem_write(STACK,struct.pack('<'+'I'*(len(args)+1),STOP,*args))
        self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(entry,STOP,count=100000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=STOP:raise RuntimeError('Original flow did not return')
        return self.uc.reg_read(UC_X86_REG_EAX)

    def result(self):
        value=FlowState();C.memmove(C.addressof(value),bytes(self.uc.mem_read(OBJECT+0x13538,RAW_BYTES)),RAW_BYTES)
        value.meta=Meta(*(self.uc.mem_read(OBJECT+offset,1)[0]for offset in META_OFFSETS))
        return value,self.word(OBJECT+0x21f78)

    def scheduler(self,value):
        self.prepare(value);result=self.invoke(0x47d2d0,OBJECT)&255
        return self.result()[0],result

    def selection(self,value,selection,ready,playing):
        self.prepare(value);self.ready,self.playing=ready,playing
        self.uc.mem_write(SCENE+0x3f58,bytes([1,1,selection.category]))
        for row in range(3):self.uc.mem_write(SCENE+0x3f5b+row,bytes([bool(selection.stage_mask&(1<<row))]))
        self.uc.mem_write(SCENE+0x3f5e,bytes([selection.first,selection.second]))
        self.uc.mem_write(SCENE+0x3f61,bytes([selection.map_index]))
        self.invoke(0x52c230,OBJECT,SCENE);return self.result()

    def scene_exit(self,value,metrics):
        self.prepare(value);t=value.meta.scene_type;s=value.meta.stage
        if t==4:
            self.uc.mem_write(SCENE+0x184d,bytes([s]));self.uc.mem_write(SCENE+0x1850,b'\2\1')
            self.uc.mem_write(SCENE+0x18b4,bytes([metrics.level]));self.uc.mem_write(SCENE+0x185b,bytes([metrics.flag_b]))
            self.uc.mem_write(SCENE+0x185e,struct.pack('<H',metrics.count));entry=0x52a990
        elif t==5:
            self.uc.mem_write(SCENE+0x21a8,bytes([s]));self.uc.mem_write(SCENE+0x21b8,b'\1\2')
            self.uc.mem_write(SCENE+0x2274,bytes([metrics.level]));self.uc.mem_write(SCENE+0x21c2,bytes([metrics.flag_b]))
            self.uc.mem_write(SCENE+0x21ec,struct.pack('<H',metrics.count));entry=0x52a430
        else:
            self.uc.mem_write(SCENE+0x1858,bytes([s]));self.uc.mem_write(SCENE+0x185f,b'\2\1')
            self.uc.mem_write(SCENE+0x1a04+s,bytes([metrics.level]));self.uc.mem_write(SCENE+0x187f+s,bytes([metrics.flag_b]))
            self.uc.mem_write(SCENE+0x18f0+s*4,struct.pack('<HH',metrics.outcome_a,metrics.outcome_b));entry=0x523380
        self.invoke(entry,OBJECT,SCENE);return self.result()

    def script_finish(self,value):
        self.prepare(value);self.uc.mem_write(0x87de88,bytes(0xbe4))
        self.uc.mem_write(OBJECT+0x21f70,b'\1\2\3')
        self.invoke(0x606440,OBJECT)
        phase=self.uc.mem_read(0x87ea68,1)[0]
        if self.uc.mem_read(0x87ea69,1)[0]:self.invoke(0x52bcf0,OBJECT,0x87de88,0x78d908)
        value,callback=self.result()
        return value,callback,phase,self.loads,list(self.uc.mem_read(OBJECT+0x21f70,3))


def compare(exe):
    original=OriginalFlow(exe);lib=library();groups={}
    def group(name):groups[name]={'cases':0,'digest':hashlib.sha256()};return groups[name]
    g=group('scheduler')
    for index,rows in enumerate(scheduler_cases()):
        current=state(index&255);write_scheduler_rows(current,rows)
        expected,result=original.scheduler(current);actual=FlowState.from_buffer_copy(current);r=C.c_uint32()
        assert lib.dc_flow_scheduler(C.byref(actual),C.byref(r))==0
        if bytes(actual)!=bytes(expected)or r.value!=result:raise AssertionError(('scheduler',index))
        record_digest(g['digest'],[rows,result,snapshot(expected)]);g['cases']+=1
    g=group('selector')
    for index,(selection,ready,playing)in enumerate(selection_cases()):
        current=state(index&255);expected,callback=original.selection(current,selection,ready,playing)
        actual=FlowState.from_buffer_copy(current);r=Result()
        if ready and not playing:
            assert lib.dc_flow_selector_route(C.byref(actual),C.byref(selection),C.byref(r))==0
        if bytes(actual)!=bytes(expected)or r.callback!=callback:raise AssertionError(('selector',index))
        record_digest(g['digest'],[list(selection.category.to_bytes(1,'little')) if False else [getattr(selection,n)for n,_ in selection._fields_],ready,playing,snapshot(expected,callback)])
        g['cases']+=1
    g=group('scene_exit')
    for index,(t,s,c,progress,prior,metrics,special)in enumerate(exit_cases()):
        current=state(index&255,c,t,s);at=s*STRIDE;current.raw[at+0x23]=progress
        for offset in(0x12,0x1e):current.raw[at+offset]=prior&255;current.raw[at+offset+1]=prior>>8
        if special:
            current.raw[at+0x34]=1;current.raw[at+0x35]=21 if special==1 else 28;current.raw[at+0x36]=255
        expected,callback=original.scene_exit(current,metrics);actual=FlowState.from_buffer_copy(current);r=Result()
        assert lib.dc_flow_scene_exit(C.byref(actual),C.byref(metrics),C.byref(r))==0
        if bytes(actual)!=bytes(expected)or r.callback!=callback:raise AssertionError(('exit',index,snapshot(actual,r.callback),snapshot(expected,callback)))
        record_digest(g['digest'],[[t,s,c,progress,prior,special],[getattr(metrics,n)for n,_ in metrics._fields_],snapshot(expected,callback)])
        g['cases']+=1
    g=group('script_finish')
    for chapter in range(29):
        if chapter in(3,5,7,10,12,14,17,19,21,24):continue
        current=state(chapter,chapter,3,255);expected,callback,phase,loads,special=original.script_finish(current)
        actual=FlowState.from_buffer_copy(current);r=Result();assert lib.dc_flow_script_finish(C.byref(actual),C.byref(r))==0
        if bytes(actual)!=bytes(expected)or r.callback!=callback:raise AssertionError(('script',chapter,snapshot(actual,r.callback),snapshot(expected,callback)))
        if bool(r.flags&8)!=(special==[0,0,0]):raise AssertionError(('script_special',chapter))
        record_digest(g['digest'],[chapter,phase,loads,special,snapshot(expected,callback)]);g['cases']+=1
    return {'target_sha256':TARGET_SHA256,'function_sha256':original.hashes,
            'execution':'isolated original numeric routers; explicit synthetic boundaries in tool docstring',
            'scope':'metadata and every raw byte; scene input/animation/audio/exit eligibility unverified',
            'groups':{name:{'cases':g['cases'],'output_sha256':g['digest'].hexdigest()}for name,g in groups.items()}}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    result=compare(args.exe);args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result))


if __name__=='__main__':main()
