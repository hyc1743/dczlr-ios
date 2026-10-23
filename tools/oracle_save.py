"""Isolate the original word-XOR save codec on synthetic records."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library
from save_cases import cases


class OriginalSave(OriginalAnimation):
    def __init__(self,exe):super().__init__(exe,{0x45dc10:83})
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if OBJECT<=address and address+size<=OBJECT+self.length and size==4 and (address-OBJECT)%4==0:return
        raise RuntimeError('Save codec wrote outside complete synthetic words')
    def code_guard(self,uc,address,size,context):
        if address not in self.instructions:raise RuntimeError('Save codec left admitted function')
    def run(self,data):
        self.length=len(data);self.uc.mem_write(OBJECT,data+b'\xa5'*8)
        # Whole save record has thousands of word iterations.
        self.execute_bounded(data)
        if bytes(self.uc.mem_read(OBJECT+len(data),8))!=b'\xa5'*8:raise RuntimeError('Save canary changed')
        return bytes(self.uc.mem_read(OBJECT,len(data)))
    def execute_bounded(self,data):
        from oracle_animation import STACK,STOP
        from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EBP,UC_X86_REG_EIP
        import struct
        self.uc.mem_write(STACK,struct.pack('<3I',STOP,OBJECT,len(data)))
        self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(0x45dc10,STOP,count=200000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=STOP or self.uc.reg_read(UC_X86_REG_ESP)!=STACK+4:raise RuntimeError('Save codec did not return within bound')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--vectors',type=Path,required=True)
    args=parser.parse_args();original=OriginalSave(args.exe);lib=library();digest=hashlib.sha256();count=0
    for data in cases():
        expected=original.run(data);out=C.create_string_buffer(data,len(data)+1)
        assert lib.dc_save_transform(out,len(data))==0
        if out.raw[:len(data)]!=expected:raise ValueError('Save codec output differs')
        digest.update(len(data).to_bytes(4,'little')+expected);count+=1
    report={'target_sha256':TARGET_SHA256,'cases':count,'output_sha256':digest.hexdigest(),'original_function_sha256':original.hashes,
            'execution':'isolated original complete-word XOR codec; self-authored buffers and canaries',
            'original_game_resources_used':False,'full_save_restore_or_write':'not implemented','game_playability':'not verified'}
    for p in (args.output,args.vectors):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'cases':count,'matched':True,'output_sha256':digest.hexdigest()}))

if __name__=='__main__':main()
