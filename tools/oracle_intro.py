"""Isolate original end-of-script and adventure transition dispatch.

All text/font/sprite/audio/file operations are synthetic boundaries. Original
callback writes, descriptor lookups and progression flags execute in isolation.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_EBP
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library
from intro_cases import finish_cases,transition_cases,native_result
from intro_cases import real_finish_cases,real_transition_cases

GLOBAL,TABLE=0x87de88,0x78d908
STUBS={0x420a60:'sprite',0x420e60:'sprite',0x593780:'alpha',0x591cf0:'reset',0x58e500:'font',
       0x61dcd0:'memset',0x61dd70:'copy',0x61dd80:'cat',0x61dd61:'cookie',0x61ebbe:'sprintf',
       0x465080:'lookup',0x605390:'load',0x464a60:'transition',0x464ab0:'query',0x605b20:'cleanup',
       0x402510:'stop',0x423450:'free'}
AUX={0x50de60:2,0x51e010:5,0x512370:6,0x52e070:7}
OLD=(0x11110001,0x11110002,0x11110003,0x11110004)


class OriginalIntro(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,{0x606440:0x6068f3-0x606440,0x52bcf0:0x52c222-0x52bcf0})
        self.uc.mem_map(OBJECT+0x11000,0x1f000,UC_PROT_READ|UC_PROT_WRITE)
        for page,length in ((0x87d000,0x2000),(0x78d000,4096),(0x6d3000,4096)):
            self.uc.mem_protect(page,length,UC_PROT_READ|UC_PROT_WRITE)

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if GLOBAL<=address and address+size<=GLOBAL+0xbe4:return
        offset=address-OBJECT
        if offset==0 and size==4:self.commands.append([10,0]);self.departed=1;return
        if size==4 and offset in (0x21f78,0x21f7c,0x21f80,0x21f84,0x21f88,
                                  0x21f98,0x21f9c,0x21fa0,0x21fa4,0x21fb4,0x21fb8,0x21fbc,0x21fc0):
            if offset==0x21f78:
                if value in AUX:self.commands.append([8,AUX[value]])
                elif value==0x12340000+self.case['state'][0]*16:self.commands.append([6,self.case['state'][0]])
                else:raise RuntimeError('Unknown callback installation')
                self.departed=1
            elif offset==0x21f9c:self.commands.append([7,1])
            elif offset==0x21fb8:self.commands.append([7,2])
            return
        if size==1 and offset in (0x13535,0x13533,0x13530,0x1355b,0x156f3,0x1788b):
            if offset==0x1355b:self.commands.append([11,1])
            return
        if 0x21f70<=offset and offset+size<=0x21f73:return
        raise RuntimeError(f'Intro wrote outside admitted fields: {address:#x}/{size}')

    def string(self,at):
        data=bytes(self.uc.mem_read(at,512));end=data.find(b'\0')
        if end<0:raise RuntimeError('Unterminated synthetic string')
        return data[:end]

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in STUBS:raise RuntimeError(f'Intro left admitted functions: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted host return')
        arg=lambda i:self.word(stack+4*i);kind=STUBS[address];eax=0
        if kind=='reset':self.commands.append([1,0])
        elif kind=='query':
            at=arg(1)
            if not 0x10000000<=at<0x10010000:raise RuntimeError('Unexpected transition output')
            uc.mem_write(at,struct.pack('<I',1));eax=self.case['ready']
        elif kind=='transition':self.commands.append([2,arg(1)])
        elif kind=='cleanup':
            if arg(1)!=OBJECT:raise RuntimeError('Unexpected cleanup context')
            self.commands.append([5,0])
        elif kind=='stop':
            if arg(1) not in (100,101,102):raise RuntimeError('Unexpected audio player')
            self.commands.append([9,arg(1)-100])
        elif kind=='load':
            chapter=self.uc.mem_read(OBJECT+0x13535,1)[0]
            if arg(1)!=OBJECT or C.c_int32(arg(5)).value!=self.case['table'][chapter][1]:raise RuntimeError('Unexpected script setup')
            self.commands.append([3,chapter])
        elif kind=='memset':
            at,value,n=arg(1),arg(2),arg(3)
            if value or n>4096:raise RuntimeError('Unexpected memset')
            self.write_guard(uc,0,at,n,0,None)
            if at==OBJECT+0x21f70 and n==3:self.commands.append([4,0])
            uc.mem_write(at,bytes(n))
        elif kind in ('copy','cat'):
            at=arg(1);data=self.string(arg(2))
            if kind=='cat':at+=len(self.string(at))
            self.write_guard(uc,0,at,len(data)+1,0,None);uc.mem_write(at,data+b'\0')
        elif kind=='sprintf':
            if self.string(arg(2))!=b'Data\\txt\\%02d.txt':raise RuntimeError('Unexpected script format')
            data=f'Data\\txt\\{C.c_int32(arg(3)).value:02d}.txt'.encode()+b'\0'
            self.write_guard(uc,0,arg(1),len(data),0,None);uc.mem_write(arg(1),data)
        elif kind=='free':raise RuntimeError('Synthetic text buffers must be empty')
        uc.reg_write(UC_X86_REG_EAX,eax);uc.reg_write(UC_X86_REG_ESP,stack+4);uc.reg_write(UC_X86_REG_EIP,target)

    def run(self,case,finish=False):
        self.case=case;self.commands=[];self.departed=0;chapter,action,waiting,progress=case['state']
        self.uc.mem_write(OBJECT,b'\xa5'*0x30000);self.uc.mem_write(OBJECT+0x1d,bytes(260))
        self.uc.mem_write(OBJECT+0x21f7c,struct.pack('<4I',*OLD))
        self.uc.mem_write(OBJECT+0x13535,bytes([chapter]));self.uc.mem_write(OBJECT+0x1355b,bytes([progress]))
        self.uc.mem_write(GLOBAL,bytes(0xbe4))
        self.uc.mem_write(GLOBAL+0xbe0,bytes([action,waiting]))
        if not finish:self.uc.mem_write(GLOBAL,struct.pack('<4I',100,101,102,103))
        self.uc.mem_write(TABLE,b''.join(struct.pack('<bb',*v) for v in case['table']))
        self.uc.mem_write(0x6d39d0,struct.pack('<26I',*(0x12340000+i*16 for i in range(26))))
        self.uc.mem_write(0x6d3a44,bytes(i%3 for i in range(26)))
        self.uc.mem_write(0x6d3a84,bytes(i%5 for i in range(26)))
        arguments=(OBJECT,) if finish else (OBJECT,GLOBAL,TABLE)
        self.uc.mem_write(0x10008000,struct.pack('<'+'I'*(len(arguments)+1),0x30000000,*arguments))
        self.uc.reg_write(UC_X86_REG_ESP,0x10008000);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(0x606440 if finish else 0x52bcf0,0x30000000,count=5000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=0x30000000 or self.uc.reg_read(UC_X86_REG_ESP)!=0x10008004:
            raise RuntimeError('Original intro did not return within bounded instructions')
        if self.departed and not [10,0] in self.commands:
            if any(self.word(OBJECT+i) for i in (0x21f7c,0x21f80,0x21f84,0x21f88)):raise RuntimeError('Stale callbacks')
        for kind,base in ((1,0x21f98),(2,0x21fb4)):
            if [7,kind] in self.commands and struct.unpack('<4I',self.uc.mem_read(OBJECT+base,16))!=OLD:raise RuntimeError('Callback backup changed order')
        if [6,chapter] in self.commands:
            if self.uc.mem_read(OBJECT+0x13530,1)[0]!=chapter%3 or self.uc.mem_read(OBJECT+0x13533,1)[0]!=chapter%5:raise RuntimeError('Chapter selector/stage differs')
        if [11,1] in self.commands and any(self.uc.mem_read(OBJECT+i,1)[0]!=1 for i in (0x1355b,0x156f3,0x1788b)):raise RuntimeError('Progress flags differ')
        result=[self.uc.mem_read(OBJECT+0x13535,1)[0],self.uc.mem_read(GLOBAL+0xbe0,1)[0],self.uc.mem_read(GLOBAL+0xbe1,1)[0],self.uc.mem_read(OBJECT+0x1355b,1)[0]]
        return {'state':result,'departed':self.departed,'commands':self.commands}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True)
    p.add_argument('--real-table',action='store_true',help='use the recovered real chapter descriptor table');args=p.parse_args()
    original=OriginalIntro(args.exe);lib=library();results={}
    sources=('finish',real_finish_cases,True),('transition',real_transition_cases,False) if args.real_table else (('finish',finish_cases,True),('transition',transition_cases,False))
    for name,source,finish in sources:
        digest=hashlib.sha256();count=0
        for case in source():
            expected=original.run(case,finish);actual=native_result(lib,case,finish)
            if expected!=actual:raise ValueError(f'{name} mismatch {case}: {expected} != {actual}')
            digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        results[name]={'cases':count,'output_sha256':digest.hexdigest()}
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'results':results,
        'coverage':('end-of-script chapter routing and transition dispatcher with the recovered real chapter descriptor table (0x0078d908); synthetic callback identities and host operations; selector/backup/progress writes verified'
            if args.real_table else 'end-of-script chapter routing and transition dispatcher; synthetic descriptors/callback identities and host operations; selector/backup/progress writes verified'),
        'original_game_resources_used':False,'game_playability':'not verified'}
    for path in (args.output,args.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(results))


if __name__=='__main__':main()
