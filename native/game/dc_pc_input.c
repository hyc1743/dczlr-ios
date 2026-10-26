#include "dc_pc_input.h"
#include <limits.h>
#include <math.h>
#include <string.h>

static int any_key(const dc_pc_latch *l,uint32_t key) {
    for(uint32_t i=0;i<DC_PC_SOURCE_COUNT;++i)if(l->sources[i].active&&l->sources[i].keys[key])return 1;
    return 0;
}
static int any_mouse(const dc_pc_latch *l,uint32_t button) {
    for(uint32_t i=0;i<DC_PC_SOURCE_COUNT;++i)if(l->sources[i].active&&l->sources[i].mouse[button])return 1;
    return 0;
}
static uint8_t code(uint8_t previous,int down,uint8_t pending) {
    return pending?3:(down?(previous?1:3):(previous?2:0));
}
static int32_t add_saturated(int32_t a,int32_t b) {
    int64_t sum=(int64_t)a+b;
    return sum>INT32_MAX?INT32_MAX:sum<INT32_MIN?INT32_MIN:(int32_t)sum;
}
void dc_pc_input_init(dc_pc_latch *l) {
    if(l){memset(l,0,sizeof(*l));l->x=.5f;l->y=.5f;}
}
dc_status dc_pc_input_source(dc_pc_latch *l,uint32_t id,uint32_t active) {
    if(!l)return DC_ARGUMENT;
    if(id>=DC_PC_SOURCE_COUNT||active>1)return DC_RANGE;
    if(!active)memset(&l->sources[id],0,sizeof(l->sources[id]));
    else l->sources[id].active=1;
    return DC_OK;
}
dc_status dc_pc_input_key(dc_pc_latch *l,uint32_t id,uint32_t key,uint32_t down) {
    if(!l)return DC_ARGUMENT;
    if(id>=DC_PC_SOURCE_COUNT||key>=DC_PC_KEY_COUNT||down>1)return DC_RANGE;
    int was=any_key(l,key);
    l->sources[id].active=1;l->sources[id].keys[key]=(uint8_t)down;
    if(down&&!was)l->pending_keys[key]=1;
    return DC_OK;
}
dc_status dc_pc_input_mouse(dc_pc_latch *l,uint32_t id,uint32_t button,uint32_t down) {
    if(!l)return DC_ARGUMENT;
    if(id>=DC_PC_SOURCE_COUNT||button>=DC_PC_MOUSE_COUNT||down>1)return DC_RANGE;
    int was=any_mouse(l,button);
    l->sources[id].active=1;l->sources[id].mouse[button]=(uint8_t)down;
    if(down&&!was)l->pending_mouse[button]=1;
    return DC_OK;
}
dc_status dc_pc_input_pointer(dc_pc_latch *l,uint32_t id,float x,float y) {
    if(!l)return DC_ARGUMENT;
    if(id>=DC_PC_SOURCE_COUNT||!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1)return DC_RANGE;
    l->sources[id].active=1;l->x=x;l->y=y;
    return DC_OK;
}
dc_status dc_pc_input_motion(dc_pc_latch *l,uint32_t id,int32_t dx,int32_t dy,int32_t wheel) {
    if(!l)return DC_ARGUMENT;
    if(id>=DC_PC_SOURCE_COUNT)return DC_RANGE;
    l->sources[id].active=1;
    l->dx=add_saturated(l->dx,dx);l->dy=add_saturated(l->dy,dy);l->wheel=add_saturated(l->wheel,wheel);
    return DC_OK;
}
dc_status dc_pc_input_poll(dc_pc_latch *l,dc_pc_frame *out) {
    if(!l||!out)return DC_ARGUMENT;
    dc_pc_frame frame={0};
    for(uint32_t i=0;i<DC_PC_SOURCE_COUNT;++i)frame.active|=l->sources[i].active;
    for(uint32_t i=0;i<DC_PC_KEY_COUNT;++i){
        frame.keys[i]=code(l->previous_keys[i],any_key(l,i),l->pending_keys[i]);
        l->previous_keys[i]=frame.keys[i]&1u;l->pending_keys[i]=0;
    }
    for(uint32_t i=0;i<DC_PC_MOUSE_COUNT;++i){
        frame.mouse[i]=code(l->previous_mouse[i],any_mouse(l,i),l->pending_mouse[i]);
        l->previous_mouse[i]=frame.mouse[i]&1u;l->pending_mouse[i]=0;
    }
    frame.x=l->x;frame.y=l->y;frame.dx=l->dx;frame.dy=l->dy;frame.wheel=l->wheel;
    l->dx=0;l->dy=0;l->wheel=0;
    if(!frame.mouse[0])frame.mouse[0]=frame.keys[0x2c];
    if(!frame.mouse[1])frame.mouse[1]=frame.keys[0x2d];
    if(frame.keys[0x1e]==3)frame.wheel=120;
    else if(frame.keys[0x1f]==3)frame.wheel=-120;
    *out=frame;
    return DC_OK;
}
void dc_pc_input_clear(dc_pc_latch *l) {
    if(!l)return;
    memset(l->sources,0,sizeof(l->sources));
    memset(l->pending_keys,0,sizeof(l->pending_keys));memset(l->pending_mouse,0,sizeof(l->pending_mouse));
    l->dx=0;l->dy=0;l->wheel=0;
}
uint32_t dc_pc_input_hid_scancode(uint32_t usage) {
    static const uint8_t letters[26]={0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
    static const uint8_t modifiers[8]={0x1d,0x2a,0x38,0xdb,0x9d,0x36,0xb8,0xdc};
    if(usage>=4&&usage<=29)return letters[usage-4];
    if(usage>=30&&usage<=38)return usage-28;
    if(usage==39)return 0x0b;
    if(usage>=58&&usage<=67)return usage+1;
    if(usage==68||usage==69)return usage+19;
    if(usage>=224&&usage<=231)return modifiers[usage-224];
    switch(usage){
    case 40:return 0x1c;case 41:return 1;case 42:return 0x0e;case 43:return 0x0f;case 44:return 0x39;
    case 45:return 0x0c;case 46:return 0x0d;case 47:return 0x1a;case 48:return 0x1b;case 49:return 0x2b;
    case 50:return 0x2b;case 51:return 0x27;case 52:return 0x28;case 53:return 0x29;case 54:return 0x33;
    case 55:return 0x34;case 56:return 0x35;case 57:return 0x3a;case 70:return 0xb7;case 71:return 0x46;
    case 72:return 0xc5;case 73:return 0xd2;case 74:return 0xc7;case 75:return 0xc9;case 76:return 0xd3;
    case 77:return 0xcf;case 78:return 0xd1;case 79:return 0xcd;case 80:return 0xcb;case 81:return 0xd0;
    case 82:return 0xc8;case 83:return 0x45;case 84:return 0xb5;case 85:return 0x37;case 86:return 0x4a;
    case 87:return 0x4e;case 88:return 0x9c;case 89:return 0x4f;case 90:return 0x50;case 91:return 0x51;
    case 92:return 0x4b;case 93:return 0x4c;case 94:return 0x4d;case 95:return 0x47;case 96:return 0x48;
    case 97:return 0x49;case 98:return 0x52;case 99:return 0x53;case 100:return 0x56;case 101:return 0xdd;
    default:return DC_PC_UNMAPPED;
    }
}
