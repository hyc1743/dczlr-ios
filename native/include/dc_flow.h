#ifndef DC_FLOW_H
#define DC_FLOW_H
#include "dc_save.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_FLOW_CHAPTERS 29u
#define DC_FLOW_STAGES 3u
#define DC_FLOW_STAGE_BYTES 0x2198u

/* Canonical original main+13538 state, including unknown bytes. The existing
 * metadata name script_frame denotes original main+13534, also the type7 mode.
 * A router installs a callback; scene_type changes when its initializer runs. */
typedef struct dc_flow_state {
    uint8_t raw[DC_GAME_STATE_BYTES];
    dc_save_slot_meta meta;
} dc_flow_state;

typedef struct dc_flow_chapter {
    uint32_t callback,scene_type;
    int32_t script,last_frame;
    uint32_t map,stage;
} dc_flow_chapter;

enum {
    DC_FLOW_DEPART=1u,
    DC_FLOW_LOAD_SCRIPT=2u,
    DC_FLOW_SCRIPT_FADE=4u,
    DC_FLOW_CLEAR_SPECIAL=8u
};
typedef struct dc_flow_result {
    uint32_t callback,destination_type,flags,scheduler;
    int32_t script,last_frame;
} dc_flow_result;

/* Explicit numeric context fields, supplied only after the real scene exit
 * condition and transition readiness. No input/animation/audio is simulated.
 * type4: level=scene+18b4, flag_b=+185b, count=u16(+185e).
 * type5: level=scene+2274, flag_b=+21c2, count=u16(+21ec).
 * type6: level=scene+1a04+stage, flag_b=+187f+stage,
 * outcome_a/b=u16(+18f0/+18f2+4*stage). All values preserve unsigned bits. */
typedef struct dc_flow_exit_metrics {
    uint32_t level,flag_b,count,outcome_a,outcome_b;
} dc_flow_exit_metrics;

typedef struct dc_flow_selection {
    uint32_t category,map_index,stage_mask,first,second;
} dc_flow_selection;
typedef struct dc_flow_selector_masks {
    uint32_t disabled_categories;
    uint32_t disabled_maps[6];
    uint32_t disabled_stages[6];
} dc_flow_selector_masks;

/* Every error preserves state and outputs; outputs must not overlap state or
 * other input spans. Metadata selectors use 0xff as the original sentinel.
 * Initial metadata is caller-owned; raw initialization is exact 0050d920. */
DC_API dc_status dc_flow_state_init(dc_flow_state *out,const dc_save_slot_meta *meta);
DC_API dc_status dc_flow_chapter_profile(uint32_t chapter,dc_flow_chapter *out);
/* Exact 0047d2d0. It does not establish that a scheduler call is due. */
DC_API dc_status dc_flow_scheduler(dc_flow_state *state,uint32_t *result);
/* 0052a990/0052a430/00523380 action2, selected by meta.scene_type4/5/6. */
DC_API dc_status dc_flow_scene_exit(dc_flow_state *state,
    const dc_flow_exit_metrics *metrics,dc_flow_result *out);
/* 0047ceb0 history update at the final type6 context action, before exit.
 * Pass the original shorts at scene+18d8/+18da+8*stage. Do not commit twice. */
DC_API dc_status dc_flow_night_commit(dc_flow_state *state,uint32_t count_a,uint32_t count_b);
/* Script exhaustion and its original departure behavior, including25..28. */
DC_API dc_status dc_flow_script_finish(dc_flow_state *state,dc_flow_result *out);
/* Original type2 UI admission. stage_mask/first/second use row indices0..2,
 * which map to original stage selectors2/1/0. */
DC_API dc_status dc_flow_selector_admission(const dc_flow_state *state,dc_flow_selector_masks *out);
/* Exact 0052c230 action1 routing after actual UI admission, fade and audio
 * completion. This validates selection shape; caller enforces admission. */
DC_API dc_status dc_flow_selector_route(dc_flow_state *state,
    const dc_flow_selection *selection,dc_flow_result *out);
/* Original type13 prompt action1; row0/1 chooses chapter27/28. */
DC_API dc_status dc_flow_prompt_route(dc_flow_state *state,uint32_t row,dc_flow_result *out);

#ifdef __cplusplus
}
#endif
#endif
