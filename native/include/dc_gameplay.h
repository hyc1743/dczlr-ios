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
#define DC_GAME_PLAYER_SAVE_BYTES 32u
#define DC_GAME_MAP_SEQUENCE_COUNT 8u
#define DC_GAME_INTERACTION_DELAY_MS 800u
#define DC_GAME_MENU_COUNT 6u
DC_API dc_status dc_game_player_step(const dc_game_player *state,const dc_game_input *input,
    float delta_seconds,dc_game_player *out);
DC_API dc_status dc_game_player_save(const dc_game_player *state,void *bytes,size_t length);
DC_API dc_status dc_game_player_load(const void *bytes,size_t length,dc_game_player *out);
/* Real chapter-3 map chain observed by the local resource audit. The final
 * selector returns itself with finished=1; invalid selectors leave outputs. */
DC_API dc_status dc_game_next_map_selector(uint32_t current,uint32_t *next,uint32_t *finished);
/* Six-row chapter-3 gameplay menu captured from the original runtime. The
 * coordinates are logical 1024x768 values; callers pass the observed window
 * scale to dc_menu_step. Row 2 is disabled in the admitted state. */
DC_API dc_status dc_game_menu_profile(dc_menu_button *buttons,size_t capacity);
DC_API dc_status dc_game_interaction_step(const dc_game_interaction_state *state,
    const dc_game_interaction_input *input,dc_game_interaction_state *out,
    dc_game_interaction_result *result);
#ifdef __cplusplus
}
#endif
#endif
