"""Self-authored two-node inputs for original render/transform flag separation."""
import ctypes as C
from native_core import XXModel,Matrix
from xx_cases import diagnostic_fixture
from scene_cases import matrix

OPERATIONS=((0,1),(1,0),(1,1),(0,0),(1,1),(0,1),(0,0))
def cases():
    for freeze in ((0,0),(0,1),(1,0),(1,1)):
        for position in ((20,4,-3),(-7,9,12)):
            yield {'freeze':list(freeze),'world':list(matrix(.3,1.2,position).values),'operations':[list(v) for v in OPERATIONS]}
def native_result(lib,case):
    xx=bytearray(diagnostic_fixture())
    with XXModel(bytes(xx)) as parsed:
        offsets=[parsed.at('node',i).matrix_offset+116 for i in range(2)]
    for offset,value in zip(offsets,case['freeze']):xx[offset]=value
    source=bytes(xx);model=C.c_void_p();assert lib.dc_model_open_static(source,len(source),C.byref(model))==0
    world=Matrix((C.c_float*16)(*case['world']));rows=[]
    try:
        for node,hidden in case['operations']:
            assert lib.dc_model_hide_node(model,node,hidden)==0
            assert lib.dc_model_tick(model,0,0,C.byref(world))==0
            visible=C.c_uint32();assert lib.dc_model_mesh_visible(model,0,C.byref(visible))==0
            out=Matrix();assert lib.dc_model_global(model,1,C.byref(out))==0
            rows.append({'visible':visible.value,'child_world':list(out.values)})
    finally:lib.dc_model_close(model)
    return rows
