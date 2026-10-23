"""Isolate title frame/dispatcher with synthetic menu, audio and transition.

Runs pinned original instructions only. All resource/OS/init/cleanup routines
are intercepted; Alt-F4 is held up. No original payload or code is exported.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library
from title_cases import cases,native_result

GLOBAL=0x8373a0
KEY_STUB=0x30000100
DESTINATIONS={0x605510:1,0x52e070:2,0x5f1d20:3,0x510a40:4,0x51e010:6}
STUBS={0x464ab0:'query',0x4025a0:'busy',0x5128e0:'cleanup',0x50d920:'init',
       0x402510:'stop',0x467b90:'escape',0x45f7c0:'menu',0x4024b0:'play',
       0x464a60:'transition',0x61dcd0:'memset',0x61dd61:'cookie',KEY_STUB:'key'}


class OriginalTitle(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,{0x5129c0:447,0x52b830:988})
        self.uc.mem_map(OBJECT+0x11000,0x1f000,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_protect(GLOBAL&~4095,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_protect(0x62e000,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_write(0x62e290,struct.pack('<I',KEY_STUB))

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if GLOBAL+0x7c0<=address and address+size<=GLOBAL+0x7c3:return
        offset=address-OBJECT
        if size==4 and offset in (0,0x21f78,0x21f7c,0x21f80,0x21f84,0x21f88,
                                  0x21f98,0x21f9c,0x21fa0,0x21fa4,0x21fb4,0x21fb8,0x21fbc,0x21fc0):
            if offset==0:self.commands.append([9,0]);self.departed=1
            elif offset==0x21f78:
                self.commands.append([2,DESTINATIONS[value]]);self.departed=1
            elif offset==0x21f9c:self.commands.append([4,1])
            elif offset==0x21fb8:self.commands.append([4,2])
            return
        if size==1 and offset in (0x278,0x68b5,0x13535):
            if offset==0x278:self.commands.append([5,2 if self.case['state'][0] in (3,4) else 1])
            if value!=0:raise RuntimeError('Unexpected nonzero flag write')
            return
        raise RuntimeError(f'Title wrote outside admitted state: {address:#x}/{size}')

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in STUBS:raise RuntimeError(f'Title left admitted instructions: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted stub return')
        kind=STUBS[address];ready,busy,escape,result,row=self.case['input'];eax=0
        if kind=='query':
            at=self.word(stack+4)
            if not 0x10000000<=at<0x10010000:raise RuntimeError('Unexpected query output')
            uc.mem_write(at,struct.pack('<I',1));eax=ready
        elif kind=='busy':
            if self.word(stack+4)!=222:raise RuntimeError('Unexpected selection player')
            eax=busy
        elif kind=='escape':eax=escape
        elif kind=='menu':
            if self.word(stack+4)!=GLOBAL+8:raise RuntimeError('Unexpected menu address')
            uc.mem_write(GLOBAL+0x50c,struct.pack('<i',row));eax=result&0xffffffff
        elif kind=='cleanup':
            if self.word(stack+4)!=OBJECT:raise RuntimeError('Unexpected cleanup context')
            self.commands.append([1,0])
        elif kind=='init':
            if self.word(stack+4)!=OBJECT:raise RuntimeError('Unexpected init context')
            self.commands.append([3,0])
        elif kind=='stop':
            if self.word(stack+4)!=111:raise RuntimeError('Unexpected music player')
            self.commands.append([6,0])
        elif kind=='play':
            if (self.word(stack+4),self.word(stack+8))!=(222,0):raise RuntimeError('Unexpected selection play')
            self.commands.append([7,0])
        elif kind=='transition':self.commands.append([8,self.word(stack+4)])
        elif kind=='memset':
            at,value,length=(self.word(stack+i) for i in (4,8,12))
            if not (0x10000000<=at and at+length<=0x10010000 and value==0 and length==260):raise RuntimeError('Unexpected memset')
            uc.mem_write(at,bytes(length))
        uc.reg_write(UC_X86_REG_EAX,eax)
        uc.reg_write(UC_X86_REG_ESP,stack+(8 if kind=='key' else 4))
        uc.reg_write(UC_X86_REG_EIP,target)

    def run(self,case):
        self.case=case;self.commands=[];self.departed=0
        self.uc.mem_write(OBJECT,b'\xa5'*0x30000)
        self.uc.mem_write(GLOBAL,struct.pack('<2I',111,222)+bytes(0x800))
        self.uc.mem_write(GLOBAL+0x7c0,bytes(case['state']))
        self.execute(0x5129c0,OBJECT)
        if self.departed and self.word(OBJECT+0x21f78) in DESTINATIONS:
            if any(self.word(OBJECT+i) for i in (0x21f7c,0x21f80,0x21f84,0x21f88)):raise RuntimeError('Stale active callback')
        if [4,1] in self.commands or [4,2] in self.commands:
            start=0x21f98 if [4,1] in self.commands else 0x21fb4
            if bytes(self.uc.mem_read(OBJECT+start,16))!=b'\xa5'*16:raise RuntimeError('Callback backup differs')
        return {'state':list(self.uc.mem_read(GLOBAL+0x7c0,3)),'departed':self.departed,'commands':self.commands}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--vectors',type=Path,required=True);args=parser.parse_args()
    original=OriginalTitle(args.exe);lib=library();digest=hashlib.sha256();count=0
    for case in cases():
        expected=original.run(case);actual=native_result(lib,case)
        if actual!=expected:raise ValueError(f'Title mismatch {case}: {expected} != {actual}')
        digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
    report={'target_sha256':TARGET_SHA256,'cases':count,'output_sha256':digest.hexdigest(),
            'original_function_sha256':original.hashes,'original_game_resources_used':False,
            'coverage':'title frame and dispatcher; synthetic menu/query/audio/cleanup/init; Alt-F4 up; host destinations not executed',
            'execution':'isolated original x86; all external routines intercepted','game_playability':'not verified'}
    for path in (args.output,args.vectors):
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':count,'matched':True,'output_sha256':digest.hexdigest()}))


if __name__=='__main__':main()
