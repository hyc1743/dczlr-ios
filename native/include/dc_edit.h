#ifndef DC_EDIT_H
#define DC_EDIT_H

#include "dc_pp.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    DC_EDIT_HEROINE_AOI = 0,
    DC_EDIT_HEROINE_YUKO = 1,
    DC_EDIT_HEROINE_MANAKA = 2
};

enum {
    DC_EDIT_TAB_CHARA = 0,
    DC_EDIT_TAB_MOTION = 1,
    DC_EDIT_TAB_LOAD = 2,
    DC_EDIT_TAB_SAVE_AS = 3
};

enum {
    DC_EDIT_MODE_1P_RESIST = 0,
    DC_EDIT_MODE_2P_KIRYU = 1,
    DC_EDIT_MODE_2P_SUB = 2,
    DC_EDIT_MODE_3P = 3,
    DC_EDIT_MODE_4P = 4
};

enum {
    DC_EDIT_PARAM_NONE = -1,
    DC_EDIT_PARAM_LOOP = 0,
    DC_EDIT_PARAM_SPEED = 1,
    DC_EDIT_PARAM_HEROINE = 2,
    DC_EDIT_PARAM_HOLE = 3,
    DC_EDIT_PARAM_STRIP = 4
};

enum {
    DC_EDIT_CAUTION_NONE = 0,
    DC_EDIT_CAUTION_COMBO = 1,
    DC_EDIT_CAUTION_MAP = 2,
    DC_EDIT_CAUTION_PERSONALITY = 3,
    DC_EDIT_CAUTION_PREGNANCY = 4,
    DC_EDIT_CAUTION_VIRGIN = 5
};

enum {
    DC_EDIT_MAX_STEPS = 999,
    DC_EDIT_MOTION_COUNT = 76,
    DC_EDIT_MAX_CATALOG = 57,
    DC_EDIT_CAND_PER_PAGE = 12,
    DC_EDIT_LIST_VISIBLE = 7,
    DC_EDIT_FILE_VISIBLE = 9,
    DC_EDIT_MAX_BODIES = 4,
    DC_EDIT_MAX_HEADS = 3,
    DC_EDIT_MAX_CHAINS = 16,
    DC_EDIT_MAX_LOOPS = 8,
    DC_EDIT_NAME_CAP = 32,
    DC_EDIT_FILENAME_CAP = 64,
    DC_EDIT_EDT_HEADER_BYTES = 150,
    DC_EDIT_EDT_STEP_BYTES = 12
};

typedef struct dc_edit_step {
    int32_t cat_idx;
    int32_t motion_id;
    int32_t param1;
    int32_t param2;
} dc_edit_step;

typedef struct dc_edit_chara_ui {
    uint8_t active_mask;
    uint8_t edit_mode;
    uint8_t chara_heroine;
    uint8_t map_enabled_mask;
    uint8_t pers_enabled_mask;
    uint8_t preg_enabled_mask;
    uint8_t virgin_enabled_mask;
    uint8_t pubic_enabled;
    uint16_t badges_enabled_mask;
    uint16_t badges_locked_mask;
} dc_edit_chara_ui;

typedef struct dc_edit_motion_ui {
    uint8_t cand_count;
    uint8_t cand_page;
    uint8_t cand_page_count;
    int32_t cand_cat_idx[DC_EDIT_MAX_CATALOG];
    int32_t cand_motion_id[DC_EDIT_MAX_CATALOG];
    int8_t p1_kind;
    int8_t p2_kind;
    uint8_t speed_enabled_mask;
    uint8_t keypad_enabled;
    uint8_t heroine_enabled_mask;
    uint8_t hole_enabled_mask;
    uint8_t strip_enabled_mask;
    uint8_t can_play_or_save;
} dc_edit_motion_ui;

typedef struct dc_edit_state {
    int32_t combo_idx;
    int32_t map_idx;
    int32_t personality[3];
    int32_t pregnancy[3];
    int32_t init_cloth[3][6];
    uint8_t non_virgin[3];
    uint8_t pubic_hair[3];
    uint8_t badges[3][9];
    int32_t step_count;
    dc_edit_step steps[DC_EDIT_MAX_STEPS];

    uint8_t tab;
    uint8_t edit_mode;
    uint8_t active_mask;
    uint8_t chara_heroine;
    int32_t selected_step;
    int32_t list_scroll;
    uint8_t cand_page;
    uint8_t keypad_overwrite;

    int32_t cur_cloth[3][6];
    uint8_t cur_acc[3][2];
    uint8_t hole_occ[3][2];
    uint8_t vibe_fast;
    uint8_t pose_state;
    int32_t last_pos_motion;

    uint8_t caution_pending;
    uint8_t caution_kind;
    int32_t caution_arg1;
    int32_t caution_arg2;

    char current_filename[DC_EDIT_FILENAME_CAP];
} dc_edit_state;

