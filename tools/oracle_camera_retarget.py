"""Compare original retarget instruction bodies, with explicit Python math stubs.

Matrices, vector angles, sqrt/abs, controller build and CRT memcpy are synthetic
math boundaries. No model, camera resource, scene or GPU executes. This is not
a gameplay or complete camera-controller equivalence test.
"""
import argparse
import ctypes as C
import json
import math
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE,UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EBP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_ECX
from oracle_animation import OriginalAnimation,OBJECT,STACK,STOP,TARGET_SHA256
from native_core import library,Matrix,CameraOrbit
from scene_cases import matrix

PRIMARY=0x7c82a8
SECONDARY=OBJECT
TARGET=OBJECT+0x4000
VECTOR=OBJECT+0x8000
HARNESS=0x30001000
def f32(v):return struct.unpack('<f',struct.pack('<f',v))[0]
def identity():return [1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.]
def multiply(a,b):return [f32(sum(a[r*4+k]*b[k*4+c] for k in range(4))) for r in range(4) for c in range(4)]
def world(base,values):
    distance,height,pitch,yaw=values
    x=identity();x[5]=x[10]=f32(math.cos(pitch));x[6]=f32(math.sin(pitch));x[9]=-x[6]
    y=identity();y[0]=y[10]=f32(math.cos(yaw));y[8]=f32(math.sin(yaw));y[2]=-y[8]
    tz=identity();tz[14]=-distance;ty=identity();ty[13]=height
    return multiply(multiply(multiply(tz,multiply(x,y)),ty),base)

