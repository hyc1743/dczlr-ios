"""Original new-game numeric initialization; bounded synthetic memset only."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_EBP
from oracle_animation import OriginalAnimation,OBJECT,STACK,STOP,TARGET_SHA256
from native_core import library

BEGIN=OBJECT+0x13538
LENGTH=0xea38


class OriginalGameState(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,{0x50d920:803})
        self.uc.mem_map(OBJECT+0x11000,0x1f000,UC_PROT_READ|UC_PROT_WRITE)
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if BEGIN<=address and address+size<=BEGIN+LENGTH:return
        raise RuntimeError('New-game initialization wrote outside state regions')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address!=0x61dcd0:raise RuntimeError('New-game initialization left admitted code')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        destination,value,length=(self.word(stack+i) for i in (4,8,12))
        if target not in self.instructions or value or (destination,length) not in (
            (BEGIN,0x64c8),(OBJECT+0x19a00,0x6414),(OBJECT+0x1fe14,0x215c)):
            raise RuntimeError('Unadmitted initialization memset')
        uc.mem_write(destination,b'\0'*length);uc.reg_write(UC_X86_REG_EAX,destination)
        uc.reg_write(UC_X86_REG_ESP,stack+4);uc.reg_write(UC_X86_REG_EIP,target)
    def run(self,pattern):
        self.uc.mem_write(OBJECT,bytes([pattern])*0x30000)
        self.uc.mem_write(STACK,struct.pack('<2I',STOP,OBJECT))
        self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(0x50d920,STOP,count=1000000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=STOP or self.uc.reg_read(UC_X86_REG_ESP)!=STACK+4:raise RuntimeError('Initialization did not return within bound')
        if bytes(self.uc.mem_read(BEGIN-8,8))+bytes(self.uc.mem_read(BEGIN+LENGTH,8))!=bytes([pattern])*16:
            raise RuntimeError('Initialization canary changed')
        return bytes(self.uc.mem_read(BEGIN,LENGTH))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--vectors',type=Path,required=True)
    args=parser.parse_args();original=OriginalGameState(args.exe);lib=library();digest=None
    for pattern in (0xa5,0x5a,0xff):
        expected=original.run(pattern);native=C.create_string_buffer(bytes([pattern])*(LENGTH+8),LENGTH+8)
        assert lib.dc_game_state_init(native,LENGTH)==0
        if native.raw[:LENGTH]!=expected:raise ValueError('New-game state differs from original')
        if native.raw[LENGTH:]!=bytes([pattern])*8:raise ValueError('Native state canary changed')
        output=hashlib.sha256(expected).hexdigest()
        if digest is not None and digest!=output:raise ValueError('State initialization depends on previous contents')
        digest=output
    report={'target_sha256':TARGET_SHA256,'state_bytes':LENGTH,'cases':3,'initial_patterns':[0xa5,0x5a,0xff],
            'output_sha256':digest,'original_function_sha256':original.hashes,
            'execution':'isolated new-game numeric initialization with exact synthetic memset boundaries',
            'original_game_resources_used':False,'actual_gameplay_or_save_file':'not verified'}
    for p in (args.output,args.vectors):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='original_function_sha256'}))

if __name__=='__main__':main()
