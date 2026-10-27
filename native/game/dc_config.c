#include "dc_config.h"
#include <math.h>
#include <string.h>

static const uint8_t offsets[DC_CONFIG_SLIDERS]={0,8,4,12,16,20,44,32,36,40};
static const uint8_t switch_offsets[6]={27,28,29,25,24,26};
static const dc_config_track tracks[DC_CONFIG_SLIDERS]={
    {260,103,650,17},{260,156,650,17},{260,209,650,17},
    {260,289,230,17},{260,349,230,17},{260,409,230,17},
    {260,573,230,17},{610,434,295,22},{610,458,295,22},{610,482,295,22}
};
static uint32_t word(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static void put_word(uint8_t *p,uint32_t value) {
    for(unsigned i=0;i<4;++i)p[i]=(uint8_t)(value>>(i*8));
}
static float number(const uint8_t *p) { uint32_t bits=word(p);float v;memcpy(&v,&bits,4);return v; }
static void put_float(uint8_t *p,float value) {uint32_t bits;memcpy(&bits,&value,4);put_word(p,bits);}
static int valid(const dc_config *s) {
    for(unsigned i=0;i<3;++i)if((int32_t)word(s->bytes+i*4)<-10000||(int32_t)word(s->bytes+i*4)>0)return 0;
    for(unsigned i=0;i<3;++i){float v=number(s->bytes+12+i*4);if(!isfinite(v)||v<0||v>1)return 0;}
    for(unsigned i=24;i<30;++i)if(s->bytes[i]>1)return 0;
    for(unsigned i=32;i<44;i+=4){float v=number(s->bytes+i);if(!isfinite(v)||v<0||v>255)return 0;}
    float wheel=number(s->bytes+44);return isfinite(wheel)&&wheel>=1&&wheel<=10;
}
dc_status dc_config_reset(dc_config *state) {
    if(!state)return DC_ARGUMENT;
    for(unsigned i=0;i<3;++i)put_word(state->bytes+i*4,(uint32_t)(int32_t)-1200);
    for(unsigned i=12;i<24;i+=4)put_float(state->bytes+i,1);
    memset(state->bytes+24,1,6);
    memset(state->bytes+32,0,12);put_float(state->bytes+44,4);
    return DC_OK;
}
dc_status dc_config_default(dc_config *out) {
    if(!out)return DC_ARGUMENT;
    dc_config next={{0}};dc_config_reset(&next);*out=next;return DC_OK;
}
dc_status dc_config_decode(const void *bytes,size_t length,dc_config *out) {
    if(!bytes||!out)return DC_ARGUMENT;
    if(length<DC_CONFIG_BYTES)return DC_RANGE;
    dc_config next;memcpy(next.bytes,bytes,DC_CONFIG_BYTES);
    if(!valid(&next))return DC_FORMAT;
    *out=next;return DC_OK;
}
dc_status dc_config_encode(const dc_config *state,void *bytes,size_t capacity) {
    if(!state||!bytes)return DC_ARGUMENT;
    if(capacity<DC_CONFIG_BYTES)return DC_RANGE;
    if(!valid(state))return DC_FORMAT;
    memmove(bytes,state->bytes,DC_CONFIG_BYTES);return DC_OK;
}
dc_status dc_config_slider_track(uint32_t slider,dc_config_track *out) {
    if(!out)return DC_ARGUMENT;
    if(slider>=DC_CONFIG_SLIDERS)return DC_RANGE;
    *out=tracks[slider];return DC_OK;
}
dc_status dc_config_slider_value(const dc_config *state,uint32_t slider,float *out) {
    if(!state||!out)return DC_ARGUMENT;
    if(slider>=DC_CONFIG_SLIDERS)return DC_RANGE;
    *out=slider<3?(float)(int32_t)word(state->bytes+offsets[slider]):number(state->bytes+offsets[slider]);return DC_OK;
}
dc_status dc_config_slider_center(const dc_config *state,uint32_t slider,float *out) {
    if(!state||!out)return DC_ARGUMENT;
    if(slider>=DC_CONFIG_SLIDERS)return DC_RANGE;
    float value;dc_config_slider_value(state,slider,&value);
    if(!isfinite(value))return DC_FORMAT;
    double delta=slider<3?(value+6000)*(double)(float)(650.0/6000):
        slider<6?value*230.0:slider==6?(value-1)*(double)(float)(230.0/9):value*(double)(float)(295.0/255);
    *out=(float)(tracks[slider].x+delta);return DC_OK;
}
dc_status dc_config_slider_apply(dc_config *state,uint32_t slider,float center_x) {
    if(!state)return DC_ARGUMENT;
    if(slider>=DC_CONFIG_SLIDERS)return DC_RANGE;
    if(!isfinite(center_x))return DC_ARGUMENT;
    double delta=fmax(0,fmin(tracks[slider].width,(double)center_x-tracks[slider].x));
    if(slider<3)put_word(state->bytes+offsets[slider],(uint32_t)((int32_t)(delta*(double)(float)(6000.0/650))-6000));
    else if(slider<6){
        float value=(float)((int32_t)(delta*(double)(float)(1.0/230)*10000)*(double)(float).0001);
        if(value>=(float).999)value=1;
        put_float(state->bytes+offsets[slider],value);
    } else put_float(state->bytes+offsets[slider],slider==6?(float)(1+delta*(double)(float)(9.0/230)):(float)(delta*(double)(float)(255.0/295)));
    return DC_OK;
}
dc_status dc_config_switch_value(const dc_config *state,uint32_t index,uint32_t *out) {
    if(!state||!out)return DC_ARGUMENT;
    if(index>=6)return DC_RANGE;
    *out=state->bytes[switch_offsets[index]];return DC_OK;
}
dc_status dc_config_switch_toggle(dc_config *state,uint32_t index) {
    if(!state)return DC_ARGUMENT;
    if(index>=6)return DC_RANGE;
    state->bytes[switch_offsets[index]]^=1;return DC_OK;
}
