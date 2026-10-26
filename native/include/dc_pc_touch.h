#ifndef DC_PC_TOUCH_H
#define DC_PC_TOUCH_H
#include "dc_pc_input.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_PC_TOUCH_COUNT 28u
#define DC_PC_TOUCH_POINTER 28u
#define DC_PC_TOUCH_NONE UINT32_MAX
typedef struct dc_pc_touch_target { float x,y,diameter; uint32_t code; } dc_pc_touch_target;
typedef struct dc_pc_touch_contact { uint64_t id; uint32_t control; float x,y; } dc_pc_touch_contact;
typedef struct dc_pc_touch {
    float width,height,cursor_x,cursor_y;
    dc_pc_touch_target targets[DC_PC_TOUCH_COUNT];
    dc_pc_touch_contact contacts[16];
} dc_pc_touch;
/* Pointer coordinates refer to the full drawable. Layout respects safe insets.
 * Codes 0..255 are scan codes; 256/257 mouse buttons, 259/260 wheel pulses.
 * Contact slots own PC sources 0..15, the persistent pointer owns source 27.
 * Moving on the open surface never clicks. Lifting retains cursor position. */
DC_API dc_status dc_pc_touch_layout(dc_pc_touch *state,float w,float h,float left,float top,float right,float bottom);
DC_API uint32_t dc_pc_touch_hit(const dc_pc_touch *state,float x,float y);
DC_API dc_status dc_pc_touch_begin(dc_pc_touch *state,dc_pc_latch *input,uint64_t id,float x,float y);
DC_API dc_status dc_pc_touch_move(dc_pc_touch *state,dc_pc_latch *input,uint64_t id,float x,float y);
DC_API dc_status dc_pc_touch_end(dc_pc_touch *state,dc_pc_latch *input,uint64_t id);
DC_API void dc_pc_touch_reset(dc_pc_touch *state,dc_pc_latch *input);
#ifdef __cplusplus
}
#endif
#endif
