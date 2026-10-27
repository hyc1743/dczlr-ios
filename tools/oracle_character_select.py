"""Execute original initial type4 character selection on synthetic contexts.

Model configuration and sound starts are recorded helper boundaries. Alternate
node bindings are null, selecting the initial hidden-alternate branch. No
resource, audio decoder, frame update, renderer or game process executes.
"""
import sys,struct,json,ctypes as C,argparse
from pathlib import Path

from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ESP,UC_X86_REG_EIP
from native_core import library,SceneCharacterState,SceneCharacterEvent
MAIN,MODEL=0x21000000,0x22000000
class Original(OriginalAnimation):
 def __init__(self,path):
  super().__init__(path,{0x5358c0:0x536f25-0x5358c0})
  self.uc.mem_map(MAIN,0x23000,UC_PROT_READ|UC_PROT_WRITE);self.uc.mem_map(MODEL,0x10000,UC_PROT_READ|UC_PROT_WRITE)
 def write_guard(self,uc,access,address,size,value,context):
  if 0x10000000<=address and address+size<=0x10010000:return
  if (address,size) in ((OBJECT+0x185e,2),(OBJECT+0x185c,1),(OBJECT+0x1864,4),(OBJECT+0x185d,1)):return
  raise RuntimeError((hex(address),size))
 def code_guard(self,uc,address,size,context):
  if address in self.instructions:return
  sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp)
  if ret not in self.instructions:raise RuntimeError('unexpected return')
  if address==0x517a40:uc.reg_write(UC_X86_REG_EAX,OBJECT)
  elif address in (0x404630,0x404680):
   assert self.word(sp+4)==MODEL
   self.calls.append([hex(address),self.word(sp+8),self.word(sp+12)])
  elif address==0x4024b0:
   assert [self.word(sp+4),self.word(sp+8)]==[0x12340000,0]
   self.calls.append(['sound',28])
  else:raise RuntimeError('unexpected helper '+hex(address))
  uc.reg_write(UC_X86_REG_ESP,sp+4);uc.reg_write(UC_X86_REG_EIP,ret)
 def run(self,option,stage,clip,counter):
  self.calls=[];self.uc.mem_write(OBJECT,bytes(0x11000));self.uc.mem_write(MAIN,bytes(0x23000))
  self.uc.mem_write(MAIN+0x1352d,b'\x04');self.uc.mem_write(OBJECT+0x184d,bytes([stage]));self.uc.mem_write(OBJECT+0x185e,struct.pack('<H',counter))
  for offset,value in ((0xc94,option),(0x1020,MODEL),(0x10dc,0x12340000)):self.uc.mem_write(OBJECT+offset,struct.pack('<I',value))
  self.uc.mem_write(MODEL+0xe350,struct.pack('<I',clip));self.execute(0x5358c0,MAIN,OBJECT,0)
  return {'count':struct.unpack('<H',bytes(self.uc.mem_read(OBJECT+0x185e,2)))[0], 'delay':self.uc.mem_read(OBJECT+0x185c,1)[0], 'exit':self.uc.mem_read(OBJECT+0x185d,1)[0], 'calls':self.calls}
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--exe',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
 original=Original(args.exe);lib=library();rows=[]
 for option in (0,1):
  for stage in range(3):
   for clip in (1,11,13):
    for counter in (0,9999,10000):
     expected=original.run(option,stage,clip,counter);s=SceneCharacterState(counter,0,0,0,0,0);e=SceneCharacterEvent()
     assert lib.dc_scene_character_select(C.byref(s),4,0,option,C.byref(e))==0
     assert expected['count']==s.activation_count and expected['delay']==s.delay_pending and expected['exit']==s.exit_pending
     assert expected['calls']==([['0x404630',6,7],['0x404680',5,1]] if option==0 else [['sound',28]])
     rows.append({'option':option,'stage':stage,'clip':clip,'counter':counter,'observed':expected})
 report={'sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),'scope':'initial type4 progress0 with both alternate-node bindings null; model config and audio stub boundaries; no graphics or full gameplay','vectors':rows}
 args.output.parent.mkdir(parents=True,exist_ok=True)
 args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
