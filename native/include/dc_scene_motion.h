#ifndef DC_SCENE_MOTION_H
#define DC_SCENE_MOTION_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_SCENE_MOTION_NO_REQUEST UINT32_MAX

/* Host-independent state for the input-driven portions of the original
 * watch/night callbacks.  The scene owns the actual model/XA controller;
 * this state only records the callback's numeric gates and requested clip. */
typedef struct dc_scene_motion_state {
    uint32_t scene_type,stage,progress,clip,phase,pointer_mode;
    uint32_t outcome_a,outcome_b;
    float metric,average_motion;
    uint32_t sample_count,last_tick;
    uint8_t release_flag,history_committed,transition_pending,completed;
} dc_scene_motion_state;

typedef struct dc_scene_motion_input {
    uint32_t tick,audio_ready;
    int32_t dx,dy,wheel;
    uint32_t left,right,middle,ctrl;
    int32_t hit_index;
} dc_scene_motion_input;

typedef struct dc_scene_motion_event {
    uint32_t request_clip,request_chain_from,request_chain_to;
    uint32_t transition_action,history_commit,completed,metric_ready;
    float metric,average_motion;
} dc_scene_motion_event;

/* Initial type-5/type-6 controller state.  No clip is invented: the caller
 * must install the returned clip through the real model/XA controller. */
DC_API dc_status dc_scene_motion_init(dc_scene_motion_state *out,
    uint32_t scene_type,uint32_t stage,uint32_t progress,uint32_t clip);

/* Character context actions recovered from 005358c0.  This is separate from
 * the visible menu geometry and from transition/audio readiness. */
DC_API dc_status dc_scene_motion_context(dc_scene_motion_state *state,
    uint32_t option,dc_scene_motion_event *out);

/* One input/update slice.  Button values use the PC latch convention
 * (3 press, 1 held, 2 release, 0 idle).  Type-5 completion requires the
 * source-backed metric and audio_ready; type-6 exit is only emitted by the
 * motion-37 context action. */
DC_API dc_status dc_scene_motion_step(const dc_scene_motion_state *state,
    const dc_scene_motion_input *input,dc_scene_motion_state *out,
    dc_scene_motion_event *event);

#ifdef __cplusplus
}
#endif
#endif
