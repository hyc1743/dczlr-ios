#ifndef DC_TYPE7_H
#define DC_TYPE7_H

#include "dc_flow.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    DC_TYPE7_SUB_2P_SEX = 0,
    DC_TYPE7_SUB_2P_ORAL = 1,
    DC_TYPE7_SUB_3P_SEX = 2,
    DC_TYPE7_SUB_3P_ORAL = 3,
    DC_TYPE7_SUB_4P_SEX = 4,
    DC_TYPE7_SUB_4P_ORAL = 5,
    DC_TYPE7_SUB_5P = 6
};

enum {
    DC_TYPE7_PHASE_IDLE = 0,
    DC_TYPE7_PHASE_INSERT = 1,
    DC_TYPE7_PHASE_SLOW = 2,
    DC_TYPE7_PHASE_FAST = 3,
    DC_TYPE7_PHASE_EDGE = 4,
    DC_TYPE7_PHASE_CLIMAX_IN = 5,
    DC_TYPE7_PHASE_CLIMAX_OUT = 6,
    DC_TYPE7_PHASE_MOUTH_HOLD = 7,
    DC_TYPE7_PHASE_AFTERGLOW = 8,
    DC_TYPE7_PHASE_PAUSE_HOLD = 9,
    DC_TYPE7_PHASE_SECOND_HOLD = 10
};

enum {
    DC_TYPE7_HUB_CHARA = 1,
    DC_TYPE7_HUB_FUKU = 2,
    DC_TYPE7_HUB_CAM = 3,
    DC_TYPE7_HUB_SYS = 4
};

enum {
    DC_TYPE7_FADE_NONE = 0,
    DC_TYPE7_FADE_SWAP = 1,
    DC_TYPE7_FADE_EXIT = 2,
    DC_TYPE7_FADE_CONFIG = 3,
    DC_TYPE7_FADE_SAVE = 4
};

enum {
    DC_TYPE7_MAX_BODIES = 4,
    DC_TYPE7_MAX_HEADS = 3,
    DC_TYPE7_MAX_MENU_ITEMS = 7,
    DC_TYPE7_MAX_CHAINS = 16,
    DC_TYPE7_MAX_LOOPS = 8,
    DC_TYPE7_NAME_CAP = 32
};

typedef struct dc_type7_assets {
    char body_archive[DC_TYPE7_NAME_CAP];
    uint8_t body_count;
    char body_xx[DC_TYPE7_MAX_BODIES][DC_TYPE7_NAME_CAP];
    char body_plst[DC_TYPE7_MAX_BODIES][DC_TYPE7_NAME_CAP];
    char body_xa[DC_TYPE7_MAX_BODIES][DC_TYPE7_NAME_CAP];
    uint8_t head_count;
    uint8_t head_heroine[DC_TYPE7_MAX_HEADS];
    uint8_t head_body_index[DC_TYPE7_MAX_HEADS];
    char head_xx[DC_TYPE7_MAX_HEADS][DC_TYPE7_NAME_CAP];
    char head_xa[DC_TYPE7_MAX_HEADS][DC_TYPE7_NAME_CAP];
    char head_eyes[DC_TYPE7_MAX_HEADS][DC_TYPE7_NAME_CAP];
    char head_neck[DC_TYPE7_MAX_HEADS][DC_TYPE7_NAME_CAP];
    char char_light_xl[DC_TYPE7_NAME_CAP];
    char cam_file[DC_TYPE7_NAME_CAP];
    char anchor_primary[DC_TYPE7_NAME_CAP];
    char anchor_fallback[DC_TYPE7_NAME_CAP];
    char bgm_name[DC_TYPE7_NAME_CAP];
} dc_type7_assets;

typedef struct dc_type7_menu_item {
    char stem[16];
    uint8_t radial_pos;
    uint8_t selected;
    uint8_t action_id;
    uint8_t aux;
} dc_type7_menu_item;

