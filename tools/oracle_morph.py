"""Isolated original morph arithmetic against self-authored vertex buffers.

No target process, game resources, graphics API, DLL, or network executes.
Original function instructions are hash-pinned; allocation/memcpy/identity and
COM vertex-buffer boundaries are synthetic, bounded memory-only operations.
"""
from pathlib import Path
import hashlib,json,struct,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from oracle_animation import OriginalAnimation,OBJECT,QUERY_OUT,STACK,STOP,TARGET_SHA256
from unicorn import UC_PROT_READ,UC_PROT_WRITE,UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_EAX,UC_X86_REG_ECX,UC_X86_REG_EIP,UC_X86_REG_ESP,UC_X86_REG_EBP

TRACK=OBJECT+0x1000;NODE=OBJECT+0x2000;MESH=OBJECT+0x2800;INDEX=OBJECT+0x3000
DEST=OBJECT+0x3100;SRC=OBJECT+0x3200;KEYS=OBJECT+0x4000;VECTORS=OBJECT+0x5000
VBO=OBJECT+0x6000;VTABLE=OBJECT+0x6100;VB=OBJECT+0x7000
HEAP=0x21000000;CALLER=0x30001000;LOCK=0x30002000;UNLOCK=LOCK+16
ENTRIES=[0x418fe0,0x419780,0x41cc20,0x41b770,0x41aa50,0x418c00]
LAYOUT={0x112:(32,12),0x111c:(48,28),0x412:(56,12),0x141c:(72,28)}
def u(value):return struct.pack('<I',value)
def f(value):return struct.pack('<f',value)
def ranges():
    out={}
    for start in ENTRIES:
        lines=(ROOT/f'out/original-mixed-morph/{start:08x}.asm').read_text().splitlines()
        last=int(lines[-1].split('\t')[0],16)
        assert lines[-1].endswith('\tRET')
        out[start]=last+1-start
    return out

