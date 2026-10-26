#include "dc_pc_touch.h"
#include <math.h>
#include <string.h>
dc_status dc_pc_touch_layout(dc_pc_touch *s,float w,float h,float l,float t,float r,float b) {
    if(!s)return DC_ARGUMENT;
    const float v[]={w,h,l,t,r,b};for(unsigned i=0;i<6;++i)if(!isfinite(v[i]))return DC_RANGE;
    if(l<0||t<0||r<0||b<0||w-l-r<540||h-t-b<240)return DC_RANGE;
    dc_pc_touch next=*s;next.width=w;next.height=h;
    float aw=w-l-r,ah=h-t-b,d=fminf(56,fminf(aw*.051f,ah*.095f));
    /* Group positions follow the supplied picture, not a keyboard grid. */
    const uint32_t codes[]={1,0x2f,0x3b,0x1e,0x2c,0x2d,0x1f,0xc9,0xc7,0xcf,0xd1,
        0xc8,0xcb,0xcd,0xd0,2,3,4,5,0x2e,0x48,0x4b,0x4d,0x50,259,260,256,257};
    const float px[]={.5f,3.4f,5.5f,1.5f,.5f,2.5f,1.5f,1.5f,.5f,2.5f,1.5f,
        1.5f,.5f,2.5f,1.5f,-.5f,-.5f,-.5f,-.5f,-.5f,-1.5f,-2.5f,-.5f,-1.5f,-2.1f,-2.1f,-2.1f,-2.1f};
    const float py[]={.065f,.065f,.065f,.20f,.27f,.27f,.34f,.46f,.53f,.53f,.60f,
        .71f,.78f,.78f,.85f,.08f,.18f,.28f,.38f,.49f,.68f,.76f,.76f,.84f,.15f,.235f,.32f,.405f};
    for(unsigned i=0;i<DC_PC_TOUCH_COUNT;++i)next.targets[i]=(dc_pc_touch_target){
        (px[i]<0?w-r:l)+px[i]*d,t+py[i]*ah,i>=24?d*.72f:d,codes[i]};
    *s=next;return DC_OK;
}
uint32_t dc_pc_touch_hit(const dc_pc_touch *s,float x,float y) {
    if(!s||!isfinite(x)||!isfinite(y)||x<0||y<0||x>s->width||y>s->height)return DC_PC_TOUCH_NONE;
    for(unsigned i=0;i<DC_PC_TOUCH_COUNT;++i) {
        dc_pc_touch_target r=s->targets[i];if(r.diameter>0&&hypotf(x-r.x,y-r.y)<=r.diameter*.5f)return i;
    }
    return DC_PC_TOUCH_POINTER;
}
static int slot(dc_pc_touch *s,uint64_t id) {for(int i=0;i<16;++i)if(s->contacts[i].id==id)return i;return -1;}
dc_status dc_pc_touch_begin(dc_pc_touch *s,dc_pc_latch *in,uint64_t id,float x,float y) {
    if(!s||!in||!id)return DC_ARGUMENT;
    uint32_t control=dc_pc_touch_hit(s,x,y);if(control==DC_PC_TOUCH_NONE)return DC_RANGE;
    if(slot(s,id)>=0)return DC_ARGUMENT;
    int free=-1;
    for(int i=0;i<16;++i) {
        if(!s->contacts[i].id){if(free<0)free=i;}
        else if(control==DC_PC_TOUCH_POINTER&&s->contacts[i].control==control)return DC_RANGE;
    }
    if(free<0)return DC_RANGE;
    s->contacts[free]=(dc_pc_touch_contact){id,control,x,y};
    /* Activate a persistent pointer even if the first event is a button. */
    dc_pc_input_pointer(in,27,s->cursor_x,s->cursor_y);
    if(control<DC_PC_TOUCH_COUNT) {
        uint32_t code=s->targets[control].code;
        if(code<256)dc_pc_input_key(in,(uint32_t)free,code,1);
        else if(code<258)dc_pc_input_mouse(in,(uint32_t)free,code-256,1);
        else dc_pc_input_motion(in,(uint32_t)free,0,0,code==259?120:-120);
    }
    return DC_OK;
}
dc_status dc_pc_touch_move(dc_pc_touch *s,dc_pc_latch *in,uint64_t id,float x,float y) {
    if(!s||!in||!id)return DC_ARGUMENT;
    if(!isfinite(x)||!isfinite(y))return DC_RANGE;
    int at=slot(s,id);if(at<0)return DC_NOT_FOUND;
    dc_pc_touch_contact *f=&s->contacts[at];
    if(f->control==DC_PC_TOUCH_POINTER) {
        float before_x=s->cursor_x,before_y=s->cursor_y;
        s->cursor_x=fmaxf(0,fminf(1,s->cursor_x+(x-f->x)/s->width));
        s->cursor_y=fmaxf(0,fminf(1,s->cursor_y+(y-f->y)/s->height));
        dc_pc_input_pointer(in,27,s->cursor_x,s->cursor_y);
        float scale=fminf(s->width/1024.f,s->height/768.f);
        dc_pc_input_motion(in,27,(int32_t)lrintf((s->cursor_x-before_x)*s->width/scale),
            (int32_t)lrintf((s->cursor_y-before_y)*s->height/scale),0);
    }
    f->x=x;f->y=y;return DC_OK;
}
dc_status dc_pc_touch_end(dc_pc_touch *s,dc_pc_latch *in,uint64_t id) {
    if(!s||!in||!id)return DC_ARGUMENT;
    int at=slot(s,id);if(at<0)return DC_NOT_FOUND;
    dc_pc_input_source(in,(uint32_t)at,0);memset(&s->contacts[at],0,sizeof(s->contacts[at]));return DC_OK;
}
void dc_pc_touch_reset(dc_pc_touch *s,dc_pc_latch *in) {
    if(!s||!in)return;
    uint8_t keys[DC_PC_KEY_COUNT]={0},mouse[DC_PC_MOUSE_COUNT]={0};
    for(unsigned i=0;i<16;++i)if(s->contacts[i].id) {
        uint32_t control=s->contacts[i].control;
        if(control<DC_PC_TOUCH_COUNT) {
            uint32_t code=s->targets[control].code;
            if(code<256)keys[code]=1;else if(code<258)mouse[code-256]=1;
        }
        dc_pc_input_source(in,i,0);
    }
    /* Cancel unseen taps on resize/mode reset without deleting a physical
     * source's pending press. Previously polled controls still release. */
    for(unsigned k=0;k<DC_PC_KEY_COUNT;++k)if(keys[k]) {
        int held=0;for(unsigned i=0;i<DC_PC_SOURCE_COUNT;++i)held|=in->sources[i].active&&in->sources[i].keys[k];
        if(!held)in->pending_keys[k]=0;
    }
    for(unsigned k=0;k<DC_PC_MOUSE_COUNT;++k)if(mouse[k]) {
        int held=0;for(unsigned i=0;i<DC_PC_SOURCE_COUNT;++i)held|=in->sources[i].active&&in->sources[i].mouse[k];
        if(!held)in->pending_mouse[k]=0;
    }
    memset(s->contacts,0,sizeof(s->contacts));dc_pc_input_source(in,27,0);
}
