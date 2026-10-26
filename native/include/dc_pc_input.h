#ifndef DC_PC_INPUT_H
#define DC_PC_INPUT_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_PC_SOURCE_COUNT 32u
#define DC_PC_KEY_COUNT 256u
#define DC_PC_MOUSE_COUNT 3u
#define DC_PC_UNMAPPED UINT32_MAX

typedef struct dc_pc_source {
    uint8_t keys[DC_PC_KEY_COUNT], mouse[DC_PC_MOUSE_COUNT], active;
} dc_pc_source;
typedef struct dc_pc_latch {
    dc_pc_source sources[DC_PC_SOURCE_COUNT];
    uint8_t previous_keys[DC_PC_KEY_COUNT], previous_mouse[DC_PC_MOUSE_COUNT];
    uint8_t pending_keys[DC_PC_KEY_COUNT], pending_mouse[DC_PC_MOUSE_COUNT];
    float x,y;
    int32_t dx,dy,wheel;
    uint32_t pointer_active; /* Bit set per source owning an absolute pointer. */
} dc_pc_latch;
typedef struct dc_pc_frame {
    uint8_t keys[DC_PC_KEY_COUNT], mouse[DC_PC_MOUSE_COUNT];
    float x,y;
    int32_t dx,dy,wheel;
    uint32_t active, pointer_active;
} dc_pc_frame;

/* Sources are caller-assigned slots 0..31, shared by that source's devices or
 * gestures. Setters activate their slot. Remove a source when disconnected.
 * Calls must be serialized by the host. Coordinates are normalized [0,1]. */
DC_API void dc_pc_input_init(dc_pc_latch *latch);
DC_API dc_status dc_pc_input_source(dc_pc_latch *latch,uint32_t source_id,uint32_t active);
DC_API dc_status dc_pc_input_key(dc_pc_latch *latch,uint32_t source_id,uint32_t scancode,uint32_t down);
DC_API dc_status dc_pc_input_mouse(dc_pc_latch *latch,uint32_t source_id,uint32_t button,uint32_t down);
DC_API dc_status dc_pc_input_pointer(dc_pc_latch *latch,uint32_t source_id,float x,float y);
DC_API dc_status dc_pc_input_motion(dc_pc_latch *latch,uint32_t source_id,int32_t dx,int32_t dy,int32_t wheel);
/* Four states: 0 idle, 3 newly pressed, 1 held, 2 newly released. Short taps
 * survive until poll, with release on the following poll. Repeated taps on
 * one control between polls coalesce. Motion is consumed once per poll.
 * Z/X supplement idle left/right mouse states; A/S press supplies +/-120
 * wheel (A takes priority), matching original main-loop fallback ordering. */
DC_API dc_status dc_pc_input_poll(dc_pc_latch *latch,dc_pc_frame *out);
/* Drop sources, pending taps and motion; retain prior polled states so the
 * next poll releases held controls. Pointer position is retained. */
DC_API void dc_pc_input_clear(dc_pc_latch *latch);
/* USB keyboard usage page 0x07 / UIKeyboardHIDUsage values. Unknown usages
 * return DC_PC_UNMAPPED. This maps physical keys, independent of text layout. */
DC_API uint32_t dc_pc_input_hid_scancode(uint32_t usage);
#ifdef __cplusplus
}
#endif
#endif
