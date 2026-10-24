"""Bounded offline original orbit/projection drivers, synthetic inputs only.

The two orbit bodies and projection body execute in Unicorn. Identity, D3DX
math and device calls are explicit reference/synthetic boundaries. Camera-world
publication is intercepted; the view inverse uses host D3DX43 math. This is
not a game process, original preset loader, renderer or collision controller.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library,CameraMatrices
from scene_cases import matrix
from camera_cases import cases

PROJECTION=0x78f690
DEVICE,VTABLE=OBJECT+0x4000,OBJECT+0x4100
GET_VIEWPORT,SET_TRANSFORM=0x422660,0x422670
MATH={0x60ac28:('D3DXMatrixRotationY',1),0x60ac2e:('D3DXMatrixRotationX',1),
      0x60abe6:('D3DXMatrixTranslation',3),0x60ac0a:('D3DXMatrixPerspectiveFovRH',4)}


class OriginalCamera(OriginalAnimation):
    def __init__(self,exe,dll):
        super().__init__(exe,{0x4656c0:0x1a2,0x4790d0:0x122,0x407020:0x13a,0x4211e0:14})
        for page in (0x78f000,0x661000,0x7c8000):
            self.uc.mem_protect(page,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_write(0x7c82a8,bytes(4))
        self.uc.mem_write(0x78f648,struct.pack('<I',DEVICE))
        self.uc.mem_write(DEVICE,struct.pack('<I',VTABLE))
        self.uc.mem_write(VTABLE+0xc0,struct.pack('<I',GET_VIEWPORT))
        self.uc.mem_write(VTABLE+0xb0,struct.pack('<I',SET_TRANSFORM))
        self.dll=C.WinDLL(str(dll.resolve()))
        self.math={}
        for address,(name,count) in MATH.items():
            f=getattr(self.dll,name);f.argtypes=[C.c_void_p]+[C.c_float]*count;f.restype=C.c_void_p
            self.math[address]=f
        self.multiply=self.dll.D3DXMatrixMultiply
        self.multiply.argtypes=[C.c_void_p]*3;self.multiply.restype=C.c_void_p
        self.inverse=self.dll.D3DXMatrixInverse
        self.inverse.argtypes=[C.c_void_p]*3;self.inverse.restype=C.c_void_p

    @staticmethod
    def valid(address,size):
        return any(start<=address and address+size<=start+length for start,length in (
            (OBJECT,0x148),(0x10000000,0x10000),(PROJECTION,128)))

    def read(self,address,size):
        if not self.valid(address,size):raise RuntimeError('Unadmitted camera math span')
        return bytes(self.uc.mem_read(address,size))

    def write_guard(self,uc,access,address,size,value,context):
        if self.valid(address,size) or 0x6610ec<=address and address+size<=0x6610f8:return
        raise RuntimeError(f'Camera write outside admitted spans: {address:#x}/{size}')

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted camera return')
        destination=self.word(stack+4);pop=0
        if address in MATH or address in (0x407330,0x60abe0):
            if not self.valid(destination,64):raise RuntimeError('Unadmitted camera math output')
            out=C.create_string_buffer(64)
            if address in MATH:
                count=MATH[address][1]
                args=struct.unpack('<'+'f'*count,self.read(stack+8,count*4))
                result=self.math[address](out,*args);pop=4*(count+1)
            elif address==0x60abe0:
                a,b=[C.create_string_buffer(self.read(self.word(stack+i),64)) for i in (8,12)]
                result=self.multiply(out,a,b);pop=12
            else:
                out=C.create_string_buffer(bytes(matrix()),64);result=C.addressof(out)
            if result!=C.addressof(out):raise RuntimeError('Reference camera math failed')
            uc.mem_write(destination,out.raw[:64]);uc.reg_write(UC_X86_REG_EAX,destination)
        elif address in (0x406e20,0x422630):
            expected=OBJECT+(0xc8 if address==0x406e20 else 0xc0)
            if destination!=expected:raise RuntimeError('Unexpected camera world publication')
            if address==0x422630 and self.word(stack+8)&255:raise RuntimeError('Unexpected camera slot')
            self.world=self.read(destination,64)
        elif address==GET_VIEWPORT:
            if destination!=DEVICE:raise RuntimeError('Unexpected viewport device')
            out=self.word(stack+8)
            if not self.valid(out,24):raise RuntimeError('Unadmitted viewport output')
            uc.mem_write(out,struct.pack('<4I2f',0,0,*self.dimensions,0,1));pop=8
            self.viewport_calls+=1
        elif address==SET_TRANSFORM:
            if [destination,self.word(stack+8),self.word(stack+12)]!=[DEVICE,3,PROJECTION]:
                raise RuntimeError('Unexpected camera transform submission')
            self.projection=self.read(PROJECTION,64);pop=12;self.submissions+=1
        else:raise RuntimeError(f'Camera left admitted functions: {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,stack+4+pop);uc.reg_write(UC_X86_REG_EIP,target)

    def run(self,orbit,lens,global_controller=False):
        self.uc.mem_write(OBJECT,bytes(0x148));self.world=None
        base,scalars=(8,0x108) if global_controller else (0x80,0x100)
        self.uc.mem_write(OBJECT+base,bytes(orbit.base))
        self.uc.mem_write(OBJECT+scalars,struct.pack('<4f',orbit.stored_distance,orbit.height,orbit.pitch,orbit.yaw))
        if global_controller:self.execute(0x4656c0,OBJECT)
        else:self.execute(0x4790d0,OBJECT,0)
        if self.world is None:raise RuntimeError('Camera world not published')
        source=C.create_string_buffer(self.world);view=C.create_string_buffer(64)
        if self.inverse(view,None,source)!=C.addressof(view):raise RuntimeError('Reference camera inverse failed')
        self.dimensions=(lens.viewport_width,lens.viewport_height)
        self.projection=None;self.submissions=0;self.viewport_calls=0
        self.execute(0x407020,*(struct.unpack('<I',struct.pack('<f',v))[0] for v in (lens.fov_y,lens.near_z,lens.far_z)))
        if self.submissions!=1 or self.viewport_calls!=2:raise RuntimeError('Camera projection contract differs')
        combined=C.create_string_buffer(64);projection=C.create_string_buffer(self.projection)
        if self.multiply(combined,view,projection)!=C.addressof(combined):raise RuntimeError('Reference camera VP failed')
        return [self.world,view.raw[:64],self.projection,combined.raw[:64]]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--d3dx',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--vectors',type=Path,required=True)
    args=parser.parse_args();original=OriginalCamera(args.exe,args.d3dx);lib=library();rows=[];errors=[0]*4
    for index,(orbit,lens) in enumerate(cases()):
        expected=original.run(orbit,lens)
        other=original.run(orbit,lens,True)
        if expected!=other:raise RuntimeError('Original global and slot camera math differs')
        out=CameraMatrices();assert lib.dc_camera_build(C.byref(orbit),C.byref(lens),C.byref(out))==0
        for i,(name,reference) in enumerate(zip(('world','view','projection','view_projection'),expected)):
            for a,b in zip(getattr(out,name).values,struct.unpack('<16f',reference)):
                errors[i]=max(errors[i],abs(a-b))
                if abs(a-b)>5e-5*(1+abs(b)):raise RuntimeError(f'Camera differs case{index} {name}: {a} vs {b}')
        rows.append({'case':index,'matrix_hex':[v.hex() for v in expected]})
    report={'target_sha256':TARGET_SHA256,'cases':len(rows),'original_orbit_calls':len(rows)*2,
        'original_projection_calls':len(rows)*2,'vectors':rows,'max_absolute_error':dict(zip(
            ('world','view','projection','view_projection'),errors)),
        'original_function_sha256':original.hashes,'host_d3dx43_sha256':hashlib.sha256(args.d3dx.read_bytes()).hexdigest(),
        'execution':'isolated original orbit/projection drivers; host D3DX43 math and synthetic device boundaries',
        'coverage':'self-authored affine bases, orbit parameters and lenses; no preset loading, tracking, collision, game scene or GPU',
        'original_game_resources_used':False,'game_playability':'not verified'}
    for p in (args.output,args.vectors):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('vectors','original_function_sha256')}))


if __name__=='__main__':main()
