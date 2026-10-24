"""Self-authored indexed-blend cases and native comparison helpers."""
import ctypes as C
from itertools import product
import struct
from native_core import library,Matrix,MeshVertex,XXWeights,SkinPalette,SkinBone,Viewport,SpriteVertex
from scene_cases import matrix


def cases():
    weights=((1,0,0),(.25,.25,.25),(0,0,0),(.2,.3,.5),(.7,.2,.1),
        (.6972389221191406,.2840930223464966,.01866699941456318),
        (.9424239993095398,.04370900243520737,.013868001289665699),(.5,.5,0),(-.1,.5,.8),(1.1,.2,.3),(-0.,0,0))
    for pattern,w,indices,position in product(range(3),weights,((0,1,2,7),(7,2,1,255),(255,255,255,255),(0,0,0,0)),
        ((.1,-.2,.3),(-.4,.2,.7),(0,0,.5),(.5,-.4,.2))):
        palette=[]
        for i in (0,1,2,7):
            transform=matrix(.07*i,1,(i*.015,-i*.01,i*.005))
            if pattern==1:
                for col in range(3):transform.values[col]*=1.2;transform.values[4+col]*=.7;transform.values[8+col]*=1.1
            palette.append([i,bytes(transform).hex()])
        if pattern==2:palette.append([255,bytes(matrix(.1,1,(.1,.2,-.1))).hex()])
        raw=struct.pack('<3f3f4B3f2f',*position,*w,*indices,.3,.4,.8,.125,.75)
        yield {'source_hex':raw.hex(),'palette':palette}


def decode_source(case):
    values=struct.unpack('<3f3f4B3f2f',bytes.fromhex(case['source_hex']))
    vertex=MeshVertex((C.c_float*3)(*values[:3]),(C.c_float*3)(*values[10:13]),(C.c_float*2)(*values[13:15]))
    weights=XXWeights((C.c_float*3)(*values[3:6]),(C.c_uint8*4)(*values[6:10]))
    return vertex,weights


def native_result(case,mode):
    lib=library();palette=SkinPalette();assert lib.dc_skin_palette_init(C.byref(palette))==0
    for index,raw in case['palette']:palette.world[index]=Matrix.from_buffer_copy(bytes.fromhex(raw))
    vertex,weights=decode_source(case);out=MeshVertex()
    status=lib.dc_skin_apply(C.byref(palette),C.byref(vertex),C.byref(weights),1,mode,C.byref(out),1)
    if status:raise ValueError(f'Native skinning rejected synthetic input: {status}')
    vp=matrix();viewport=Viewport(0,0,100,100,0,1);indices=(C.c_uint16*3)(0,0,0);screen=(SpriteVertex*3)()
    assert lib.dc_mesh_project(C.byref(out),1,indices,3,C.byref(vp),C.byref(viewport),0xffffffff,screen,3)==0
    return {'screen':[screen[0].x,screen[0].y,screen[0].z,screen[0].rhw],'normal':list(out.normal),'uv_hex':bytes(out)[24:].hex()}


def palette_cases():
    for count,pattern in product((0,1,4,9,17),range(3)):
        globals=[bytes(matrix(.1*i+pattern*.05,1+i*.1+pattern*.05,(i*.3,-i*.2,i*.1))).hex() for i in range(4)]
        bones=[]
        for i in range(count):
            index=255 if i%5==4 else i%7
            bones.append({'index':index,'target':0xffffffff if index==255 else (i*3)%4,
                'offset_hex':bytes(matrix(-.07*i,.75+i*.025,(-i*.1,i*.05,0))).hex()})
        initial=[]
        if pattern:initial=[[7,bytes(matrix(.2*pattern,.8+pattern*.05,(1,2,3))).hex()],[255,bytes(matrix(.3*pattern,1,(.3,.2,.1))).hex()]]
        yield {'bones':bones,'globals':globals,'initial':initial}


def native_palette(case):
    lib=library();palette=SkinPalette();assert lib.dc_skin_palette_init(C.byref(palette))==0
    for index,raw in case['initial']:palette.world[index]=Matrix.from_buffer_copy(bytes.fromhex(raw))
    globals=(Matrix*len(case['globals']))(*(Matrix.from_buffer_copy(bytes.fromhex(raw)) for raw in case['globals']))
    bones=(SkinBone*len(case['bones']))(*(SkinBone(b['index'],b['target'],Matrix.from_buffer_copy(bytes.fromhex(b['offset_hex']))) for b in case['bones']))
    status=lib.dc_skin_palette_update(C.byref(palette),bones,len(bones),globals,len(globals))
    if status:raise ValueError(f'Native palette rejected synthetic input: {status}')
    return [list(m.values) for m in palette.world]
