#include "dc_gamepad.h"
#include <math.h>
#include <string.h>

void dc_pad_stick(float dx,float dy,float radius,int32_t *x,int32_t *y) {
    if(!x||!y)return;
    *x=*y=0;
    if(!isfinite(dx)||!isfinite(dy)||!isfinite(radius)||radius<=0)return;
    float d=hypotf(dx,dy),dead=radius*.1f;
    if(d<=dead)return;
    float magnitude=fminf((d-dead)/(radius*.7f),1.f)/d;
    *x=(int32_t)lrintf(dx*magnitude*32767.f);
    *y=(int32_t)lrintf(-dy*magnitude*32767.f);
}
static int tilted(int32_t x,int32_t y) {
    return (int64_t)x*x+(int64_t)y*y>INT64_C(4000)*4000;
}
dc_pad_raw dc_pad_merge(dc_pad_raw v,dc_pad_raw p) {
    v.buttons|=p.buttons;
    if(tilted(p.lx,p.ly)){v.lx=p.lx;v.ly=p.ly;}
    if(tilted(p.rx,p.ry)){v.rx=p.rx;v.ry=p.ry;}
    return v;
}
void dc_pad_publish(dc_pad_latch *s,dc_pad_raw raw) {
    s->pending|=raw.buttons&~s->current.buttons;
    s->current=raw;
}
void dc_pad_touches(dc_pad_latch *s,const dc_pad_touch *touches,uint32_t count) {
    if(count>16)count=16;
    if(count&&!touches)return;
    if(count&&!s->touch_count){s->tap=touches[0];s->pending_touch=1;}
    s->touch_count=count;
    if(count)memcpy(s->touches,touches,count*sizeof(*touches));
}
dc_pad_frame dc_pad_poll(dc_pad_latch *s) {
    dc_pad_frame f={0};
    f.buttons=s->current.buttons|s->pending;
    f.lx=s->current.lx;f.ly=s->current.ly;f.rx=s->current.rx;f.ry=s->current.ry;
    /* Match Npad direction flags; shake stays separate from the 16 game buttons. */
    const int32_t threshold=16384;
    if(f.lx < -threshold)f.buttons|=UINT64_C(1)<<16;
    if(f.ly > threshold)f.buttons|=UINT64_C(1)<<17;
    if(f.lx > threshold)f.buttons|=UINT64_C(1)<<18;
    if(f.ly < -threshold)f.buttons|=UINT64_C(1)<<19;
    if(f.rx < -threshold)f.buttons|=UINT64_C(1)<<20;
    if(f.ry > threshold)f.buttons|=UINT64_C(1)<<21;
    if(f.rx > threshold)f.buttons|=UINT64_C(1)<<22;
    if(f.ry < -threshold)f.buttons|=UINT64_C(1)<<23;
    f.pressed=f.buttons&~s->previous;f.released=s->previous&~f.buttons;
    s->previous=f.buttons;s->pending=0;f.connected=s->connected;
    f.touch_count=s->touch_count;
    if(f.touch_count)memcpy(f.touches,s->touches,f.touch_count*sizeof(*f.touches));
    else if(s->pending_touch){f.touch_count=1;f.touches[0]=s->tap;}
    s->pending_touch=0;
    if(f.touch_count){f.touch_x=f.touches[0].x;f.touch_y=f.touches[0].y;}
    return f;
}
void dc_pad_clear(dc_pad_latch *s) {
    /* Preserve sampled previous buttons so the next poll reports releases. */
    uint64_t previous=s->previous;uint32_t connected=s->connected;
    memset(s,0,sizeof(*s));s->previous=previous;s->connected=connected;
}
