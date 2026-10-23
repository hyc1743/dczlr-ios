"""Synthetic byte-pair text, state and clock combinations; no game input."""
import ctypes as C
from itertools import product
from native_core import TextState,TextPlan,TextAdvancePlan


def state(body,**changes):
    s=TextState(columns=30,max_lines=3,visible_lines=1,body_bytes=len(body),current_line=0,
        wait_state=-1,wait_glyph=-1,frame=0,last_frame=2,last_fade_row=0,wait_line=255,
        wait_duration=1000,wait_stamp=100,fade_index=0,active=1,x=135,y=652,font_size=29,scale=1,rgb=0xffefcd)
    for n,v in changes.items():
        if n in ('alpha','line_lengths'):
            for i,x in enumerate(v):getattr(s,n)[i]=x
        else:setattr(s,n,v)
    return s


def tick_cases():
    bodies=(b'ABCD\r\n',b'\x82\xa0\x82\xa2\r\n',b'ABCD\r\nEFGH\r\n',b'ABCD\nEF\n',b'AB'*30+b'CD\r\n')
    for body,current,delta,fast,style in product(bodies,(-1,0,2,4,5),(0,1,25,26,33,-1,2147483647),range(2),range(3)):
        yield {'body':body.hex(),'state':state(body,current_line=current).record(),'delta':delta,'clock':1000,'fast':fast,'style':style}
    for wait,index,alpha,clock,duration,scale in product((-2,-1,1),(0,2,10),(0,254,255,256,0xffffffff),(99,100,1000099,1000100,0xfffffff0),(0,1000),(.5,1.75)):
        body=b'ABCD\r\n'
        s=state(body,wait_state=wait,wait_glyph=2,fade_index=index,wait_duration=duration,scale=scale,alpha=[alpha]*200)
        yield {'body':body.hex(),'state':s.record(),'delta':17,'clock':clock,'fast':1,'style':2}


def advance_cases():
    body=b'ABCD\r\n'
    for frame,current,last_row,visible,alpha,fast,fade in product((-1,0,1,2),(-1,0,2,3,4),(0,2),(1,3),(0,254,255),range(2),(0,2,8)):
        s=state(body,frame=frame,current_line=current,last_fade_row=last_row,visible_lines=visible,alpha=[alpha]*200,fade_index=fade)
        yield {'state':s.record(),'fast':fast}


def from_record(record):
    out=TextState()
    for n,v in record.items():
        if n in ('alpha','line_lengths'):
            for i,x in enumerate(v):getattr(out,n)[i]=x
        else:setattr(out,n,v)
    return out


def native_tick(lib,case):
    body=bytes.fromhex(case['body']);s=from_record(case['state']);out=TextPlan()
    if lib.dc_text_build_plan(C.byref(s),body,len(body),case['delta'],case['clock'],case['fast'],C.byref(out)):
        raise ValueError('Native text tick rejected synthetic case')
    draws=[]
    for g in out.glyphs[:out.count]:
        label=bytes(g.bytes).split(b'\0')[0].hex();black=g.color&0xff000000
        offsets=([(2,2)] if case['style']==1 else [(-1,-1),(1,1),(-1,1),(1,-1)] if case['style']==2 else [])
        draws.extend([[g.x+x,g.y+y,label,black] for x,y in offsets]);draws.append([g.x,g.y,label,g.color])
    return {'state':out.next.record(),'draws':draws}


def native_advance(lib,case):
    s=from_record(case['state']);out=TextAdvancePlan()
    if lib.dc_text_advance(C.byref(s),case['fast'],C.byref(out)):raise ValueError('Native text advance rejected synthetic case')
    return {'state':out.next.record(),'load_record':out.load_record,'finished':out.finished}