class OriginalMorph(OriginalAnimation):
    def __init__(self,path):
        super().__init__(path,ranges())
        self.uc.mem_map(HEAP,0x10000,UC_PROT_READ|UC_PROT_WRITE)
        self.uc.mem_map(CALLER,0x2000,UC_PROT_READ|UC_PROT_WRITE)
        self.callers=set()
        for slot,entry in enumerate(ENTRIES):
            address=CALLER+slot*128
            code=b'\xdb\xe3\xd9\x2d'+u(QUERY_OUT+8)+b'\xe9'+struct.pack('<i',entry-(address+13))
            self.uc.mem_write(address,code);self.callers.update((address,address+2,address+8))
        self.uc.mem_protect(CALLER,0x2000,UC_PROT_READ|UC_PROT_EXEC)
        self.allocations={};self.heap_next=HEAP
    def allowed(self,address,size):
        return any(lo<=address and address+size<=hi for lo,hi in [(OBJECT,OBJECT+0x11000),(HEAP,HEAP+0x10000),(0x10000000,0x10010000)])
    def write_guard(self,uc,access,address,size,value,context):
        if 0x10000000<=address and address+size<=0x10010000:return
        if HEAP<=address and address+size<=HEAP+0x10000:return
        if VB<=address and address+size<=VB+4*self.stride:return
        if (address,size)==(MESH+0x28,4):return
        if OBJECT+0x234<=address and address+size<=OBJECT+0x283:return
        raise RuntimeError(f'Unadmitted original write {address:#x}/{size}')
    def code_guard(self,uc,address,size,context):
        if address in self.instructions or address in self.callers:return
        sp=uc.reg_read(UC_X86_REG_ESP);ret=self.word(sp);pop=0
        if ret not in self.instructions:raise RuntimeError(f'Unadmitted host return {ret:#x}')
        if address==0x4211e0:
            uc.reg_write(UC_X86_REG_EAX,uc.reg_read(UC_X86_REG_ECX))
        elif address==0x4233d0:
            size=self.word(sp+4);assert 0<size<=256
            result=self.heap_next;self.heap_next+=(size+15)&~15
            assert self.heap_next<=HEAP+0x10000
            self.allocations[result]=size;uc.mem_write(result,bytes(size));uc.reg_write(UC_X86_REG_EAX,result)
        elif address==0x423450:
            ptr=self.word(sp+4);assert ptr in self.allocations;del self.allocations[ptr]
        elif address==0x61dfb0:
            dest,source,size=[self.word(sp+i) for i in (4,8,12)]
            assert 0<=size<=256 and self.allowed(dest,size) and self.allowed(source,size)
            uc.mem_write(dest,bytes(uc.mem_read(source,size)));uc.reg_write(UC_X86_REG_EAX,dest)
        elif address==0x61dcd0:
            dest,value,size=[self.word(sp+i) for i in (4,8,12)]
            assert 0<=size<=256 and self.allowed(dest,size)
            uc.mem_write(dest,bytes([value&255])*size);uc.reg_write(UC_X86_REG_EAX,dest)
        elif address==LOCK:
            this,offset,length,out,flags=[self.word(sp+i) for i in (4,8,12,16,20)]
            assert (this,offset,length,flags)==(VBO,0,0,0) and 0x10000000<=out<0x10010000-4
            uc.mem_write(out,u(VB));uc.reg_write(UC_X86_REG_EAX,0);pop=20
        elif address==UNLOCK:
            assert self.word(sp+4)==VBO;uc.reg_write(UC_X86_REG_EAX,0);pop=4
        else:raise RuntimeError(f'Unadmitted helper {address:#x}')
        uc.reg_write(UC_X86_REG_ESP,sp+4+pop);uc.reg_write(UC_X86_REG_EIP,ret)
    def put(self,address,values):self.uc.mem_write(address,struct.pack('<'+'f'*len(values),*values))
    def call(self,entry,args,control):
        self.uc.mem_write(QUERY_OUT+8,struct.pack('<H',control))
        self.uc.mem_write(STACK,struct.pack('<'+'I'*(1+len(args)),STOP,*args))
        self.uc.reg_write(UC_X86_REG_ESP,STACK);self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(CALLER+ENTRIES.index(entry)*128,STOP,count=50000)
        if self.uc.reg_read(UC_X86_REG_EIP)!=STOP or self.uc.reg_read(UC_X86_REG_ESP)!=STACK+4:raise RuntimeError('Bounded morph call did not return')
        return self.uc.reg_read(UC_X86_REG_EAX)
    def prepare(self,case):
        self.stride,self.normal=LAYOUT[case['fvf']]
        self.allocations={};self.heap_next=HEAP
        self.uc.mem_write(OBJECT,bytes(0x10000));self.uc.mem_write(HEAP,bytes(0x10000))
        self.uc.mem_write(NODE+0x184,u(MESH));self.uc.mem_write(NODE+0x18c,u(case['fvf']))
        self.uc.mem_write(MESH+0x28,u(VBO));self.uc.mem_write(VBO,u(VTABLE));self.uc.mem_write(VTABLE+0x2c,u(LOCK)+u(UNLOCK))
        self.uc.mem_write(INDEX+8,b'\0');self.uc.mem_write(INDEX+0xc,struct.pack('<3I',2,DEST,SRC))
        self.uc.mem_write(DEST,struct.pack('<2H',2,0));self.uc.mem_write(SRC,struct.pack('<2H',1,2))
        self.uc.mem_write(TRACK+0xc,u(NODE));self.uc.mem_write(TRACK+0x10,u(case['type']))
        self.uc.mem_write(TRACK+0x1c,struct.pack('<3I',INDEX,6,KEYS))
        self.uc.mem_write(TRACK+0x28,f(case.get('frame',4.5)))
        for j,time in enumerate([0,9,10,19,20,29]):
            descriptor=VECTORS+j*0x100;positions=descriptor+0x20;normals=positions+36
            self.uc.mem_write(descriptor+0xc,u(positions)+u(normals))
            self.put(positions,[100*j+10*i+k for i in range(3) for k in [1,2,3]])
            self.put(normals,[1000+100*j+10*i+k for i in range(3) for k in [4,5,6]])
            self.uc.mem_write(KEYS+j*20,struct.pack('<IBB2xIII',time,0,0,0,0,descriptor))
        if case['type']==1 and case.get('weighted'):
            self.uc.mem_write(TRACK+0x30,struct.pack('<3I',VECTORS,VECTORS+0x100,VECTORS+0x200))
            self.put(TRACK+0x3c,[.25,.5])
        self.uc.mem_write(VB,b'\xa5'*(4*self.stride))
        # The reset changes bounds/mode only; synthetic controls are supplied separately.
        self.call(0x418c00,[OBJECT],case['control'])
        for group in [0x234,0x24c]:
            lane='mouth' if group==0x234 else 'eyes'
            self.uc.mem_write(OBJECT+group,struct.pack('<2i',case.get(lane+'_previous',0),case.get(lane+'_current',1)))
            self.put(OBJECT+group+0x10,[case.get('blend',.25)])
            self.uc.mem_write(OBJECT+group+0x14,bytes([case.get('blend_state',0)]))
        self.put(OBJECT+0x264,case.get('phases',[case.get('phase',4.5)]*3))
        self.inputs={KEYS:bytes(self.uc.mem_read(KEYS,120)),DEST:bytes(self.uc.mem_read(DEST,4)),SRC:bytes(self.uc.mem_read(SRC,4)),VECTORS:bytes(self.uc.mem_read(VECTORS,0x600))}
    def run(self,case):
        self.prepare(case)
        typ=case['type']
        if typ==0:entry,args=0x418fe0,[TRACK,struct.unpack('<I',f(case['frame']))[0]]
        elif typ==1:entry,args=(0x41cc20 if case.get('weighted') else 0x419780),[TRACK]
        elif typ in [3,4]:entry,args=0x41b770,[OBJECT,TRACK]
        elif typ==5:entry,args=0x41aa50,[OBJECT,TRACK]
        result=self.call(entry,args,case['control'])
        assert not self.allocations,'Unreleased synthetic allocation'
        for address,data in self.inputs.items():assert bytes(self.uc.mem_read(address,len(data)))==data,'Original changed synthetic input'
        raw=bytes(self.uc.mem_read(VB,4*self.stride));rows=[]
        changed=[]
        for vertex in range(4):
            at=vertex*self.stride
            if raw[at:at+self.stride]!=b'\xa5'*self.stride:
                changed.append(vertex)
                assert vertex in [0,2]
                allowed=set(range(at,at+12))|set(range(at+self.normal,at+self.normal+12))
                assert all(v==0xa5 for i,v in enumerate(raw[at:at+self.stride],at) if i not in allowed)
                rows.append({'vertex':vertex,'position':list(struct.unpack_from('<3f',raw,at)),
                             'normal':list(struct.unpack_from('<3f',raw,at+self.normal))})
        return {'result':result,'success_byte':result&255,'changed_vertices':changed,'writes':rows,'buffer_sha256':hashlib.sha256(raw).hexdigest(),
            'phases':list(struct.unpack('<3f',bytes(self.uc.mem_read(OBJECT+0x264,12))))}

