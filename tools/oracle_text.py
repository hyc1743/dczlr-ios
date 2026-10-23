"""Isolate normal original text layout/fade and forward-input state functions.

Actual original x87-to-integer helper executes. Font draw, clock, strings and
next-record parser are synthetic boundaries. No GDI/device/game process runs.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP,UC_X86_REG_EIP,UC_X86_REG_EAX,UC_X86_REG_FPCW,UC_X86_REG_EBP
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library
from text_cases import tick_cases,advance_cases,native_tick,native_advance

BODY,LINES=OBJECT+0x2000,OBJECT+0x4000
ALPHA,FADE,STAMP=0x84d1d0,0x84d4f0,0x84dc18
FIELDS={'columns':0x170,'max_lines':0x14d,'visible_lines':0x174,'body_bytes':0x17c,
        'current_line':0x14c,'wait_state':0x154,'wait_glyph':0x1a0,'frame':0x15c,'last_frame':0x164,
        'last_fade_row':0x14f,'wait_line':0x14e,'wait_duration':0x19c,'active':0x1b4,
        'x':0x180,'y':0x188,'font_size':0x198,'scale':0x1ac}
SIGNED={'current_line','wait_state','wait_glyph','frame','last_frame','x','y','font_size'}
BYTES={'current_line','max_lines','last_fade_row','wait_line'}
STUBS={0x4223b0:'clock',0x61dcd0:'memset',0x61e400:'strcmp',0x61dd61:'cookie',0x58e4a0:'draw',
       0x592590:'parse',0x61dd70:'copy'}


class OriginalText(OriginalAnimation):
    def __init__(self,exe):
        super().__init__(exe,{0x58eb30:5040,0x61e344:117,0x591310:0x591ce6-0x591310})
        for page in (0x84d000,0x768000):self.uc.mem_protect(page,4096,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_write(0x84d1c8,struct.pack('<I',OBJECT))
        self.uc.reg_write(UC_X86_REG_FPCW,0x37f)

    def execute(self,address,*arguments):
        self.uc.mem_write(0x10008000,struct.pack('<'+'I'*(len(arguments)+1),0x30000000,*arguments))
        self.uc.reg_write(UC_X86_REG_ESP,0x10008000);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(address,0x30000000,count=300000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=0x30000000 or self.uc.reg_read(UC_X86_REG_ESP)!=0x10008004:
            raise RuntimeError('Original text function did not return within bounded instructions')

    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if OBJECT<=address and address+size<=OBJECT+0xc00:return
        if BODY<=address and address+size<=BODY+400:return
        if LINES<=address and address+size<=LINES+20:return
        if ALPHA<=address and address+size<=FADE+4:return
        if address==STAMP and size==4:return
        if address==0x84d4f4 and size==1:return
        raise RuntimeError(f'Text wrote outside admitted state: {address:#x}/{size}')

    def string(self,at,limit=512):
        data=bytes(self.uc.mem_read(at,limit));end=data.find(b'\0')
        if end<0:raise RuntimeError('Unterminated synthetic string')
        return data[:end]

    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        if address not in STUBS:raise RuntimeError(f'Text left admitted functions: {address:#x}')
        stack=uc.reg_read(UC_X86_REG_ESP);target=self.word(stack)
        if target not in self.instructions:raise RuntimeError('Unadmitted host return')
        arg=lambda i:self.word(stack+4*i);kind=STUBS[address];eax=0
        if kind=='clock':eax=self.clock
        elif kind=='draw':
            self.draws.append([C.c_int32(arg(1)).value,C.c_int32(arg(2)).value,self.string(arg(3)).hex(),arg(4)])
        elif kind=='memset':
            at,value,n=arg(1),arg(2),arg(3)
            if n>4096:raise RuntimeError('Oversized memset')
            self.write_guard(uc,0,at,n,0,None);uc.mem_write(at,bytes([value&255])*n)
        elif kind=='strcmp':
            a,b=self.string(arg(1)),self.string(arg(2));eax=(a>b)-(a<b)
        elif kind=='parse':
            if arg(1)!=OBJECT:raise RuntimeError('Unexpected parser context')
            self.load_record+=1
        elif kind=='copy':
            if (arg(1),arg(2))!=(OBJECT+0x2c,OBJECT+0xc):raise RuntimeError('Unexpected speaker copy')
            uc.mem_write(arg(1),self.string(arg(2))+b'\0')
        uc.reg_write(UC_X86_REG_EAX,eax&0xffffffff);uc.reg_write(UC_X86_REG_ESP,stack+4);uc.reg_write(UC_X86_REG_EIP,target)

    def install(self,case):
        s=case['state'];self.draws=[];self.load_record=0;self.clock=case.get('clock',0)
        self.uc.mem_write(OBJECT,bytes(0x10000))
        self.uc.mem_write(OBJECT+4,struct.pack('<2I',BODY,400));self.uc.mem_write(OBJECT+0x158,struct.pack('<I',LINES))
        self.uc.mem_write(OBJECT+0x1a4,struct.pack('<I',case.get('style',0)))
        for n,at in FIELDS.items():
            value=s[n];fmt='f' if n=='scale' else 'b' if n=='current_line' else 'B' if n in BYTES else 'i' if n in SIGNED else 'I'
            self.uc.mem_write(OBJECT+at,struct.pack('<'+fmt,value))
        self.uc.mem_write(ALPHA,struct.pack('<200I',*s['alpha']));self.uc.mem_write(FADE,struct.pack('<I',s['fade_index']))
        self.uc.mem_write(LINES,struct.pack('<5I',*s['line_lengths']));self.uc.mem_write(STAMP,struct.pack('<I',s['wait_stamp']))
        self.uc.mem_write(0x84d1b8,bytes([case['fast']]));self.uc.mem_write(0x84d4f4,b'\0')
        self.uc.mem_write(0x768df0,struct.pack('<3I',s['rgb']>>16,(s['rgb']>>8)&255,s['rgb']&255))
        body=bytes.fromhex(case.get('body','414243440d0a'));self.uc.mem_write(BODY,body+b'\0'*400)

    def result(self,case):
        s=dict(case['state'])
        for n,at in FIELDS.items():
            fmt='f' if n=='scale' else 'b' if n=='current_line' else 'B' if n in BYTES else 'i' if n in SIGNED else 'I'
            s[n]=struct.unpack('<'+fmt,self.uc.mem_read(OBJECT+at,struct.calcsize(fmt)))[0]
        s['alpha']=list(struct.unpack('<200I',self.uc.mem_read(ALPHA,800)))
        s['fade_index']=self.word(FADE);s['wait_stamp']=self.word(STAMP)
        s['line_lengths']=list(struct.unpack('<5I',self.uc.mem_read(LINES,20)))
        return s

    def tick(self,case):
        self.install(case);self.execute(0x58eb30,case['delta']&0xffffffff)
        return {'state':self.result(case),'draws':self.draws}

    def advance(self,case):
        self.install(case);self.execute(0x591310,0,0)
        if self.load_record>1:raise RuntimeError('Repeated parser operation')
        s=self.result(case)
        return {'state':s,'load_record':self.load_record,'finished':int(not s['active'])}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);args=p.parse_args()
    original=OriginalText(args.exe);lib=library();results={}
    for name,source,reference,native in (('tick',tick_cases,original.tick,native_tick),('advance',advance_cases,original.advance,native_advance)):
        digest=hashlib.sha256();count=0
        for case in source():
            expected=reference(case);actual=native(lib,case)
            if expected!=actual:
                differences={k:[expected[k],actual[k]] for k in expected if expected[k]!=actual[k]}
                raise ValueError(f'{name} mismatch at {count}, case={case}, differences={differences}')
            digest.update((json.dumps({**case,'output':expected},sort_keys=True,separators=(',',':'))+'\n').encode());count+=1
        results[name]={'cases':count,'output_sha256':digest.hexdigest()}
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'results':results,
        'coverage':'normal byte-pair layout/fade and forward input; actual original x87 truncation; font draw/clock/CRT/parser synthetic',
        'original_game_resources_used':False,'game_playability':'not verified','excluded':'texture mode/backlog, rasterized font and other scene logic'}
    for path in (args.output,args.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(results))


if __name__=='__main__':main()
