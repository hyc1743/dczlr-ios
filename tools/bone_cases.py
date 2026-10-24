"""Self-authored XX bone tables with duplicate/root-only/missing name targets."""
import ctypes as C
from itertools import product
from native_core import XXModel,Matrix,library
from scene_cases import matrix
from xx_cases import name,u32,node,material


def model(records,version=0x404c28f6):
    carrier=node(uv_sets=0,bone_records=records,vertex_format=0x111c,label=b'carrier\0')
    tree=node((carrier,node(label=b'synthetic-node\0'),node(label=b'synthetic-node\0')),label=b'root-only\0')
    return u32(version)+bytes(17)+tree+bytes(4)+u32(1)+material()+u32(0)


def cases():
    labels=(b'synthetic-node\0',b'root-only\0',b'carrier\0',b'missing\0',b'synthetic-node\0ignored',b'\0')
    for count,pattern,version in product((0,1,3,7,32),range(3),(0x404ae148,0x404c28f6)):
        records=[]
        for i in range(count):
            index=i if pattern==0 else count-1-i if pattern==1 else (0xffffffff if i==count-1 else i*3+7)
            transform=matrix(.13*i,.5+i*.125,(i*.3,-i*.2,i*.1))
            records.append((labels[(i+pattern)%len(labels)],index,bytes(transform)))
        table=u32(count)+b''.join(name(label)+u32(index)+transform for label,index,transform in records)
        yield {'count':count,'pattern':pattern,'version':version,'table_hex':table.hex(),
            'model_hex':model(records,version).hex()}


def native_result(case):
    lib=library();records=[]
    with XXModel(bytes.fromhex(case['model_hex'])) as xx:
        skin=xx.at('skin',1)
        for i in range(skin.bones):
            bone=xx.at('bone',skin.first_bone+i);transform=Matrix()
            if lib.dc_xx_bone_matrix(xx.handle,skin.first_bone+i,C.byref(transform)):raise ValueError('Native bone matrix rejected fixture')
            records.append({'name_hex':bytes(v^255 for v in xx.span(bone.name)).hex(),'index':bone.index,'matrix_hex':bytes(transform).hex()})
        targets=(C.c_uint32*skin.bones)()
        if lib.dc_xx_bind_bones(xx.handle,1,targets,len(targets)):raise ValueError('Native bone binding rejected fixture')
    return {'records':records,'targets':list(targets)}
