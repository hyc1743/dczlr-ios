"""Isolate original node selection/lerp with bounded host D3DX43 math calls.

Original search/conversion/vector lerp and mode-0 driver execute in Unicorn.
Matrix/quaternion imports execute only pure math exports of a caller-supplied
64-bit D3DX43 reference DLL. This is not the original game's D3DX version or
GPU pipeline. Public vectors contain self-authored inputs/hashes only.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EAX, UC_X86_REG_EBP
from oracle_animation import OriginalAnimation, OBJECT, QUERY_OUT, STACK, STOP, TARGET_SHA256
from native_core import library, PoseKey, PoseSelection, Matrix
from pose_cases import key, selection_cases, transform_cases

CALLER, TRACK, NODE, KEYS = 0x30001000, OBJECT+0x1000, OBJECT+0x2000, OBJECT+0x3000
MATH = {0x60abf8: ('D3DXQuaternionSlerp',16,[16,16],True),
        0x60abf2: ('D3DXMatrixRotationQuaternion',64,[16],False),
        0x60abe0: ('D3DXMatrixMultiply',64,[64,64],False),
        0x60abe6: ('D3DXMatrixTranslation',64,[],False),
        0x60abec: ('D3DXMatrixScaling',64,[],False)}


class OriginalPose(OriginalAnimation):
    def __init__(self, exe, d3dx=None):
        super().__init__(exe,{0x412ff0:143,0x413080:115,0x61e344:117,0x406c60:85,0x412c40:935,0x4211e0:14})
        self.uc.mem_map(CALLER,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.callers=set()
        for slot,entry in enumerate((0x412ff0,0x413080,0x412c40)):
            address=CALLER+slot*128
            code=b'\xdb\xe3\xd9\x2d'+struct.pack('<I',QUERY_OUT+8)
            code+=b'\xe9'+struct.pack('<i',entry-(address+13))
            self.uc.mem_write(address,code)
            self.callers.update((address,address+2,address+8))
        self.uc.mem_protect(CALLER,4096,UC_PROT_READ|UC_PROT_EXEC)
        self.math={}
        if d3dx:
            self.dll=C.WinDLL(str(d3dx.resolve()))
            for address,(name,size,inputs,weight) in MATH.items():
                function=getattr(self.dll,name)
                function.restype=C.c_void_p
                function.argtypes=[C.c_void_p]*(1+len(inputs))+([C.c_float] if weight else [])
                if not inputs: function.argtypes=[C.c_void_p,C.c_float,C.c_float,C.c_float]
                self.math[address]=function

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000: return
        if NODE+0x14<=address and address+size<=NODE+0x54: return
        raise RuntimeError(f'Pose write outside admitted spans: {address:#x}/{size}')

    def read(self,address,size):
        if not ((OBJECT<=address and address+size<=OBJECT+0x10000) or
                (0x10000000<=address and address+size<=0x10010000)):
            raise RuntimeError('Math source outside synthetic spans')
        return bytes(self.uc.mem_read(address,size))

    def code_guard(self,uc,address,size,context):
        if address in self.instructions or address in self.callers: return
        stack=uc.reg_read(UC_X86_REG_ESP); target=self.word(stack)
        if target not in self.instructions: raise RuntimeError('Pose host return outside admitted caller')
        pop=0
        if address in self.math:
            name,length,inputs,weight=MATH[address]
            destination=self.word(stack+4)
            if not ((0x10000000<=destination and destination+length<=0x10010000) or
                    (destination==NODE+0x14 and length==64)):
                raise RuntimeError('Math output outside admitted spans')
            out=C.create_string_buffer(length)
            buffers=[C.create_string_buffer(self.read(self.word(stack+8+i*4),n)) for i,n in enumerate(inputs)]
            args=[out,*buffers]
            if weight:
                w=struct.unpack('<f',self.read(stack+8+len(inputs)*4,4))[0]
                self.weight=w
                args.append(w)
            if not inputs:
                args.extend(struct.unpack('<3f',self.read(stack+8,12)))
            result=self.math[address](*args)
            if result!=C.addressof(out): raise RuntimeError('D3DX math did not return output')
            uc.mem_write(destination,out.raw[:length])
            uc.reg_write(UC_X86_REG_EAX,destination)
            pop=4*(1+len(inputs)+int(weight)) if inputs else 16
        else:
            raise RuntimeError(f'Pose left admitted functions: {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,stack+4+pop)
        uc.reg_write(UC_X86_REG_EIP,target)

    def prepare(self,keys,frame,control):
        if len(keys)<2 or len(keys)*52>0xc000: raise ValueError('Key count outside harness')
        self.uc.mem_write(OBJECT,b'\0'*0x10000)
        raw=b''.join(bytes(k) for k in keys)
        self.uc.mem_write(KEYS,raw)
        self.uc.mem_write(TRACK+8,struct.pack('<4I',len(keys),0,KEYS,NODE))
        self.uc.mem_write(OBJECT+0x2dc,struct.pack('<2I',1,TRACK))
        self.uc.mem_write(QUERY_OUT+8,struct.pack('<H',control))
        self.frame_bits=struct.unpack('<I',struct.pack('<f',frame))[0]
        self.raw=raw

    def call(self,slot,object):
        self.uc.mem_write(STACK,struct.pack('<3I',STOP,object,self.frame_bits))
        self.uc.reg_write(UC_X86_REG_ESP,STACK); self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(CALLER+slot*128,STOP,count=50000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=STOP or self.uc.reg_read(UC_X86_REG_ESP)!=STACK+4:
            raise RuntimeError('Pose call did not return within bound')
        if bytes(self.uc.mem_read(KEYS,len(self.raw)))!=self.raw: raise RuntimeError('Input keys changed')
        return self.uc.reg_read(UC_X86_REG_EAX)

    def select(self,keys,frame,control):
        self.prepare(keys,frame,control)
        addresses=[self.call(slot,TRACK) for slot in (0,1)]
        if any(a<KEYS or (a-KEYS)%52 or a>=KEYS+len(self.raw) for a in addresses): raise RuntimeError('Bad key address')
        return [(a-KEYS)//52 for a in addresses]

    def sample(self,keys,frame,control):
        self.prepare(keys,frame,control)
        self.weight=None
        self.call(2,OBJECT)
        return struct.unpack('<16f',self.read(NODE+0x14,64)),self.weight


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True)
    parser.add_argument('--d3dx',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--vectors',type=Path,required=True)
    args=parser.parse_args()
    original,lib=OriginalPose(args.exe,args.d3dx),library()
    rows=[]; matrices=[]; max_error=0.0; samples=0
    for frames,frame in selection_cases():
        keys=(PoseKey*len(frames))(*(key(f) for f in frames)); result=PoseSelection()
        assert lib.dc_pose_select(keys,len(keys),frame,C.byref(result))==0
        for control in (0x27f,0x37f):
            expected=original.select(keys,frame,control)
            if expected!=[result.left,result.right]: raise ValueError('Original/native key selection differs')
            rows.append({'frames':frames,'frame':frame,'control':control,'selection':expected})
    if args.d3dx:
        for case_index,(source,frame) in enumerate(transform_cases()):
            keys=(PoseKey*len(source))(*source); out=Matrix(); selection=PoseSelection()
            assert lib.dc_pose_sample(keys,len(keys),0,frame,C.byref(out))==0
            assert lib.dc_pose_select(keys,len(keys),frame,C.byref(selection))==0
            for control in (0x27f,0x37f):
                expected,weight=original.sample(keys,frame,control)
                matrices.append({'case':case_index,'control':control,'matrix_hex':struct.pack('<16f',*expected).hex(),
                                 'weight_hex':struct.pack('<f',weight).hex()})
                if struct.pack('<f',weight)!=struct.pack('<f',selection.weight): raise ValueError('Pose weight bytes differ')
                for a,b in zip(out.values,expected):
                    error=abs(a-b);max_error=max(max_error,error)
                    if error>5e-5*(1+abs(b)): raise ValueError(f'Pose matrix differs: {a}/{b}')
                samples+=1
    report={'schema':1,'target_sha256':TARGET_SHA256,'selection_cases':len(rows),'selection_vectors':rows,
            'matrix_comparisons':samples,'matrix_vectors':matrices,'matrix_tolerance':'abs <= 5e-5*(1+abs(reference))','max_absolute_error':max_error,
            'original_function_sha256':original.hashes,'original_game_resources_used':False,
            'host_d3dx43_sha256':hashlib.sha256(args.d3dx.read_bytes()).hexdigest() if args.d3dx else None,
            'coverage':'original selection/conversion/mode-0 driver/vector lerp; host reference D3DX43 pure math boundaries; no original DLL/GPU or hierarchy',
            'game_playability':'not_verified'}
    for p in (args.output,args.vectors):
        p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('selection_vectors','matrix_vectors','original_function_sha256')}))

if __name__=='__main__': main()
