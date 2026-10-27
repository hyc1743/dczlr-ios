"""Replay original 00417ac0 with original cross/scale instruction leaves.

Only D3DXVec3Normalize is a Python math boundary; constructors are inert.
Synthetic finite, nonvertical directions are used. No original scene, assets,
renderer, D3DX implementation or game process executes.
"""
import argparse
import ctypes as C
import json
import math
from pathlib import Path
import struct
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ECX,UC_X86_REG_ESP,UC_X86_REG_EIP
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library,Matrix
from camera_look_at_cases import cases

class OriginalLookAt(OriginalAnimation):
    def __init__(self,path):super().__init__(path,{0x417ac0:372,0x418ac0:124,0x418b40:51})
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if OBJECT<=address and address+size<=OBJECT+64:return
        raise RuntimeError(f'Unadmitted look-at write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp);pop=0
        if ret not in self.instructions:raise RuntimeError('Unadmitted helper return')
        if address==0x4211e0:uc.reg_write(UC_X86_REG_EAX,uc.reg_read(UC_X86_REG_ECX))
        elif address==0x60ac16:
            dst,src=self.word(sp+4),self.word(sp+8)
            v=struct.unpack('<3f',bytes(uc.mem_read(src,12)));length=math.sqrt(sum(x*x for x in v))
            if not length:raise RuntimeError('Degenerate test input')
            uc.mem_write(dst,struct.pack('<3f',*(x/length for x in v)));uc.reg_write(UC_X86_REG_EAX,dst);pop=8
        else:raise RuntimeError(f'Unadmitted look-at helper {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4+pop);uc.reg_write(UC_X86_REG_EIP,ret)
    def run(self,source,target):
        self.uc.mem_write(OBJECT,bytes(source));self.uc.mem_write(OBJECT+0x1000,bytes(target))
        self.execute(0x417ac0,OBJECT,OBJECT+0x1000)
        return list(struct.unpack('<16f',bytes(self.uc.mem_read(OBJECT,64))))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    original=OriginalLookAt(a.exe);lib=library();rows=[];maximum=0
    assert bytes(original.uc.mem_read(0x62e664,4))==struct.pack('<f',2.)
    for i,(source,target) in enumerate(cases()):
        expected=original.run(source,target);actual=Matrix()
        assert lib.dc_camera_look_at(C.byref(source),C.byref(target),C.byref(actual))==0
        error=max(abs(x-y) for x,y in zip(actual.values,expected));maximum=max(maximum,error)
        assert error<2e-6,(i,error,list(actual.values),expected)
        rows.append({'case':i,'result':expected})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),
        'maximum_absolute_error':maximum,'scene_target_height':{'address':'0x0062e664','value':2.},
        'boundaries':__doc__,'vectors':rows}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