typedef struct dc_type7_menu {
    uint8_t hub;
    uint8_t count;
    uint8_t target_heroine;
    uint8_t page;
    dc_type7_menu_item items[DC_TYPE7_MAX_MENU_ITEMS];
} dc_type7_menu;

typedef struct dc_type7_heroine_metrics {
    uint16_t vaginal_in_ejac;
    uint16_t anal_in_ejac;
    uint16_t out_ejac;
    uint16_t oral_in_ejac;
    uint16_t oral_out_ejac;
    uint16_t anal_penetrations;
    uint16_t heroine_climaxes;
    uint8_t posture_a_used;
    uint8_t posture_b_used;
    uint8_t caress_used;
    uint8_t stripped_flags;
    uint8_t swallowed;
    uint8_t anal_used;
    uint8_t special_event;
    uint8_t reserved;
} dc_type7_heroine_metrics;

typedef struct dc_type7_state {
    uint8_t sub_mode;
    uint8_t initial_sub_mode;
    uint8_t rig_mode;
    uint8_t map_id;
    uint8_t heroine_count;
    uint8_t slots[3];
    uint8_t conquered_mask;
    int8_t active_slot;
    uint8_t primary_heroine;
    uint8_t hole;
    uint8_t phase;
    uint8_t oral_pos;
    uint8_t oral_fast;
    uint8_t chara_page;
    uint8_t fuku_slot_cursor;
    uint8_t cam_slot_cursor;
    uint8_t gaze_mode[3];
    uint8_t cam_pivot_mode;
    uint8_t cam_target_heroine;
    uint8_t vibe_mask;
    uint8_t vibe_fast;
    uint8_t fuku_state[3][6];
    uint8_t fade_pending;
    uint8_t fade_kind;
    uint8_t pending_sub_mode;
    uint8_t pending_rig_mode;
    int8_t pending_slot;
    uint8_t pending_hole;
    uint8_t sub_style;
    uint8_t cummed_piston;
    uint8_t edge_resumed;
    uint8_t breath_tier;
    uint8_t oral_afterglow_irrumatio;
    uint32_t hold_timer_ms;
    uint32_t moan_timer_ms;
    uint32_t se_cycle_clip;
    uint8_t se_fired_in_stroke;
    float idle_anim_speed;
    float speed;
    float arousal[3];
    uint32_t voice_serial;
    dc_type7_heroine_metrics metrics[3];
} dc_type7_state;

typedef struct dc_type7_plan {
    uint8_t body_count;
    int32_t body_clip[DC_TYPE7_MAX_BODIES];
    int32_t body_next_clip[DC_TYPE7_MAX_BODIES];
    uint8_t chain_count;
    uint8_t chain_body[DC_TYPE7_MAX_CHAINS];
    uint16_t chain_from[DC_TYPE7_MAX_CHAINS];
    int16_t chain_to[DC_TYPE7_MAX_CHAINS];
    uint8_t loop_count;
    uint8_t loop_body[DC_TYPE7_MAX_LOOPS];
    uint16_t loop_clip[DC_TYPE7_MAX_LOOPS];
    int16_t loop_limit[DC_TYPE7_MAX_LOOPS];
    uint8_t reset_cam_preset;
    uint8_t update_cam_pivot;
    uint8_t start_fade;
    uint8_t fade_kind;
    uint8_t voice_heroine;
    char voice_stem[DC_TYPE7_NAME_CAP];
    char se_name[DC_TYPE7_NAME_CAP];
} dc_type7_plan;

typedef struct dc_type7_exit_outcome {
    uint8_t destination_type;
    uint8_t destination_chapter;
    uint8_t destination_stage;
    uint8_t badge_awarded;
    uint8_t badge_heroine;
    uint8_t badge_index;
    uint8_t promoted_conquest_mask;
    char exit_voice[DC_TYPE7_NAME_CAP];
} dc_type7_exit_outcome;

