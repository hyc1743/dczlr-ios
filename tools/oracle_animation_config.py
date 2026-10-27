"""Execute original 00404630/00404680 configuration leaves on synthetic records.

No game process, assets, graphics or operating-system helpers execute.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import struct
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library,AnimationClip,AnimationTiming

class OriginalConfig(OriginalAnimation):
    def __init__(self,path):super().__init__(path,{0x404630:74,0x404680:64})
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if (address,size) in ((OBJECT+0x348+0x50,1),(OBJECT+0x348+0x52,1),
                             (OBJECT+0x348+0x53,1),(OBJECT+0x348+0x54,4)):return
        raise RuntimeError(f'Unadmitted configuration write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address not in self.instructions:raise RuntimeError(f'Unexpected helper {address:#x}')
    def run(self,operation,value):
        self.uc.mem_write(OBJECT+0x348,bytes([0xa5])*112)
        self.execute(0x404630 if operation=='chain' else 0x404680,OBJECT,0,value&0xffffffff)
        b=bytes(self.uc.mem_read(OBJECT+0x348+0x50,8))
        return [b[0],b[2],b[3],struct.unpack_from('<I',b,4)[0]]

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    original=OriginalConfig(a.exe);lib=library();rows=[]
    for op in ('chain','loop'):
        for value in (-2147483648,-2,-1,0,1,7,255,256,257,511):
            if op=='chain' and value>511:continue
            clips=(AnimationClip*512)();timing=(AnimationTiming*512)()
            clips[0].loop=timing[0].loop_limit=timing[0].chain=0xa5;timing[0].next_clip=0xa5a5a5a5
            status=lib.dc_animation_set_chain(timing,512,0,value) if op=='chain' else lib.dc_animation_set_loop(clips,timing,512,0,value)
            assert status==0
            actual=[clips[0].loop,timing[0].loop_limit,timing[0].chain,timing[0].next_clip]
            expected=original.run(op,value);assert actual==expected,(op,value,actual,expected)
            rows.append({'operation':op,'value':value,'expected':expected})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),
        'coverage':'synthetic configuration bytes; no animation tick, asset or scene execution','vectors':rows}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
