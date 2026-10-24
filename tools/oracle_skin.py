"""Original indexed palette prefix + host Direct3D9 software vertex reference.

Original draw prefix stops before texture/material/render submission. D3DX43
matrix operations are reference boundaries. NULLREF ProcessVertices uses only
self-authored source data; neither renderer draws, Presents nor loads a game.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EBP,UC_X86_REG_EAX
from oracle_animation import OriginalAnimation,TARGET_SHA256
from d3d9_reference import D3D9Reference
from scene_cases import matrix
from skin_cases import cases,native_result,palette_cases,native_palette,decode_source

REG,DEVICE,VTABLE,NODE,MATERIAL,MESH,BONES,GLOBALS=0x20020000,0x20020000,0x20020100,0x20020500,0x20021000,0x20021200,0x20022000,0x20030000
STATE_STUB,TRANSFORM_STUB,END=0x30000100,0x30000110,0x4134a3


class D3DXReference:
    def __init__(self,path):
        self.dll=C.WinDLL(str(path.resolve()));self.sha=hashlib.sha256(path.read_bytes()).hexdigest()
        self.multiply=self.dll.D3DXMatrixMultiply;self.inverse=self.dll.D3DXMatrixInverse
        self.transpose=self.dll.D3DXMatrixTranspose;self.normal=self.dll.D3DXVec3TransformNormal;self.normalize=self.dll.D3DXVec3Normalize
        for function,n in ((self.multiply,3),(self.inverse,3),(self.transpose,2),(self.normal,3),(self.normalize,2)):
            function.argtypes=[C.c_void_p]*n;function.restype=C.c_void_p

    def normal_result(self,case,mode):
        vertex,weights=decode_source(case)
        if not mode:return list(vertex.normal)
        f32=lambda value:struct.unpack('<f',struct.pack('<f',value))[0]
        blend=list(weights.weights);blend.append(f32(1-f32(f32(blend[0]+blend[1])+blend[2])))
        palette={index:bytes.fromhex(raw) for index,raw in case['palette']};result=[0.,0.,0.]
        for weight,index in zip(blend,weights.indices):
            if weight==0:continue
            source=C.create_string_buffer(palette.get(index,bytes(matrix())));inverse=C.create_string_buffer(64);transposed=C.create_string_buffer(64)
            if not self.inverse(inverse,None,source):raise RuntimeError('Reference inverse failed')
            self.transpose(transposed,inverse);out=(C.c_float*3)();self.normal(out,vertex.normal,transposed)
            for j in range(3):result[j]=f32(result[j]+f32(out[j]*weight))
        if mode==2:
            source=(C.c_float*3)(*result);out=(C.c_float*3)();self.normalize(out,source);result=list(out)
        return result


class OriginalPalette(OriginalAnimation):
    def __init__(self,exe,math):
        super().__init__(exe,{0x4132e0:END-0x4132e0,0x4211e0:14},fragment_ends={0x4132e0:'mov'})
        self.math=math;self.uc.mem_map(REG,0x40000,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_protect(0x79f000,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_write(0x79f7f8,struct.pack('<I',DEVICE))

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        raise RuntimeError(f'Palette prefix wrote outside stack: {address:#x}/{size}')

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in (STATE_STUB,TRANSFORM_STUB,0x60abe0,0x61dfb0):raise RuntimeError(f'Palette prefix left admitted operations: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted palette boundary return')
        arg=lambda i:self.word(stack+4*i);eax=0;pop=4
        if address==STATE_STUB:
            if (arg(1),arg(2),arg(3)) not in ((DEVICE,0x97,3),(DEVICE,0xa7,1)):raise RuntimeError('Unexpected indexed blend state')
            pop=16
        elif address==TRANSFORM_STUB:
            if arg(1)!=DEVICE or not 256<=arg(2)<=511:raise RuntimeError('Unexpected world slot')
            at=arg(3)
            if not (0x10000000<=at and at+64<=0x10010000):raise RuntimeError('Unadmitted transform output')
            self.transforms.append((arg(2)-256,bytes(uc.mem_read(at,64))));pop=16
        elif address==0x60abe0:
            destination,left,right=arg(1),arg(2),arg(3)
            if not (0x10000000<=destination and destination+64<=0x10010000):raise RuntimeError('Unadmitted matrix destination')
            offset=left-(BONES+12);target_index=right-GLOBALS
            if offset<0 or offset%0x50 or offset//0x50>=self.bone_count or target_index<0 or target_index%64 or target_index//64>=self.global_count:
                raise RuntimeError('Unadmitted bound matrix source')
            result=C.create_string_buffer(64);a=C.create_string_buffer(bytes(uc.mem_read(left,64)));b=C.create_string_buffer(bytes(uc.mem_read(right,64)))
            self.math.multiply(result,a,b);uc.mem_write(destination,result.raw);eax=destination;pop=16
        else:
            if (arg(2),arg(3))!=(MATERIAL+8,68):raise RuntimeError('Unexpected material-prefix copy')
            self.write_guard(uc,0,arg(1),68,0,None);uc.mem_write(arg(1),bytes(uc.mem_read(arg(2),68)));eax=arg(1)
        uc.reg_write(UC_X86_REG_EAX,eax);uc.reg_write(UC_X86_REG_ESP,stack+pop);uc.reg_write(UC_X86_REG_EIP,target)

    def run(self,case):
        if len(case['bones'])>256 or len(case['globals'])>2048:raise ValueError('Palette reference input exceeds bound')
        self.transforms=[];self.bone_count=len(case['bones']);self.global_count=len(case['globals'])
        self.uc.mem_write(REG,bytes(0x40000));self.uc.mem_write(DEVICE,struct.pack('<I',VTABLE))
        self.uc.mem_write(VTABLE+0xe4,struct.pack('<I',STATE_STUB));self.uc.mem_write(VTABLE+0xb0,struct.pack('<I',TRANSFORM_STUB))
        self.uc.mem_write(NODE+0x18c,struct.pack('<I',0x111c));self.uc.mem_write(NODE+0x1e0,struct.pack('<2I',len(case['bones']),BONES))
        self.uc.mem_write(NODE+0x1e8,struct.pack('<f',1));self.uc.mem_write(MESH+0x20,struct.pack('<I',MATERIAL))
        self.uc.mem_write(MATERIAL+8,struct.pack('<17f',*([1]*17)))
        for i,raw in enumerate(case['globals']):self.uc.mem_write(GLOBALS+i*64,bytes.fromhex(raw))
        for i,bone in enumerate(case['bones']):
            at=BONES+i*0x50;self.uc.mem_write(at+8,struct.pack('<I',bone['index']));self.uc.mem_write(at+12,bytes.fromhex(bone['offset_hex']))
            self.uc.mem_write(at+0x4c,struct.pack('<I',0 if bone['target']==0xffffffff else GLOBALS+bone['target']*64))
        self.uc.mem_write(0x10008000,struct.pack('<4I',0x30000000,REG+0x1f000,NODE,MESH))
        self.uc.reg_write(UC_X86_REG_ESP,0x10008000);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(0x4132e0,END,count=50000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=END:raise RuntimeError('Original palette prefix did not reach bounded stop')
        result=[list(matrix().values) for _ in range(256)]
        for index,raw in case['initial']:result[index]=list(struct.unpack('<16f',bytes.fromhex(raw)))
        for index,raw in self.transforms:result[index]=list(struct.unpack('<16f',raw))
        return result


def close(a,b):return abs(a-b)<=5e-5*(1+abs(b))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--d3dx',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);args=p.parse_args()
    math=D3DXReference(args.d3dx);original=OriginalPalette(args.exe,math);palette_rows=[];skin_rows=[];max_error=0
    for i,case in enumerate(palette_cases()):
        expected=original.run(case);actual=native_palette(case)
        for a,b in zip(actual,expected):
            if not all(close(x,y) for x,y in zip(a,b)):raise ValueError(f'Original palette mismatch at case {i}')
        selected=sorted({0,7,255}|{b['index'] for b in case['bones'] if b['index']!=255})
        palette_rows.append({'case':i,'matrices':[[index,expected[index]] for index in selected]})
    with D3D9Reference() as device:
        assert tuple(struct.unpack('<16f',device.get_transform(511)))==tuple(matrix().values)
        for i,case in enumerate(cases()):
            raw=device.process(bytes.fromhex(case['source_hex']),{index:bytes.fromhex(data) for index,data in case['palette']})
            screen=list(struct.unpack('<4f',raw));normals=[]
            for mode in range(3):
                expected_normal=math.normal_result(case,mode);actual=native_result(case,mode)
                for a,b in zip(actual['screen'],screen):
                    max_error=max(max_error,abs(a-b))
                    if not close(a,b):raise ValueError(f'Direct3D software vertex mismatch at case {i}, mode {mode}: {actual["screen"]} != {screen}')
                if not all(close(a,b) for a,b in zip(actual['normal'],expected_normal)):raise ValueError(f'D3DX normal reference mismatch at case {i}/{mode}')
                normals.append(expected_normal)
            skin_rows.append({'case':i,'screen':screen,'normals':normals})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'host_d3dx43_sha256':math.sha,
        'palette_cases':palette_rows,'skin_cases':skin_rows,'max_screen_error':max_error,
        'coverage':'isolated original palette prefix and host NULLREF/SWVP ProcessVertices for synthetic FVF111c; normals use D3DX inverse-transpose math',
        'original_game_resources_used':False,'draw_or_present_called':False,'game_playability':'not verified'}
    for path in (args.output,args.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'palette_cases':len(palette_rows),'skin_cases':len(skin_rows),'max_screen_error':max_error,'matched':True}))


if __name__=='__main__':main()
