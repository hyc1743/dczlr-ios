"""Isolate original XX bone loader and name/global-matrix pointer binding.

Only the pinned loader, byte-complement decoder and binding/search functions
execute. Allocation, memcpy and strcmp are synthetic bounded operations.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_EBP
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from bone_cases import cases,native_result

INPUT,HEAP,NODES=0x20011000,0x20030000,OBJECT+0x1000
CURSOR,SEARCH_RESULT=0x78f710,0x79f788


class OriginalBones(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,{0x40a6d0:0x40a86d-0x40a6d0,0x40d770:72,0x409830:0x4098f5-0x409830,0x4131f0:114,0x413270:109})
        self.uc.mem_map(INPUT,0x40000,UC_PROT_READ|UC_PROT_WRITE)
        for at in (CURSOR,SEARCH_RESULT):self.uc.mem_protect(at&~4095,4096,UC_PROT_READ|UC_PROT_WRITE)

    def heap_range(self,at,length):
        return any(start<=at and at+length<=start+size for start,size in self.allocations)

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if size==4 and address in (CURSOR,SEARCH_RESULT,self.node+0x1e0,self.node+0x1e4):return
        if self.heap_range(address,size):return
        raise RuntimeError(f'Bone code wrote outside admitted spans: {address:#x}/{size}')

    def allocate(self,length):
        if not length or self.heap_next+length>HEAP+0x10000:raise RuntimeError('Bone allocation outside bounded heap')
        at=self.heap_next;self.heap_next=(at+length+15)&~15;self.allocations.append((at,length))
        self.uc.mem_write(at,bytes(length));return at

    def string(self,at):
        if not self.heap_range(at,1):raise RuntimeError('Name pointer outside bounded heap')
        for i in range(256):
            if not self.heap_range(at,i+1):raise RuntimeError('Unterminated synthetic bone/node name')
            if self.uc.mem_read(at+i,1)[0]==0:return bytes(self.uc.mem_read(at,i))
        raise RuntimeError('Synthetic name exceeds reference bound')

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in (0x4233d0,0x61dfb0,0x61e400):raise RuntimeError(f'Bone code left admitted functions: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted host return')
        if address==0x4233d0:eax=self.allocate(self.word(stack+4))
        elif address==0x61dfb0:
            destination,source,length=(self.word(stack+i) for i in (4,8,12))
            if source!=INPUT+self.word(CURSOR) or not INPUT<=source<=source+length<=INPUT+self.input_length:raise RuntimeError('Unadmitted bone memcpy source')
            if not (length==4 and destination==self.node+0x1e0) and not self.heap_range(destination,length):raise RuntimeError('Unadmitted bone memcpy destination')
            uc.mem_write(destination,bytes(uc.mem_read(source,length)));eax=destination
        else:
            a,b=self.string(self.word(stack+4)),self.string(self.word(stack+8));eax=(a>b)-(a<b)
        uc.reg_write(UC_X86_REG_EAX,eax&0xffffffff);uc.reg_write(UC_X86_REG_ESP,stack+4);uc.reg_write(UC_X86_REG_EIP,target)

    def execute(self,address,*arguments):
        self.uc.mem_write(0x10008000,struct.pack('<'+'I'*(len(arguments)+1),0x30000000,*arguments))
        self.uc.reg_write(UC_X86_REG_ESP,0x10008000);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(address,0x30000000,count=500000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=0x30000000 or self.uc.reg_read(UC_X86_REG_ESP)!=0x10008004:raise RuntimeError('Bone reference did not return within bound')

    def run_table(self,table,bind=True):
        if len(table)>65536:raise ValueError('Bone table outside reference bound')
        self.node=NODES+0x210;self.input_length=len(table);self.allocations=[];self.heap_next=HEAP
        self.uc.mem_write(OBJECT,bytes(0x10000));self.uc.mem_write(CURSOR,bytes(4))
        self.uc.mem_protect(INPUT,0x10000,UC_PROT_READ|UC_PROT_WRITE);self.uc.mem_write(INPUT,table)
        self.uc.mem_protect(INPUT,0x10000,UC_PROT_READ)
        self.execute(0x40a6d0,self.node,INPUT)
        if self.word(CURSOR)!=len(table):raise RuntimeError('Original bone table cursor differs')
        count=self.word(self.node+0x1e0);array=self.word(self.node+0x1e4);records=[]
        for i in range(count):
            at=array+i*0x50;length=self.word(at)
            if not self.heap_range(self.word(at+4),length):raise RuntimeError('Bone name outside heap')
            records.append({'name_hex':bytes(self.uc.mem_read(self.word(at+4),length)).hex(),'index':self.word(at+8),
                'matrix_hex':bytes(self.uc.mem_read(at+12,64)).hex()})
        if not bind:return {'records':records}
        self.uc.mem_write(OBJECT+0x218,struct.pack('<I',NODES))
        for i,label in enumerate((b'root-only\0',b'carrier\0',b'synthetic-node\0',b'synthetic-node\0')):
            at=self.allocate(len(label));self.uc.mem_write(at,label)
            self.uc.mem_write(NODES+i*0x210+4,struct.pack('<3I',at,3 if i==0 else 0,NODES+0x210 if i==0 else 0))
        self.execute(0x409830,OBJECT,self.node)
        targets=[]
        for i in range(count):
            pointer=self.word(array+i*0x50+0x4c)
            if not pointer:targets.append(0xffffffff)
            else:
                selected=(pointer-NODES-0x54)//0x210
                if pointer!=NODES+selected*0x210+0x54 or not 1<=selected<=3:raise RuntimeError('Unadmitted bound matrix pointer')
                targets.append(selected)
        return {'records':records,'targets':targets}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);args=p.parse_args()
    original=OriginalBones(args.exe);digest=hashlib.sha256();count=0
    for case in cases():
        expected=original.run_table(bytes.fromhex(case['table_hex']));actual=native_result(case)
        if expected!=actual:raise ValueError(f'Original bone table/binding mismatch at {count}')
        digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
    report={'target_sha256':TARGET_SHA256,'cases':count,'output_sha256':digest.hexdigest(),'original_function_sha256':original.hashes,
        'coverage':'name/index/matrix loader and global-matrix-pointer binding on self-authored duplicate/root/missing targets; bounded heap/memcpy/strcmp',
        'original_game_resources_used':False,'game_playability':'not verified'}
    for path in (args.output,args.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':count,'matched':True,'output_sha256':digest.hexdigest()}))


if __name__=='__main__':main()