class OriginalRetarget(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,{0x581380:0x581aed-0x581380,0x581af0:0x582183-0x581af0})
        self.uc.mem_protect(0x7c8000,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_map(HARNESS,4096,UC_PROT_READ|UC_PROT_WRITE|UC_PROT_EXEC)
        # Return one synthetic math result through ST0, preserving cdecl args.
        self.uc.mem_write(HARNESS+32,b'\xdd\x05'+struct.pack('<I',HARNESS+128)+b'\xc3')
        for offset,target in ((0,0x581af0),(16,0x581380)):
            self.uc.mem_write(HARNESS+offset,b'\xdb\xe3\xe9'+struct.pack('<i',target-(HARNESS+offset+7)))
    def floats(self,address,count):return list(struct.unpack('<'+'f'*count,bytes(self.uc.mem_read(address,count*4))))
    def put(self,address,values):self.uc.mem_write(address,struct.pack('<'+'f'*len(values),*values))
    def write_guard(self,uc,access,address,size,value,context):
        if PRIMARY<=address<PRIMARY+0x148:self.state_writes.append([hex(address-PRIMARY),size,value])
        if any(start<=address and address+size<=start+length for start,length in ((OBJECT,0x11000),(PRIMARY,0x148),(0x10000000,0x10000))):return
        raise RuntimeError(f'Unadmitted retarget write {address:#x}/{size}')
    def math_return(self,value):
        self.uc.mem_write(HARNESS+128,struct.pack('<d',value));self.uc.reg_write(UC_X86_REG_EIP,HARNESS+32)
    def code_guard(self,uc,address,size,context):
        if address in self.instructions or address in (HARNESS,HARNESS+2,HARNESS+16,HARNESS+18,HARNESS+32,HARNESS+38):return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp)
        pop=0
        if ret not in self.instructions:raise RuntimeError('Unexpected retarget math return')
        args=lambda count:[self.word(sp+4+i*4) for i in range(count)]
        if address==0x4211e0:uc.reg_write(UC_X86_REG_EAX,uc.reg_read(UC_X86_REG_ECX))
        elif address==0x61dfb0:
            dst,src,count=args(3);assert count==64
            self.uc.mem_write(dst,bytes(self.uc.mem_read(src,count)));uc.reg_write(UC_X86_REG_EAX,dst)
        elif address in (0x416cb0,0x470ba0):
            v=self.floats(sp+4,1)[0];self.math_return(math.sqrt(v) if address==0x416cb0 else abs(v));return
        elif address==0x407300:
            self.put(VECTOR,self.floats(sp+4,3));uc.reg_write(UC_X86_REG_EAX,VECTOR);pop=12
        elif address in (0x418970,0x418a10):
            dst,src=args(2);m=self.floats(src,16);v=self.floats(sp+12,3)
            p=[f32(m[12+i]+sum(v[j]*m[j*4+i] for j in range(3))) for i in range(3)]
            self.put(dst+48,p)
        elif address==0x418770:
            dst,center,axis,angle=args(4);assert dst==center and self.floats(axis,3)==[0,1,0]
            angle=self.floats(sp+16,1)[0];rotation=identity();rotation[0]=rotation[10]=f32(math.cos(angle));rotation[8]=f32(math.sin(angle));rotation[2]=-rotation[8]
            m=self.floats(dst,16);pos=m[12:15];m[12:15]=[0,0,0];m=multiply(m,rotation);m[12:15]=pos;self.put(dst,m)
        elif address==0x4446a0:
            a,origin,b=[self.floats(p,3) for p in args(3)]
            u=[f32(x-y) for x,y in zip(a,origin)];v=[f32(x-y) for x,y in zip(b,origin)]
            ul=f32(math.sqrt(sum(x*x for x in u)));vl=math.sqrt(sum(x*x for x in v));denom=f32(ul*vl)
            angle=0 if denom==0 else math.degrees(math.acos(max(-1,min(1,f32(sum(x*y for x,y in zip(u,v))/denom)))))
            self.angle_calls.append([a,origin,b,angle])
            self.math_return(angle);return
        elif address==0x4656c0:
            assert args(1)==[PRIMARY];base=self.floats(PRIMARY+8,16);values=self.floats(PRIMARY+0x108,4)
            self.put(PRIMARY+0xc8,world(base,values))
        elif address==0x466ce0:
            assert args(1)==[PRIMARY+0xc8];p=self.floats(PRIMARY+0xf8,3);p[1]-=self.floats(PRIMARY+0x10c,1)[0]
            self.put(PRIMARY+0xf8,p);self.put(PRIMARY+0x38,p)
        else:raise RuntimeError(f'Unadmitted retarget math {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4+pop);uc.reg_write(UC_X86_REG_EIP,ret)
    def run(self,orbit,target,primary):
        self.angle_calls=[];self.state_writes=[]
        obj=PRIMARY if primary else SECONDARY;base=8 if primary else 0x80;scalars=0x108 if primary else 0x100;w=0xc8 if primary else 0xc0
        self.uc.mem_write(obj,bytes(0x148));self.put(obj+base,list(orbit.base.values))
        self.put(obj+scalars,[orbit.stored_distance,orbit.height,orbit.pitch,orbit.yaw]);self.put(obj+w,world(list(orbit.base.values),self.floats(obj+scalars,4)))
        self.uc.mem_write(TARGET,bytes(target));entry=HARNESS+16 if primary else HARNESS
        self.uc.mem_write(STACK,struct.pack('<3I',STOP,obj,TARGET));self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(entry,STOP,count=10000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=STOP or self.uc.reg_read(UC_X86_REG_ESP)!=STACK+4:raise RuntimeError('Retarget did not return')
        return self.floats(obj+base,16)+self.floats(obj+scalars,4)

def cases():
    for rotation in (0,.4):
        for height in (0,3):
            for distance in (-20,-60):
                for pitch in (-.3,.2):
                    for target in ((0,2,0),(8,4,-2),(-10,8,4),(2,-3,-9)):
                        for primary in (0,1):
                            yield CameraOrbit(matrix(rotation,1,(2,1,-3)),distance,height,pitch,.5),matrix(translation=target),primary

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);a=p.parse_args()
    original=OriginalRetarget(a.exe);lib=library();rows=[];max_error=0
    for i,(source,target,primary) in enumerate(cases()):
        expected=original.run(source,target,primary);out=CameraOrbit()
        assert lib.dc_camera_retarget(C.byref(source),C.byref(target),primary,C.byref(out))==0
        actual=list(out.base.values)+[out.stored_distance,out.height,out.pitch,out.yaw]
        for x,y in zip(actual,expected):
            max_error=max(max_error,abs(x-y))
            if abs(x-y)>2e-4*(1+abs(y)):raise RuntimeError((i,primary,x,y,actual,expected))
        rows.append({'case':i,'result':expected})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),'max_absolute_error':max_error,
            'boundaries':__doc__,'game_playability':'not verified','vectors':rows}
    for path in (a.output,a.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