typedef struct dc_edit_assets {
    uint8_t map_id;
    uint8_t edit_mode;
    char map_archive[DC_EDIT_NAME_CAP];
    char map_xx[DC_EDIT_NAME_CAP];
    char map_xl[DC_EDIT_NAME_CAP];
    char map_xa[DC_EDIT_NAME_CAP];
    char map_glare[DC_EDIT_NAME_CAP];
    char bgm_name[DC_EDIT_NAME_CAP];

    char body_archive[DC_EDIT_NAME_CAP];
    uint8_t body_count;
    char body_xx[DC_EDIT_MAX_BODIES][DC_EDIT_NAME_CAP];
    char body_plst[DC_EDIT_MAX_BODIES][DC_EDIT_NAME_CAP];
    char body_xa[DC_EDIT_MAX_BODIES][DC_EDIT_NAME_CAP];
    char body_oral_xa[DC_EDIT_NAME_CAP];
    char body_oral_xa_multi[DC_EDIT_MAX_BODIES][DC_EDIT_NAME_CAP];

    uint8_t head_count;
    uint8_t head_heroine[DC_EDIT_MAX_HEADS];
    uint8_t head_body_index[DC_EDIT_MAX_HEADS];
    uint8_t head_preg_belly[DC_EDIT_MAX_HEADS];
    uint8_t head_pubic_tex[DC_EDIT_MAX_HEADS];
    char head_xx[DC_EDIT_MAX_HEADS][DC_EDIT_NAME_CAP];
    char head_xa[DC_EDIT_MAX_HEADS][DC_EDIT_NAME_CAP];
    char head_eyes[DC_EDIT_MAX_HEADS][DC_EDIT_NAME_CAP];
    char head_neck[DC_EDIT_MAX_HEADS][DC_EDIT_NAME_CAP];

    char char_light_xl[DC_EDIT_NAME_CAP];
    char cam_file[DC_EDIT_NAME_CAP];
    char oral_cam_file[DC_EDIT_NAME_CAP];
    char anchor_primary[DC_EDIT_NAME_CAP];
    char anchor_fallback[DC_EDIT_NAME_CAP];
    char oral_anchor_primary[DC_EDIT_NAME_CAP];
    char oral_anchor_fallback[DC_EDIT_NAME_CAP];
} dc_edit_assets;

typedef struct dc_edit_step_plan {
    uint8_t finished;
    uint8_t immediate_only;
    uint8_t use_oral_rig;
    uint8_t body_count;
    int32_t body_clip[DC_EDIT_MAX_BODIES];
    int32_t body_next_clip[DC_EDIT_MAX_BODIES];
    uint8_t chain_count;
    uint8_t chain_body[DC_EDIT_MAX_CHAINS];
    uint16_t chain_from[DC_EDIT_MAX_CHAINS];
    int16_t chain_to[DC_EDIT_MAX_CHAINS];
    uint8_t loop_count;
    uint8_t loop_body[DC_EDIT_MAX_LOOPS];
    uint16_t loop_clip[DC_EDIT_MAX_LOOPS];
    int16_t loop_limit[DC_EDIT_MAX_LOOPS];
    uint8_t is_looping;
    uint32_t loop_target;
    float base_speed;
    float effective_speed;
    uint8_t cloth_changed;
    int32_t cur_cloth[3][6];
    uint8_t cur_acc[3][2];
    uint8_t update_cam_pivot;
    uint8_t cam_target_heroine;
    uint8_t voice_heroine;
    char voice_stem[DC_EDIT_NAME_CAP];
    char se_name[DC_EDIT_NAME_CAP];
} dc_edit_step_plan;

typedef struct dc_edit_player {
    int32_t cur_step;
    uint8_t edit_mode;
    uint8_t map_id;
    uint8_t pose_state;
    uint8_t active_heroine;
    int8_t active_slot;
    uint8_t hole;
    uint8_t vibe_mask;
    uint8_t vibe_fast;
    uint8_t use_oral_rig;
    uint8_t afterglow;
    uint8_t oral_pos;
    uint8_t paused;
    uint8_t ff_mode;
    uint8_t hud_hidden;
    uint8_t finished;
    uint8_t in_loop_clip;
    uint8_t is_looping;
    uint32_t loop_target;
    uint32_t loops_done;
    float base_speed;
    int32_t cur_cloth[3][6];
    uint8_t cur_acc[3][2];
    uint32_t voice_serial;
} dc_edit_player;

/* Metadata & sprite stem helpers (0x63ead8, 0x76ff88, 0x7706d0, 0x5fe7d0). */
DC_API char dc_edit_heroine_prefix(uint8_t heroine);
DC_API uint8_t dc_edit_map_id_from_index(int32_t map_idx);
DC_API int32_t dc_edit_map_index_from_id(uint8_t map_id);
DC_API dc_status dc_edit_motion_sprite_name(int32_t motion_id, uint8_t selected,
    char out_name[DC_EDIT_NAME_CAP]);
