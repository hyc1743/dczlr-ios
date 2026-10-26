#ifndef DC_TOUCH_CONTROLS_H
#define DC_TOUCH_CONTROLS_H
#include "dc_gamepad.h"
#ifdef __cplusplus
extern "C" {
#endif
enum {
    DC_TOUCH_NONE, DC_TOUCH_MOVE, DC_TOUCH_LOOK, DC_TOUCH_PRIMARY,
    DC_TOUCH_BACK, DC_TOUCH_SAVE, DC_TOUCH_RESET, DC_TOUCH_NEXT,
    DC_TOUCH_ZOOM_IN, DC_TOUCH_ZOOM_OUT, DC_TOUCH_MENU, DC_TOUCH_COUNT,
    DC_TOUCH_POINTER = DC_TOUCH_COUNT
};
typedef struct dc_touch_rect { float x,y,width,height; } dc_touch_rect;
typedef struct dc_touch_layout {
    float width,height;
    uint32_t gameplay;
    dc_touch_rect controls[DC_TOUCH_COUNT];
} dc_touch_layout;
typedef struct dc_touch_contact {
    uint64_t id;
    uint32_t control;
    float x,y,origin_x,origin_y;
} dc_touch_contact;
typedef struct dc_touch_controls {
    dc_touch_layout layout;
    dc_touch_contact fingers[16];
    float look_dx,look_dy;
} dc_touch_controls;
typedef struct dc_touch_snapshot {
    dc_pad_raw pad;
    dc_pad_touch touches[16];
    uint32_t touch_count,held_ui;
} dc_touch_snapshot;
/* Shared UIKit/test geometry in points. Each finger keeps its initial owner. */
DC_API dc_status dc_touch_make_layout(float width,float height,float left,float top,
    float right,float bottom,uint32_t gameplay,dc_touch_layout *out);
DC_API uint32_t dc_touch_hit(const dc_touch_layout *layout,float x,float y);
DC_API dc_status dc_touch_begin(dc_touch_controls *state,uint64_t id,float x,float y);
DC_API dc_status dc_touch_move(dc_touch_controls *state,uint64_t id,float x,float y);
DC_API uint32_t dc_touch_end(dc_touch_controls *state,uint64_t id,uint32_t cancelled);
DC_API void dc_touch_reset(dc_touch_controls *state);
DC_API void dc_touch_clear_motion(dc_touch_controls *state);
DC_API dc_touch_snapshot dc_touch_read(const dc_touch_controls *state);
#ifdef __cplusplus
}
#endif
#endif
