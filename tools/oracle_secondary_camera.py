"""Replay original secondary pointer controller 00479630 in isolated x86.

GetAsyncKeyState(F1), matrix translation/multiply and camera publication are
explicit synthetic boundaries. The initial world is computed with Python
math. No original process, scene, resource, DirectInput or GPU executes.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import struct
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ECX,UC_X86_REG_ESP,UC_X86_REG_EIP
from oracle_animation import OriginalAnimation,OBJECT,STOP,TARGET_SHA256
from oracle_camera_retarget import world,multiply,identity
from native_core import library,CameraOrbit
from secondary_camera_cases import cases

INPUT=OBJECT+0x1000
FAST=STOP+0x100
class OriginalPointer(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,{0x479630:0x479bb3-0x479630})
        self.uc.mem_write(0x62e290,struct.pack('<I',FAST));self.uc.mem_write(FAST,b'\xc3')
    def put(self,address,values):self.uc.mem_write(address,struct.pack('<'+'f'*len(values),*values))
    def floats(self,address,count):return list(struct.unpack('<'+'f'*count,bytes(self.uc.mem_read(address,count*4))))
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if size==4 and address-OBJECT in (0x100,0x104,0x108,0x10c,0xb0,0xb4,0xb8):return
        raise RuntimeError(f'Unadmitted pointer write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp);pop=0
        if ret not in self.instructions:raise RuntimeError('Unadmitted helper return')
        if address==0x4211e0:uc.reg_write(UC_X86_REG_EAX,uc.reg_read(UC_X86_REG_ECX))
        elif address==FAST:
            assert self.word(sp+4)==0x70;uc.reg_write(UC_X86_REG_EAX,0x8000 if self.fast else 0);pop=4
        elif address==0x60abe6:
            dst=self.word(sp+4);m=identity();m[12:15]=self.floats(sp+8,3);self.put(dst,m);pop=16
        elif address==0x60abe0:
            dst,a,b=[self.word(sp+i) for i in (4,8,12)];self.put(dst,multiply(self.floats(a,16),self.floats(b,16)));pop=12
        elif address==0x4790d0:
            assert self.word(sp+4)==OBJECT and self.word(sp+8)&255==0;self.published+=1
        else:raise RuntimeError(f'Unadmitted pointer helper {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4+pop);uc.reg_write(UC_X86_REG_EIP,ret)
    def run(self,orbit,limits,move):
        self.fast=move.fast;self.published=0
        self.uc.mem_write(OBJECT,bytes(0x2000));self.put(OBJECT+0x80,list(orbit.base.values))
        self.put(OBJECT+0x100,[orbit.stored_distance,orbit.height,orbit.pitch,orbit.yaw])
        self.put(OBJECT+0xc0,world(list(orbit.base.values),self.floats(OBJECT+0x100,4)))
        self.put(OBJECT+0x110,[limits.far_distance,limits.near_distance,limits.high,limits.low,limits.wheel_step])
        self.uc.mem_write(INPUT+0x14,bytes((move.left,move.right,move.middle)))
        self.uc.mem_write(INPUT+0x18,struct.pack('<3i',move.dx,move.dy,move.wheel))
        self.execute(0x479630,OBJECT,INPUT,0)
        return self.floats(OBJECT+0x80,16)+self.floats(OBJECT+0x100,4)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    original=OriginalPointer(a.exe);lib=library();rows=[];maximum=0
    for i,(orbit,limits,move) in enumerate(cases()):
        expected=original.run(orbit,limits,move);out=CameraOrbit()
        assert lib.dc_camera_secondary_pointer(C.byref(orbit),C.byref(limits),C.byref(move),C.byref(out))==0
        actual=list(out.base.values)+[out.stored_distance,out.height,out.pitch,out.yaw]
        error=max(abs(x-y) for x,y in zip(actual,expected));maximum=max(maximum,error)
        assert error<2e-5,(i,error,actual,expected)
        rows.append({'case':i,'result':expected,'publication_calls':original.published})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),
        'maximum_absolute_error':maximum,'boundaries':__doc__,'vectors':rows}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
