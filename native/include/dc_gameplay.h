#ifndef DC_GAMEPLAY_H
#define DC_GAMEPLAY_H
#include "dc_pp.h"
#include "dc_menu.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dc_game_player { float x,z,min_x,max_x,min_z,max_z,speed; uint32_t interaction_count,map_selector; } dc_game_player;
typedef struct dc_game_input { float axis_x,axis_z; uint32_t touching; } dc_game_input;
typedef struct dc_game_interaction_state {
    uint32_t interaction_count, start_tick;
    uint32_t active, completed;
} dc_game_interaction_state;
typedef struct dc_game_interaction_input {
    uint32_t tick, new_touch, near_target;
} dc_game_interaction_input;
typedef struct dc_game_interaction_result {
    uint32_t begin, restore, completed;
} dc_game_interaction_result;
typedef enum dc_game_menu_event_kind {
    DC_GAME_MENU_EVENT_MISS = 0,
    DC_GAME_MENU_EVENT_OTHER = 1,
    DC_GAME_MENU_EVENT_TOUCH = 2,
    DC_GAME_MENU_EVENT_FINISH = 3
} dc_game_menu_event_kind;
typedef struct dc_game_menu_activate_input {
    uint32_t scene_type;         /* original 0x1352d byte; 4 = gameplay scene */
    uint32_t selected_row;       /* UINT32_MAX when the pointer missed */
    uint32_t interaction_count;  /* original scene-context +0xc94 counter */
    uint32_t press_edge;         /* original button state 3 */
    uint32_t release_edge;       /* original button state 2 */
} dc_game_menu_activate_input;
typedef struct dc_game_menu_activate_state {
    uint32_t toggle_active;      /* original action +0x2c flag */
} dc_game_menu_activate_state;
typedef struct dc_game_menu_activate_result {
    uint32_t handled;            /* original 0x00532240 returned nonzero */
    uint32_t stay;               /* 1 keep scene, 2 exit to chapter end */
    uint32_t kind;               /* dc_game_menu_event_kind */
} dc_game_menu_activate_result;
#define DC_GAME_PLAYER_SAVE_BYTES 32u
#define DC_GAME_MAP_SEQUENCE_COUNT 8u
#define DC_GAME_INTERACTION_DELAY_MS 800u
#define DC_GAME_MENU_COUNT 6u
#define DC_GAME_STORY_MAP_TABLE_COUNT 22u
DC_API dc_status dc_game_player_step(const dc_game_player *state,const dc_game_input *input,
    float delta_seconds,dc_game_player *out);
DC_API dc_status dc_game_player_save(const dc_game_player *state,void *bytes,size_t length);
DC_API dc_status dc_game_player_load(const void *bytes,size_t length,dc_game_player *out);
/* Real chapter-3 map chain observed by the local resource audit. The final
 * selector returns itself with finished=1; invalid selectors leave outputs. */
DC_API dc_status dc_game_next_map_selector(uint32_t current,uint32_t *next,uint32_t *finished);
/* Static table recovered from 0x0052bcf0/0x00598a50. Story states without a
 * map use 0xff and return DC_NOT_FOUND without modifying selector. */
DC_API dc_status dc_game_story_map_selector(uint32_t story_state,uint32_t *selector);
/* Six-row chapter-3 gameplay menu captured from the original runtime. The
 * coordinates are logical 1024x768 values; callers pass the observed window
 * scale to dc_menu_step. Row 2 is disabled in the admitted state. */
DC_API dc_status dc_game_menu_profile(dc_menu_button *buttons,size_t capacity);
DC_API dc_status dc_game_interaction_step(const dc_game_interaction_state *state,
    const dc_game_interaction_input *input,dc_game_interaction_state *out,
    dc_game_interaction_result *result);
/* Shared row-activation dispatch from original 0x00532240, chapter type 4
 * branch. Row 4 plays the finish event, row 2 the touch event, rows 1/3/5
 * the alternate event; a row-1 activation only keeps the scene when the
 * interaction counter exceeds one. A missed press keeps the scene without
 * an event. The release edge clears the armed toggle flag. */
DC_API dc_status dc_game_menu_activate(const dc_game_menu_activate_input *input,
    dc_game_menu_activate_state *state,dc_game_menu_activate_result *result);
#ifdef __cplusplus
}
#endif
#endif
