"""Isolated original recursive transform driver with host D3DX43 math only.

Synthetic trees disable meshes, draw-list submission and billboards. Original
0x415620, constructor and camera-inverse wrapper execute. Matrix multiply and
inverse imports are pure math reference boundaries, not original DLL/GPU proof.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_EBP
from oracle_animation import OriginalAnimation, OBJECT, TARGET_SHA256, STACK, STOP
from native_core import library, Matrix
from scene_cases import cases, matrix

NODES, WORLD, CAMERA=0x20020000,OBJECT+0x1000,0x78f650
REFERENCE_NODE_LIMIT=512
REFERENCE_NODE_BYTES=(REFERENCE_NODE_LIMIT*0x210+4095)&~4095


class OriginalScene(OriginalAnimation):
    def __init__(self,exe,dll):
        super().__init__(exe,{0x415620:818,0x4211e0:14,0x406fc0:21})
        self.uc.mem_map(NODES,REFERENCE_NODE_BYTES,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_protect(CAMERA&~4095,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_write(CAMERA,bytes(matrix()))
        self.uc.mem_protect(CAMERA&~4095,4096,UC_PROT_READ)
        self.dll=C.WinDLL(str(dll.resolve()))
        self.multiply=self.dll.D3DXMatrixMultiply
        self.multiply.argtypes=[C.c_void_p]*3;self.multiply.restype=C.c_void_p
        self.inverse=self.dll.D3DXMatrixInverse
        self.inverse.argtypes=[C.c_void_p]*3;self.inverse.restype=C.c_void_p

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        index,offset=divmod(address-NODES,0x210)
        if 0<=index<self.count and ((offset==0x1e8 or offset==0x1ec) and size==4 or 0x54<=offset and offset+size<=0x94):return
        raise RuntimeError(f'Hierarchy write outside admitted spans: {address:#x}/{size}')

    def read(self,address,size):
        spans=((OBJECT,0x10000),(NODES,self.count*0x210),(0x10000000,0x10000),(CAMERA,64))
        if not any(start<=address and address+size<=start+length for start,length in spans):raise RuntimeError('Unadmitted math source')
        return bytes(self.uc.mem_read(address,size))

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in (0x60abe0,0x60ac04):raise RuntimeError(f'Hierarchy left admitted functions: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted math return')
        destination=self.word(stack+4)
        index,offset=divmod(destination-NODES,0x210)
        if not ((0x10000000<=destination and destination+64<=0x10010000) or
                (0<=index<self.count and offset==0x54)):raise RuntimeError('Unadmitted math output')
        result=C.create_string_buffer(64)
        if address==0x60abe0:
            a,b=[C.create_string_buffer(self.read(self.word(stack+i),64)) for i in (8,12)]
            returned=self.multiply(result,a,b)
        else:
            if self.word(stack+8)!=0 or self.word(stack+12)!=CAMERA:raise RuntimeError('Unexpected inverse args')
            source=C.create_string_buffer(self.read(CAMERA,64))
            returned=self.inverse(result,None,source)
        if returned!=C.addressof(result):raise RuntimeError('Reference math failed')
        uc.mem_write(destination,result.raw[:64])
        uc.reg_write(UC_X86_REG_EAX,destination);uc.reg_write(UC_X86_REG_ESP,stack+16);uc.reg_write(UC_X86_REG_EIP,target)

    def run_tree(self,nodes,world,initial=None):
        self.count=len(nodes)
        if not self.count or self.count>REFERENCE_NODE_LIMIT:raise ValueError('Synthetic tree too large')
        depths=[]
        for i,node in enumerate(nodes):
            if node.parent!=0xffffffff and node.parent>=i:raise ValueError('Parent order outside reference profile')
            depth=0 if node.parent==0xffffffff else depths[node.parent]+1
            if depth>64:raise ValueError('Tree exceeds bounded reference stack depth')
            depths.append(depth)
        self.uc.mem_write(OBJECT,b'\0'*0x10000)
        self.uc.mem_write(NODES,b'\0'*(self.count*0x210))
        self.uc.mem_write(WORLD,bytes(world))
        initial=initial if initial is not None else [matrix(translation=(99,98,97)) for _ in nodes]
        for i,n in enumerate(nodes):
            children=[j for j,m in enumerate(nodes) if m.parent==i]
            if children and children!=list(range(children[0],children[-1]+1)):raise ValueError('Original siblings must be contiguous')
            at=NODES+i*0x210
            self.uc.mem_write(at+8,struct.pack('<2I',len(children),NODES+children[0]*0x210 if children else 0))
            self.uc.mem_write(at+0x14,bytes(n.local));self.uc.mem_write(at+0x54,bytes(initial[i]));self.uc.mem_write(at+0x94,bytes(n.extra))
            self.uc.mem_write(at+0x154,struct.pack('<I',n.modifier));self.uc.mem_write(at+0x158,bytes([n.billboard]))
            self.uc.mem_write(at+0x1f8,bytes([n.hidden]))
        roots=[i for i,n in enumerate(nodes) if n.parent==0xffffffff]
        for root in roots:
            self.uc.mem_write(STACK,struct.pack('<5I',STOP,OBJECT,OBJECT,NODES+root*0x210,WORLD))
            self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
            self.uc.emu_start(0x415620,STOP,count=500000)
            if self.uc.reg_read(UC_X86_REG_EIP)!=STOP or self.uc.reg_read(UC_X86_REG_ESP)!=STACK+4:
                raise RuntimeError('Original hierarchy did not return within bounded instructions')
        return [bytes(self.uc.mem_read(NODES+i*0x210+0x54,64)) for i in range(self.count)]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--d3dx',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--vectors',type=Path,required=True)
    args=parser.parse_args();original=OriginalScene(args.exe,args.d3dx);lib=library();rows=[];error=0
    for case,(nodes,world) in enumerate(cases()):
        reference=original.run_tree(nodes,world)
        out=(Matrix*len(nodes))(*(matrix(translation=(99,98,97)) for _ in nodes))
        assert lib.dc_scene_update(nodes,len(nodes),C.byref(world),out,len(nodes))==0
        for native,expected in zip(out,reference):
            for a,b in zip(native.values,struct.unpack('<16f',expected)):
                error=max(error,abs(a-b))
                if abs(a-b)>5e-5*(1+abs(b)):raise ValueError('Original/reference hierarchy differs from native')
        rows.append({'case':case,'global_hex':[v.hex() for v in reference]})
    report={'target_sha256':TARGET_SHA256,'cases':len(rows),'vectors':rows,'max_absolute_error':error,
            'original_function_sha256':original.hashes,'host_d3dx43_sha256':hashlib.sha256(args.d3dx.read_bytes()).hexdigest(),
            'execution':'isolated recursive transform driver and camera wrapper; pure math D3DX43 reference imports',
            'coverage':'self-authored trees, modifiers 0/1/2, hidden subtrees; no mesh/draw lists/billboard/GPU',
            'original_game_resources_used':False,'game_playability':'not verified'}
    for p in (args.output,args.vectors):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('vectors','original_function_sha256')}))

if __name__=='__main__':main()
