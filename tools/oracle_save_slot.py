"""Capture the actual WriteFile byte sequence of original FUN_0052eab0.

Executes original save writer and word-XOR instructions on synthetic state.
CRT path building, path resolution, Win32 file calls, menu refresh and cookie
checking are stub boundaries. No file is created/deleted, no original game
state or resource is loaded, and no original process is launched.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ESP,UC_X86_REG_EBP,UC_X86_REG_EIP
from oracle_animation import OriginalAnimation,OBJECT,STACK,STOP,TARGET_SHA256
from native_core import library
from save_slot_cases import cases

MAIN=0x21000000
STUBS={0x62e12c:STOP+0x100,0x62e110:STOP+0x110,0x62e114:STOP+0x120,0x62e10c:STOP+0x130}
class OriginalSlot(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,{0x52eab0:0x52ef6c-0x52eab0,0x45dc10:83})
        self.uc.mem_map(MAIN,0x23000,UC_PROT_READ|UC_PROT_WRITE)
        for iat,address in STUBS.items():self.uc.mem_write(iat,struct.pack('<I',address));self.uc.mem_write(address,b'\xc3')
    def string(self,address):
        out=bytearray()
        for i in range(512):
            b=self.uc.mem_read(address+i,1)[0]
            if not b:return bytes(out)
            out.append(b)
        raise RuntimeError('Unterminated synthetic path')
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if MAIN+0x13538<=address and address+size<=MAIN+0x21f70:return
        raise RuntimeError(f'Unexpected save-writer write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp);pop=0
        if ret not in self.instructions:raise RuntimeError('Unexpected save helper return')
        args=lambda n:[self.word(sp+4+i*4) for i in range(n)]
        if address==0x61dcd0:
            dest,value,length=args(3);assert 0x10000000<=dest and dest+length<=0x10010000;uc.mem_write(dest,bytes([value&255])*length)
        elif address==0x61ebbe:
            dest,fmt,slot=args(3);assert self.string(fmt)==b'RP_%02d.sav';uc.mem_write(dest,('RP_%02d.sav'%slot).encode()+b'\0')
        elif address in (0x61dd70,0x61dd80):
            dest,src=args(2);value=self.string(src)
            if address==0x61dd80:value=self.string(dest)+value
            uc.mem_write(dest,value+b'\0');uc.reg_write(UC_X86_REG_EAX,dest)
        elif address==0x465080:
            self.path=self.string(args(1)[0]);uc.mem_write(MAIN+0x11d,self.path+b'\0')
        elif address==STOP+0x100:
            assert self.string(args(1)[0])==b'Data\\save\\RP_23.sav';pop=4
        elif address==STOP+0x110:
            assert self.string(args(7)[0])==b'Data\\save\\RP_23.sav';uc.reg_write(UC_X86_REG_EAX,0x4444);pop=28
        elif address==STOP+0x120:
            handle,source,length,written,overlapped=args(5);assert handle==0x4444 and overlapped==0
            self.chunks.append(bytes(uc.mem_read(source,length)));uc.mem_write(written,struct.pack('<I',length));uc.reg_write(UC_X86_REG_EAX,1);pop=20
        elif address==STOP+0x130:
            assert args(1)==[0x4444];pop=4
        elif address in (0x52d3d0,0x52d970,0x61dd61):pass
        else:raise RuntimeError(f'Unexpected save helper {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4+pop);uc.reg_write(UC_X86_REG_EIP,ret)
    def run(self,state,meta):
        self.chunks=[];self.uc.mem_write(MAIN,bytes(0x23000));self.uc.mem_write(MAIN+0x13538,state)
        for offset,value in ((0x13535,meta.chapter),(0x1352d,meta.scene_type),(0x1352f,meta.previous_type),
                             (0x13533,meta.map),(0x13530,meta.stage),(0x13531,meta.selector0),(0x13532,meta.selector1),(0x13534,meta.script_frame)):
            self.uc.mem_write(MAIN+offset,bytes([value]))
        self.uc.mem_write(0x84d07a,b'\x03\x02')
        self.uc.mem_write(STACK,struct.pack('<2I',STOP,MAIN));self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(0x52eab0,STOP,count=2000000)
        assert self.uc.reg_read(UC_X86_REG_EIP)==STOP
        assert bytes(self.uc.mem_read(MAIN+0x13538,len(state)))==state,'Writer failed to restore runtime state after XOR'
        return b''.join(self.chunks)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    original=OriginalSlot(a.exe);lib=library();rows=[]
    for seed,state,meta in cases():
        expected=original.run(state,meta);out=C.create_string_buffer(0xea40)
        assert lib.dc_save_slot_encode(state,len(state),C.byref(meta),out,len(out))==0
        assert out.raw==expected
        rows.append({'seed':seed,'meta':list(bytes(meta)),'bytes':len(expected),'sha256':hashlib.sha256(expected).hexdigest(),
                     'chunk_lengths':[len(b) for b in original.chunks]})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),'boundaries':__doc__,'vectors':rows}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