DC_API char dc_type7_heroine_prefix(uint8_t heroine);

/* Exact binary clip lookup tables (0x004ccd80..0x004cce60). */
DC_API int32_t dc_type7_clip_2p_sex(uint32_t row, uint32_t idx);
DC_API int32_t dc_type7_clip_2p_oral(uint32_t pos, uint32_t step);
DC_API int32_t dc_type7_clip_3p_sex(uint32_t slot, uint32_t idx);
DC_API int32_t dc_type7_clip_3p_vibe(uint32_t slot, uint32_t idx);
DC_API int32_t dc_type7_clip_3p_oral(uint32_t pos, uint32_t step);
DC_API int32_t dc_type7_clip_4p_sex(uint32_t slot, uint32_t idx);
DC_API int32_t dc_type7_clip_4p_switch(uint32_t from_slot, uint32_t to_slot);
DC_API int32_t dc_type7_clip_4p_oral(uint32_t pos, uint32_t step);

/* Initialize Scene Type 7 state with canonical slot ordering and initial clips. */
DC_API dc_status dc_type7_init(dc_type7_state *state, uint8_t initial_sub_mode,
    uint8_t map_id, uint8_t slot0, uint8_t slot1, uint8_t slot2,
    uint8_t conquered_mask, dc_type7_plan *initial_plan);

/* Resolve archives, body/head models, animations, light, camera and map anchor. */
DC_API dc_status dc_type7_resolve_assets(const dc_type7_state *state, dc_type7_assets *out);

/* Synchronize phase when body[0]'s active clip auto-chains inside dc_model_tick. */
DC_API dc_status dc_type7_observe_clip(dc_type7_state *state, uint32_t body0_clip);

/* Advance continuous arousal/breath tiers, 10s oral hold timer, stroke SEs, and moan cadence. */
DC_API dc_status dc_type7_tick(dc_type7_state *state, uint32_t dt_ms,
    uint32_t body0_clip, float clip_progress, dc_type7_plan *out_events);

/* Scale playback speed across [0.5f, 3.0f] (0x004c9320). */
DC_API dc_status dc_type7_adjust_speed(dc_type7_state *state, float delta);

/* Build radial action/clothing/camera/system menus for the current Type 7 state. */
DC_API dc_status dc_type7_build_menu(const dc_type7_state *state, uint8_t hub, dc_type7_menu *out);

/* Handle right-click while a radial hub is open. Sets *consumed = 1 when paging/cycling
 * (2P P_chara page 0..2, 3P P_fuku heroine 0..1, 3P/4P P_cam heroine), 0 if menu should close. */
DC_API dc_status dc_type7_right_click_menu(dc_type7_state *state, uint8_t hub, uint8_t *consumed);

/* Execute a radial menu item selection and produce the resulting clip/fade/voice/cam plan. */
DC_API dc_status dc_type7_select_menu_item(dc_type7_state *state, uint8_t hub,
    uint8_t item_index, dc_type7_plan *out);

/* Complete a pending in-scene fade swap (sub_mode / rig_mode / 4P non-adjacent slot). */
DC_API dc_status dc_type7_complete_fade(dc_type7_state *state, dc_type7_plan *out);

/* Choose a contextual voice stem for the current sub_mode, phase and accessory state. */
DC_API dc_status dc_type7_voice_stem(dc_type7_state *state, uint8_t *out_heroine,
    char out_stem[DC_TYPE7_NAME_CAP]);

/* Commit session counters, 9-badge evaluation (0x00552ce0), conquest promotion,
 * oral/anal flags (0x0047d000), menstrual init (2P/5P only), and cycle advance (0x0047d2d0). */
DC_API dc_status dc_type7_commit_exit(const dc_type7_state *state, dc_flow_state *flow,
    dc_type7_exit_outcome *out);

#ifdef __cplusplus
}
#endif

#endif