DC_API dc_status dc_edit_motion_param_kinds(int32_t motion_id, int8_t *out_p1, int8_t *out_p2);
DC_API uint8_t dc_edit_catalog_count(uint8_t edit_mode);
DC_API int32_t dc_edit_catalog_motion(uint8_t edit_mode, int32_t cat_idx);
DC_API int32_t dc_edit_catalog_index_of(uint8_t edit_mode, int32_t motion_id);
DC_API dc_status dc_edit_format_autoname(int32_t combo_idx, int32_t map_idx, uint32_t serial,
    char out_filename[DC_EDIT_FILENAME_CAP]);

/* Studio state lifecycle & .edt binary serialization (0x5f19f0, 0x5fdcb0, 0x5fe1e0). */
DC_API dc_status dc_edit_init(dc_edit_state *state);
DC_API size_t dc_edit_serialized_size(const dc_edit_state *state);
DC_API dc_status dc_edit_serialize(const dc_edit_state *state, uint8_t *out_buf,
    size_t buf_cap, size_t *out_written);
DC_API dc_status dc_edit_deserialize(dc_edit_state *state, const uint8_t *buf,
    size_t buf_len, const char *filename);

/* Chara Tab rules, lockouts & Caution modal (0x5f2cf0..0x5f6b40). */
DC_API dc_status dc_edit_build_chara_ui(const dc_edit_state *state, dc_edit_chara_ui *out);
DC_API dc_status dc_edit_select_chara_heroine(dc_edit_state *state, uint8_t heroine);
DC_API dc_status dc_edit_set_combo(dc_edit_state *state, int32_t combo_idx);
DC_API dc_status dc_edit_set_map(dc_edit_state *state, int32_t map_idx);
DC_API dc_status dc_edit_set_personality(dc_edit_state *state, uint8_t heroine, int32_t pers);
DC_API dc_status dc_edit_set_pregnancy(dc_edit_state *state, uint8_t heroine, int32_t preg);
DC_API dc_status dc_edit_set_virgin(dc_edit_state *state, uint8_t heroine, uint8_t non_virgin);
DC_API dc_status dc_edit_set_pubic_hair(dc_edit_state *state, uint8_t heroine, uint8_t pubic_hair);
DC_API dc_status dc_edit_toggle_badge(dc_edit_state *state, uint8_t heroine, uint8_t badge_idx);
DC_API dc_status dc_edit_resolve_caution(dc_edit_state *state, uint8_t confirm_yes);

/* Motion Tab playlist, candidate filtering, right-click pop & param editing (0x5f7400..0x604040). */
DC_API dc_status dc_edit_replay_state(dc_edit_state *state);
DC_API dc_status dc_edit_build_motion_ui(const dc_edit_state *state, dc_edit_motion_ui *out);
DC_API dc_status dc_edit_set_cand_page(dc_edit_state *state, uint8_t page);
DC_API dc_status dc_edit_append_candidate(dc_edit_state *state, int32_t cat_idx);
DC_API dc_status dc_edit_pop_last_step(dc_edit_state *state);
DC_API dc_status dc_edit_select_step(dc_edit_state *state, int32_t step_index);
DC_API dc_status dc_edit_scroll_list(dc_edit_state *state, int32_t delta);
DC_API dc_status dc_edit_set_speed_param(dc_edit_state *state, int32_t speed_val);
DC_API dc_status dc_edit_keypad_press(dc_edit_state *state, int32_t key);
DC_API dc_status dc_edit_set_heroine_param(dc_edit_state *state, uint8_t heroine);
DC_API dc_status dc_edit_set_hole_param(dc_edit_state *state, uint8_t hole);
DC_API dc_status dc_edit_set_strip_param(dc_edit_state *state, uint8_t strip_slot);

/* Type 12 Edit 3D Playback asset resolution & timeline runner (0x598a50..0x5e04cb). */
DC_API dc_status dc_edit_resolve_assets(const dc_edit_state *state, dc_edit_assets *out);
DC_API float dc_edit_ff_multiplier(uint8_t ff_mode);
DC_API dc_status dc_edit_player_init(dc_edit_player *player, const dc_edit_state *state,
    dc_edit_step_plan *first_plan);
DC_API dc_status dc_edit_player_on_clip_end(dc_edit_player *player, const dc_edit_state *state,
    dc_edit_step_plan *out_plan, uint8_t *out_advanced);
DC_API dc_status dc_edit_player_skip_step(dc_edit_player *player, const dc_edit_state *state,
    dc_edit_step_plan *out_plan);
DC_API dc_status dc_edit_player_toggle_pause(dc_edit_player *player);
DC_API dc_status dc_edit_player_set_ff(dc_edit_player *player, uint8_t ff_mode);
DC_API dc_status dc_edit_player_cycle_ff(dc_edit_player *player);

#ifdef __cplusplus
}
#endif

#endif
