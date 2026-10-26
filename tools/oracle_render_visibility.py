"""Isolated original recursive render hide and transform traversal.

Runs FUN_00412450 and FUN_00415620 on a self-authored two-node tree. Matrix
multiply and the unused no-billboard camera inverse are synthetic math
boundaries. Observes render-list admission and cached matrices, not a GPU,
model loader, original resource or complete game.
"""
import argparse
import json
from pathlib import Path
import struct
from unicorn import UC_PROT_READ,UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ECX,UC_X86_REG_EIP,UC_X86_REG_ESP
from oracle_animation import OriginalAnimation,OBJECT,TARGET_SHA256
from native_core import library
from render_visibility_cases import cases,native_result

NODES=0x20020000
WORLD=OBJECT+0x1000
IDENTITY=[1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.]
class OriginalVisibility(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,{0x412450:101,0x415620:818})
        self.uc.mem_map(NODES,4096,UC_PROT_READ|UC_PROT_WRITE)
    def put(self,address,values):self.uc.mem_write(address,struct.pack('<'+'f'*len(values),*values))
    def floats(self,address):return list(struct.unpack('<16f',bytes(self.uc.mem_read(address,64))))
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        index,offset=divmod(address-NODES,0x210)
        if 0<=index<2 and ((offset==0x1f0 and size==1) or (offset in (0x1e8,0x1ec) and size==4) or 0x54<=offset and offset+size<=0x94):return
        if (address,size) in ((OBJECT+0x2608,4),(OBJECT+0x260c,4)):return
        raise RuntimeError(f'Unadmitted visibility write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp);pop=0
        if ret not in self.instructions:raise RuntimeError('Unadmitted visibility return')
        if address==0x4211e0:uc.reg_write(UC_X86_REG_EAX,uc.reg_read(UC_X86_REG_ECX))
        elif address==0x406fc0:
            out=self.word(sp+4);assert 0x10000000<=out<0x10010000-64
            self.put(out,IDENTITY)
        elif address==0x60abe0:
            dst,a,b=[self.word(sp+i) for i in (4,8,12)];a=self.floats(a);b=self.floats(b)
            values=[sum(a[r*4+k]*b[k*4+c] for k in range(4)) for r in range(4) for c in range(4)]
            self.put(dst,values);uc.reg_write(UC_X86_REG_EAX,dst);pop=12
        else:raise RuntimeError(f'Unadmitted visibility helper {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4+pop);uc.reg_write(UC_X86_REG_EIP,ret)
    def run(self,case):
        self.uc.mem_write(OBJECT,bytes(0x10000));self.uc.mem_write(NODES,bytes(0x420))
        self.uc.mem_write(NODES+8,struct.pack('<2I',1,NODES+0x210))
        for i in range(2):
            node=NODES+i*0x210;self.put(node+0x14,IDENTITY);self.put(node+0x54,IDENTITY)
            self.uc.mem_write(node+0x1f8,bytes([case['freeze'][i]]))
        self.uc.mem_write(NODES+0x210+0x168,struct.pack('<I',1))
        self.put(WORLD,case['world']);self.put(OBJECT+0xe3c8,[1,0]);rows=[]
        for node,hidden in case['operations']:
            self.execute(0x412450,NODES+node*0x210,hidden)
            assert [self.uc.mem_read(NODES+i*0x210+0x1f8,1)[0] for i in range(2)]==case['freeze']
            self.uc.mem_write(OBJECT+0x2608,bytes(8));self.execute(0x415620,OBJECT,OBJECT,NODES,WORLD)
            count=self.word(OBJECT+0x2608);assert count in (0,1)
            if count:assert self.word(OBJECT+0x260c)==NODES+0x210
            rows.append({'visible':count,'child_world':self.floats(NODES+0x210+0x54)})
        return rows
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--vectors',type=Path,required=True);a=p.parse_args()
    original=OriginalVisibility(a.exe);lib=library();rows=[]
    for case in cases():
        expected=original.run(case);actual=native_result(lib,case)
        for x,y in zip(expected,actual):
            assert x['visible']==y['visible'],(case,x,y)
            assert all(abs(a-b)<1e-5*(1+abs(a)) for a,b in zip(x['child_world'],y['child_world'])),(case,x,y)
        rows.append({'input':case,'result':expected})
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':original.hashes,'cases':len(rows),
            'operations':sum(len(v['result']) for v in rows),'boundaries':__doc__,'game_playability':'not verified','vectors':rows}
    for path in (a.output,a.vectors):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='vectors'}))
if __name__=='__main__':main()
