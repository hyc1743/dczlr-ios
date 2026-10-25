#ifndef DC_GAMEPAD_H
#define DC_GAMEPAD_H
#include <stdint.h>
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
enum {
    DC_PAD_A=1u<<0, DC_PAD_B=1u<<1, DC_PAD_X=1u<<2, DC_PAD_Y=1u<<3,
    DC_PAD_L3=1u<<4, DC_PAD_R3=1u<<5, DC_PAD_L=1u<<6, DC_PAD_R=1u<<7,
    DC_PAD_ZL=1u<<8, DC_PAD_ZR=1u<<9, DC_PAD_PLUS=1u<<10, DC_PAD_MINUS=1u<<11,
    DC_PAD_LEFT=1u<<12, DC_PAD_UP=1u<<13, DC_PAD_RIGHT=1u<<14, DC_PAD_DOWN=1u<<15
};
#define DC_PAD_SHAKE (UINT64_C(1)<<63)
typedef struct dc_pad_raw { uint64_t buttons; int32_t lx,ly,rx,ry; } dc_pad_raw;
typedef struct dc_pad_touch { uint32_t id; float x,y; } dc_pad_touch;
typedef struct dc_pad_frame {
    uint64_t buttons, pressed, released;
    int32_t lx,ly,rx,ry;
    uint32_t connected, touch_count;
    float touch_x,touch_y;
    dc_pad_touch touches[16];
} dc_pad_frame;
typedef struct dc_pad_latch {
    dc_pad_raw current;
    uint64_t pending, previous;
    uint32_t connected, touch_count, pending_touch;
    dc_pad_touch touches[16], tap;
} dc_pad_latch;
/* Same radial dead zone and full tilt as weixing3's DmGamepad.m. */
DC_API void dc_pad_stick(float dx,float dy,float radius,int32_t *x,int32_t *y);
/* A tilted physical stick wins as a pair (4000 of 32767). Buttons OR. */
DC_API dc_pad_raw dc_pad_merge(dc_pad_raw virtual_pad,dc_pad_raw physical_pad);
/* Caller serializes these operations. A brief tap survives until the next poll. */
DC_API void dc_pad_publish(dc_pad_latch *state,dc_pad_raw raw);
DC_API void dc_pad_touches(dc_pad_latch *state,const dc_pad_touch *touches,uint32_t count);
DC_API dc_pad_frame dc_pad_poll(dc_pad_latch *state);
DC_API void dc_pad_clear(dc_pad_latch *state);
#ifdef __cplusplus
}
#endif
#endif
