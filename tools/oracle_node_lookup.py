"""Original recursive XX node lookup on self-authored trees and bounded strcmp."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import XXModel,library
from xx_cases import fixture

GLOBAL=0x79f788
NODE=OBJECT+0x1000


class OriginalNodeLookup(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,{0x4131f0:114,0x413270:109})
        self.uc.mem_protect(GLOBAL&~4095,4096,UC_PROT_READ|UC_PROT_WRITE)

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if (address,size)==(GLOBAL,4):return
        raise RuntimeError('Node lookup wrote outside admitted state')

    def string(self,address):
        if not OBJECT<=address<=OBJECT+0xff00:raise RuntimeError('Unadmitted strcmp source')
        raw=bytes(self.uc.mem_read(address,256))
        if b'\0' not in raw:raise RuntimeError('Unterminated synthetic name')
        return raw.split(b'\0',1)[0]

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address!=0x61e400:raise RuntimeError('Node lookup left admitted functions')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Bad strcmp return')
        a,b=self.string(self.word(stack+4)),self.string(self.word(stack+8))
        uc.reg_write(UC_X86_REG_EAX,0 if a==b else 1)
        uc.reg_write(UC_X86_REG_ESP,stack+4);uc.reg_write(UC_X86_REG_EIP,target)

    def lookup(self,depth,query):
        self.uc.mem_write(OBJECT,b'\0'*0x10000)
        header=OBJECT+0x800;label=OBJECT+0x9000;argument=OBJECT+0xa000
        self.uc.mem_write(OBJECT+0x218,struct.pack('<I',header))
        self.uc.mem_write(header+8,struct.pack('<2I',1,NODE))
        self.uc.mem_write(label,b'synthetic-node\0')
        self.uc.mem_write(argument,query)
        for i in range(depth+1):
            self.uc.mem_write(NODE+i*0x210+4,struct.pack('<3I',label,int(i<depth),NODE+(i+1)*0x210 if i<depth else 0))
        self.execute(0x4131f0,OBJECT,argument)
        result=self.uc.reg_read(UC_X86_REG_EAX)
        if not result:return None
        if (result-NODE)%0x210 or not NODE<=result<=NODE+depth*0x210:raise RuntimeError('Unadmitted matched node')
        return (result-NODE)//0x210


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--vectors',type=Path,required=True)
    args=parser.parse_args();original=OriginalNodeLookup(args.exe);lib=library();rows=[]
    for depth in (0,1,4):
        with XXModel(fixture(depth=depth)) as model:
            for query in (b'synthetic-node\0',b'synthetic-node\0ignored',b'Synthetic-node\0',b'other\0'):
                expected=original.lookup(depth,query)
                result=C.c_uint32(0xffffffff);encoded=bytes(b^255 for b in query)
                status=lib.dc_xx_find_node_encoded(model.handle,encoded,len(encoded),C.byref(result))
                mismatch = ((status,result.value)!=(0,expected) if expected is not None
                            else (status!=6 or result.value!=0xffffffff))
                if mismatch:
                    raise ValueError('Original/native node binding differs')
                rows.append({'depth':depth,'query_hex':query.hex(),'selected':expected})
    report={'target_sha256':TARGET_SHA256,'cases':len(rows),'vectors':rows,'original_function_sha256':original.hashes,
            'execution':'isolated original recursive node lookup; synthetic bounded exact-equality strcmp',
            'original_game_resources_used':False,'gpu':'not executed','game_playability':'not verified'}
    for p in (args.output,args.vectors):
        p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':len(rows),'matched':True}))

if __name__=='__main__':main()
