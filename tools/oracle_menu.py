"""Isolate original pointer menu update and scaled rectangle hit function."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn.x86_const import UC_X86_REG_EAX
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library,MenuState,MenuButton
from menu_cases import cases,native_result


class OriginalMenu(OriginalAnimation):
    def __init__(self,exe):super().__init__(exe,{0x45f7c0:423,0x45f600:112})

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        offset=address-OBJECT
        if (offset==0x508 and size==1) or (size==4 and (offset in (0x500,0x504) or
            0x590<=offset<0x610 and offset%4==0 or 0x690<=offset<0x710 and offset%4==0)):return
        raise RuntimeError(f'Menu write outside admitted fields: {address:#x}/{size}')

    def code_guard(self,uc,address,size,context):
        if address not in self.instructions:raise RuntimeError('Menu left admitted functions')

    def run(self,case):
        s=case['state'];self.uc.mem_write(OBJECT,b'\0'*0x10000)
        self.uc.mem_write(OBJECT+0x500,struct.pack('<2i',s['selected'],s['hover']))
        self.uc.mem_write(OBJECT+0x508,bytes([s['active']]))
        self.uc.mem_write(OBJECT+0x50c,struct.pack('<I',len(case['buttons'])))
        self.uc.mem_write(OBJECT+0x590,struct.pack('<32I',*s['pressed']))
        self.uc.mem_write(OBJECT+0x690,struct.pack('<32I',*s['toggled']))
        for i,b in enumerate(case['buttons']):
            for name,offset in (('x',0x200),('y',0x280),('width',0x400),('height',0x480)):
                self.uc.mem_write(OBJECT+offset+i*4,struct.pack('<f',b[name]))
            for name,offset in (('disabled',0x710),('press_activate',0x510),('toggle',0x610)):
                self.uc.mem_write(OBJECT+offset+i*4,struct.pack('<I',b[name]))
        scale=struct.unpack('<I',struct.pack('<f',case['scale']))[0]
        self.execute(0x45f7c0,OBJECT,case['x']&0xffffffff,case['y']&0xffffffff,scale,case['input_code'])
        output={'selected':C.c_int32(self.word(OBJECT+0x500)).value,'hover':C.c_int32(self.word(OBJECT+0x504)).value,
                'active':bytes(self.uc.mem_read(OBJECT+0x508,1))[0],
                'pressed':list(struct.unpack('<32I',bytes(self.uc.mem_read(OBJECT+0x590,128)))),
                'toggled':list(struct.unpack('<32I',bytes(self.uc.mem_read(OBJECT+0x690,128))))}
        return {'state':output,'result':C.c_int32(self.uc.reg_read(UC_X86_REG_EAX)).value}




def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--vectors',type=Path,required=True);args=parser.parse_args()
    original,lib=OriginalMenu(args.exe),library();digest=hashlib.sha256();count=0
    for case in cases():
        expected=original.run(case);actual=native_result(lib,case)
        if expected!=actual:raise ValueError(f'Menu comparison failed at {count}')
        digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
    report={'target_sha256':TARGET_SHA256,'cases':count,'output_sha256':digest.hexdigest(),'original_function_sha256':original.hashes,
            'execution':'isolated original menu update and scaled hit tests; self-authored finite layouts and states',
            'coverage':'first-hit, inclusive bounds, scale rounding, disabled/sentinel rows, hover/selection, press and toggle flags; no UI or OS input',
            'original_game_resources_used':False,'game_playability':'not verified'}
    for p in (args.output,args.vectors):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':count,'matched':True,'output_sha256':digest.hexdigest()}))

if __name__=='__main__':main()
