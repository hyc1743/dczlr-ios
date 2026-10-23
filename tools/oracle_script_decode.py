"""Pinned original normal-branch script parser with synthetic CRT boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library
from script_decode_cases import cases,native_result

SOURCE,BODY=OBJECT+0x2000,OBJECT+0x6000
LENGTH_STUB=0x30000100
STUBS={0x61dd70:'copy',0x61dd61:'cookie',0x61ebbe:'sprintf',0x61e400:'strcmp',
       0x61dcd0:'memset',0x61fe40:'strncpy',0x6203f0:'strncmp',0x620481:'atol',
       0x6202a0:'strncat',LENGTH_STUB:'strlen'}


class OriginalScript(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,{0x592590:4579})
        for page in (0x84d000,0x62e000):self.uc.mem_protect(page,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_write(0x84d4f4,b'\0');self.uc.mem_write(0x84d1c8,struct.pack('<I',OBJECT))
        self.uc.mem_write(0x62e16c,struct.pack('<I',LENGTH_STUB))

    def writable(self,address,size):
        return (0x10000000<=address and address+size<=0x10010000 or
                OBJECT<=address and address+size<=OBJECT+0xc00 or
                BODY<=address and address+size<=BODY+0x4000)

    def write_guard(self,uc,access,address,size,value,context):
        if not self.writable(address,size):raise RuntimeError(f'Script wrote outside admitted buffers: {address:#x}/{size}')

    def write(self,address,data):
        if not self.writable(address,len(data)):raise RuntimeError('CRT output outside admitted buffers')
        self.uc.mem_write(address,data)

    def cstring(self,address,limit=4096):
        out=bytearray()
        for i in range(limit):
            b=self.uc.mem_read(address+i,1)[0]
            if b==0:return bytes(out)
            out.append(b)
        raise RuntimeError('Unterminated synthetic/reference string')

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in STUBS:raise RuntimeError(f'Script left admitted function: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unexpected CRT return')
        kind=STUBS[address];arg=lambda i:self.word(stack+4*i);eax=0
        if kind=='memset':
            if arg(3)>4096:raise RuntimeError('Oversized memset')
            self.write(arg(1),bytes([arg(2)&255])*arg(3));eax=arg(1)
        elif kind=='sprintf':
            if self.cstring(arg(2))!=b'#T%04d':raise RuntimeError('Unexpected format')
            self.write(arg(1),f'#T{arg(3):04d}'.encode()+b'\0');eax=6
        elif kind in ('strcmp','strncmp'):
            if kind=='strcmp':a,b=self.cstring(arg(1)),self.cstring(arg(2))
            else:
                n=arg(3)
                if n>64:raise RuntimeError('Oversized compare')
                a=bytes(uc.mem_read(arg(1),n)).split(b'\0',1)[0];b=bytes(uc.mem_read(arg(2),n)).split(b'\0',1)[0]
            eax=(a>b)-(a<b)
        elif kind=='strlen':eax=len(self.cstring(arg(1)))
        elif kind=='strncpy':
            n=arg(3)
            if n>64:raise RuntimeError('Oversized copy')
            source=bytes(uc.mem_read(arg(2),n)).split(b'\0',1)[0]
            self.write(arg(1),source.ljust(n,b'\0'));eax=arg(1)
        elif kind=='strncat':
            n=arg(3)
            if n>64:raise RuntimeError('Oversized concatenate')
            old=self.cstring(arg(1));added=bytes(uc.mem_read(arg(2),n)).split(b'\0',1)[0]
            self.write(arg(1)+len(old),added+b'\0');eax=arg(1)
        elif kind=='copy':self.write(arg(1),self.cstring(arg(2))+b'\0');eax=arg(1)
        elif kind=='atol':eax=int(self.cstring(arg(1)))
        uc.reg_write(UC_X86_REG_EAX,eax&0xffffffff)
        uc.reg_write(UC_X86_REG_ESP,stack+(8 if kind=='strlen' else 4));uc.reg_write(UC_X86_REG_EIP,target)

    def run(self,case):
        data=bytes.fromhex(case['hex'])
        if len(data)>0x3000:raise ValueError('Synthetic script too large')
        self.uc.mem_write(OBJECT,bytes(0x10000));self.uc.mem_write(SOURCE,data+b'\0'*16)
        for offset,value in ((0,SOURCE),(4,BODY),(8,len(data)),(0x15c,case['frame']),
                              (0x164,9999),(0x16c,1),(0x1a8,case['cursor'])):
            self.uc.mem_write(OBJECT+offset,struct.pack('<I',value))
        for i,(key,n) in enumerate(case['controls']):
            self.uc.mem_write(OBJECT+0xaba+16*i,key.encode()+b'\0')
            self.uc.mem_write(OBJECT+0xb6a+i,bytes([n]))
        # Bound instruction count independently of caller-controlled text.
        self.uc.mem_write(0x10008000,struct.pack('<2I',0x30000000,OBJECT))
        self.uc.reg_write(UC_X86_REG_ESP,0x10008000)
        self.uc.emu_start(0x592590,0x30000000,count=100000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=0x30000000 or self.uc.reg_read(UC_X86_REG_ESP)!=0x10008004 or self.uc.reg_read(UC_X86_REG_EAX)!=0:
            raise RuntimeError('Original script did not successfully return within bound')
        return {'cursor':self.word(OBJECT+0x1a8),'speaker':self.cstring(OBJECT+0xc,33).hex(),
                'body':bytes(self.uc.mem_read(BODY,self.word(OBJECT+0x17c))).hex(),
                **{n:bytes(self.uc.mem_read(OBJECT+offset,20)).hex() for n,offset in
                   (('background',0x1bc),('music',0x1d0),('sound',0x1e4),('message',0x1f8))},
                'controls':bytes(self.uc.mem_read(OBJECT+0x923,37*11)).hex()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--vectors',type=Path,required=True);args=parser.parse_args()
    original=OriginalScript(args.exe);lib=library();digest=hashlib.sha256();count=0
    for case in cases():
        expected=original.run(case);actual=native_result(lib,case)
        if actual!=expected:raise ValueError(f'Script mismatch {case}: {expected} != {actual}')
        digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
    report={'target_sha256':TARGET_SHA256,'cases':count,'output_sha256':digest.hexdigest(),
            'original_function_sha256':original.hashes,'original_game_resources_used':False,
            'coverage':'normal sequential branch; pre-record command accumulation/order; fixed header controls; speaker/body/cursor; no actor commands, backlog, glyph/voice or scene execution',
            'execution':'isolated original x86; CRT strings/format/memory functions intercepted','game_playability':'not verified'}
    for path in (args.output,args.vectors):
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':count,'matched':True,'output_sha256':digest.hexdigest()}))


if __name__=='__main__':main()