cases=[]
for control in [0x27f,0x37f]:
    for fvf in LAYOUT:
        for typ in [0,1]:
            for frame in [-1,0,4.5,9,10,14.5,29,30]:cases.append({'type':typ,'fvf':fvf,'frame':frame,'control':control})
        cases.append({'type':1,'weighted':True,'fvf':fvf,'control':control})
        for typ in [3,4,5]:
            for phase in [-3,0,4.5,9,12]:
                for state in [0,1,2]:cases.append({'type':typ,'fvf':fvf,'phase':phase,'blend_state':state,'blend':.25,'control':control})
    for typ in [3,4,5]:cases.append({'type':typ,'fvf':0x112,'phases':[2,3,7],'mouth_current':2,'eyes_current':1,'blend_state':2,'blend':.25,'control':control})
def main():
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    oracle=OriginalMorph(args.exe)
    vectors=[{'input':case,'output':oracle.run(case)} for case in cases]
    report={'target_sha256':TARGET_SHA256,'original_function_sha256':oracle.hashes,'cases':len(vectors),
        'original_game_resources_used':False,'target_process_launched':False,'pixels_produced':False,
        'boundaries':__doc__,'coverage':'type0, type1 manual and three-vector branch, type3/4/5 sampling and phase clamp; four admitted FVF destination layouts; x87 control words 0x27f and0x37f; mapped source/destination mismatch; original reset bounds; no random blinking/controller dispatch/scene mechanics','vectors':vectors}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(json.dumps({'cases':len(vectors),'source_functions':oracle.hashes,'types':sorted({x['input']['type'] for x in vectors}),
        'changed_cases':sum(bool(x['output']['changed_vertices']) for x in vectors)}))
if __name__=='__main__':main()
