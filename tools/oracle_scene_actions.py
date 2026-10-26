"""Execute isolated original type-4 camera/system dispatch with synthetic contexts.

Camera math, reset, publishing, sound and cookie checking are observed/stubbed
boundaries. This checks dispatch and mode writes, not those helpers, destination
screens, camera rendering or complete gameplay. No resource payload is exported.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ECX,UC_X86_REG_ESP,UC_X86_REG_EIP
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library,SceneActionPlan

MAIN=0x21000000
CAMERA=OBJECT+0x10000
TARGETS=[OBJECT+0x4000,OBJECT+0x5000,OBJECT+0x6000]
RANGES={0x539dd0:0xa772-0x9dd0,0x53a7c0:0xad8f-0xa7c0}

class OriginalSceneActions(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,RANGES)
        self.uc.mem_map(MAIN,0x23000,UC_PROT_READ|UC_PROT_WRITE)
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        allowed=((OBJECT+0x184e,1),(OBJECT+0x184f,1),(OBJECT+0x1850,1),(OBJECT+0x1851,1),
                 (CAMERA+0x128,4),(OBJECT+0xef18+0x120,4))
        if (address,size) in allowed:return
        raise RuntimeError(f'Unadmitted scene dispatch write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp)
        if ret not in self.instructions:raise RuntimeError('Helper return is outside original dispatch')
        args=lambda count:[self.word(sp+4+i*4) for i in range(count)]
        if address==0x517a40:uc.reg_write(UC_X86_REG_EAX,OBJECT)
        elif address==0x4211e0:uc.reg_write(UC_X86_REG_EAX,uc.reg_read(UC_X86_REG_ECX))
        elif address in (0x581380,0x581af0):
            controller,target=args(2)
            assert controller==(CAMERA if address==0x581380 else OBJECT+0xef18)
            index=[p+0x54 for p in TARGETS].index(target)
            self.calls.append([1 if address==0x581380 else 3,index])
        elif address==0x465f30:
            fov,preset,*limits=args(6)
            assert fov==0x3e99999a and preset==OBJECT+0x173c+self.preset*0x54
            assert limits==[0x41a00000,0xc1f00000,0x42c80000,0x40a00000]
            self.calls.append([2,0])
        elif address==0x479490:
            controller,fov,preset,*tail=args(8)
            assert controller==OBJECT+0xef18 and fov==0x3e99999a
            assert preset==OBJECT+0x173c+self.preset*0x54
            assert tail[:4]==[0x41a00000,0xc1f00000,0x42c80000,0x40a00000] and tail[4]&255==0
            self.calls.append([4,0])
        elif address==0x4790d0:
            controller,slot=args(2);assert controller==OBJECT+0xef18 and slot&255==0;self.publishes+=1
        elif address==0x464a60:
            assert args(1)==[2];self.sounds+=1
        elif address==0x61dd61:pass
        else:raise RuntimeError(f'Unadmitted scene helper {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4);uc.reg_write(UC_X86_REG_EIP,ret)
    def run(self,icon,option,primary,secondary,stage,preset):
        self.calls=[];self.publishes=self.sounds=0;self.preset=preset
        self.uc.mem_write(OBJECT,bytes(0x11000));self.uc.mem_write(MAIN,bytes(0x23000))
        self.uc.mem_write(MAIN+0x1352d,b'\x04');self.uc.mem_write(MAIN+0x21ff8,struct.pack('<I',0x12345678))
        self.uc.mem_write(OBJECT+0x184d,bytes([stage,primary,secondary]))
        self.uc.mem_write(OBJECT+0x1838,bytes([preset]))
        self.uc.mem_write(OBJECT+0x9600,struct.pack('<I',CAMERA))
        self.uc.mem_write(OBJECT+0x1708+stage*12,struct.pack('<I',TARGETS[0]))
        self.uc.mem_write(OBJECT+0x187c+stage*4,struct.pack('<I',TARGETS[1]))
        self.uc.mem_write(OBJECT+0x1454,struct.pack('<I',TARGETS[2]))
        if icon==3:
            self.execute(0x539dd0,MAIN,option)
            assert self.publishes==(1 if option in (3,4) else 0)
            if option in (2,6):assert self.word(CAMERA+0x128)==0x12345678
            if option in (5,6):assert self.word(OBJECT+0xef18+0x120)==0x12345678
        else:
            self.uc.mem_write(OBJECT+0x504,struct.pack('<I',4));self.uc.mem_write(OBJECT+0xc94,struct.pack('<I',option))
            self.execute(0x53a7c0,MAIN,OBJECT,OBJECT+0xf104,0)
            assert self.sounds==1 and self.uc.mem_read(OBJECT+0x1851,1)==b'\x01'
            state=self.uc.mem_read(OBJECT+0x1850,1)[0]
            assert state in (3,4);self.calls.append([5 if state==4 else 6,0])
        return {'modes':list(self.uc.mem_read(OBJECT+0x184e,2)),'commands':self.calls}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);a=p.parse_args()
    original=OriginalSceneActions(a.exe);lib=library();rows=[]
    for icon in (3,4):
        for option in range(7 if icon==3 else 2):
            for primary in range(3):
                for secondary in range(3):
                    for stage in range(3):
                        for preset in range(3):
                            expected=original.run(icon,option,primary,secondary,stage,preset)
                            actual=SceneActionPlan();assert lib.dc_scene_action_build(4,icon,option,primary,secondary,C.byref(actual))==0
                            if actual.record()!=expected:raise RuntimeError((icon,option,primary,secondary,stage,preset,actual.record(),expected))
                            rows.append({'input':[4,icon,option,primary,secondary],'stage':stage,'preset':preset,'result':expected})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),
            'coverage':'type-4 camera/system dispatch, mode writes, helper order, target and active preset selection',
            'boundaries':'synthetic contexts; camera math/reset/publish, sound and cookie check stubbed; destination scenes not executed',
            'game_playability':'not verified','vectors':rows}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    a.vectors.parent.mkdir(parents=True,exist_ok=True);a.vectors.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
