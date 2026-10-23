"""Self-authored input states for the original menu hit/activation oracle."""
import itertools
import ctypes as C
from native_core import MenuState,MenuButton


def cases():
    layouts=[[(0,0,10,10),(5,5,10,10),(20,20,10,10)],
             [(-1,0,10,10),(0,0,0,0),(3,3,8,8)],
             [(16777216,0,2,10),(16777218,0,2,10)]]
    positions=[(-1,-1),(0,0),(5,5),(10,10),(15,15),(21,21),(16777217,5)]
    for layout,(x,y),scale,flags,hover,code in itertools.product(layouts,positions,(.5,1,1.25),range(4),(-1,0,1),(0,1,2,3,5)):
        buttons=[{'x':a,'y':b,'width':w,'height':h,'disabled':int(flags==1 and i==0),
                  'press_activate':int(flags==2),'toggle':int(flags==3)} for i,(a,b,w,h) in enumerate(layout)]
        yield {'buttons':buttons,'state':{'selected':9,'hover':hover,'active':0,
            'pressed':[2]*32,'toggled':[i%2 for i in range(32)]},'x':x,'y':y,'scale':scale,'input_code':code}


def native_result(lib,case):
    source=case['state'];state=MenuState(source['selected'],source['hover'],source['active'],
        (C.c_uint32*32)(*source['pressed']),(C.c_uint32*32)(*source['toggled']))
    buttons=(MenuButton*len(case['buttons']))(*(MenuButton(**b) for b in case['buttons']))
    result=C.c_int32()
    status=lib.dc_menu_step(C.byref(state),buttons,len(buttons),case['x'],case['y'],case['scale'],case['input_code'],C.byref(result))
    if status:raise ValueError('Native rejected finite menu case')
    return {'state':state.record(),'result':result.value}

