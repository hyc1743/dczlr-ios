#ifndef DC_SCENE_UI_H
#define DC_SCENE_UI_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_SCENE_CONTEXT_LIMIT 7u
typedef struct dc_scene_context_item {
    int32_t resource_id;
    uint32_t arrangement;
    float x,y;
} dc_scene_context_item;
typedef struct dc_scene_context {
    uint32_t icon,count,opening_right;
    int32_t hover;
    dc_scene_context_item items[DC_SCENE_CONTEXT_LIMIT];
} dc_scene_context;
typedef struct dc_scene_context_input {
    uint32_t scene_type,icon,stage_progress,animation,camera_mode,secondary_camera_mode;
    float x,y;
} dc_scene_context_input;
typedef struct dc_scene_context_event {
    uint32_t close_code; /* Original 00532240 context result; NEVER a chapter. */
    int32_t selected;   /* Context option index, not the main icon row. */
} dc_scene_context_event;
/* Recovered initial type-4 profiles from 00533a70/005342b0/005352c0/00535730.
 * Evolved character/outfit profiles return DC_NOT_FOUND, not guessed options.
 * Placement is 005319e0's 105/35 fan with a 240x32 sprite, pivot (.9,.5).
 * Logical 1024x768 coordinates; output is unchanged on failure. */
DC_API dc_status dc_scene_context_build(const dc_scene_context_input *input,dc_scene_context *out);
DC_API dc_status dc_scene_context_hit(const dc_scene_context *menu,float x,float y,int32_t *out);
/* Button bytes use the PC latch's 3 press / 1 held / 2 release / 0 idle.
 * An outside left press or a subsequent right press dismisses the menu.
 * Opening right press is retained until release; no synthetic left click. */
DC_API dc_status dc_scene_context_step(dc_scene_context *menu,float x,float y,uint32_t left,uint32_t right,dc_scene_context_event *out);
DC_API dc_status dc_scene_context_resource(uint32_t scene_type,uint32_t icon,int32_t resource_id,uint32_t state,char *out,size_t capacity);
/* FUN_0051a890 selects the stage's quarter of the 384x96 outfit atlas. */
DC_API dc_status dc_scene_icon_uv(uint32_t stage,uint32_t icon,float *u0,float *u1);

enum dc_scene_action_kind {
    DC_SCENE_CAMERA_RETARGET_PRIMARY=1,DC_SCENE_CAMERA_RESET_PRIMARY=2,
    DC_SCENE_CAMERA_RETARGET_SECONDARY=3,DC_SCENE_CAMERA_RESET_SECONDARY=4,
    DC_SCENE_ENTER_SAVE_MENU=5,DC_SCENE_ENTER_EDIT_MENU=6
};
typedef struct dc_scene_action_command { uint32_t kind,target; } dc_scene_action_command;
typedef struct dc_scene_action_plan {
    uint32_t camera_mode,secondary_camera_mode,count;
    dc_scene_action_command commands[2];
} dc_scene_action_plan;
/* Original FUN_00539dd0/FUN_0053a7c0 type-4 numeric dispatch. An option is
 * its context index, never its resource ID or its main icon row. Camera
 * retargeting and destination scene execution are separate host boundaries.
 * Commands 1/3 target entries 0/1; commands 2/4 use the current CAM preset.
 * System options request SAVE/EDIT; neither advances the chapter. */
DC_API dc_status dc_scene_action_build(uint32_t scene_type,uint32_t icon,uint32_t option,
    uint32_t camera_mode,uint32_t secondary_camera_mode,dc_scene_action_plan *out);
#ifdef __cplusplus
}
#endif
#endif
