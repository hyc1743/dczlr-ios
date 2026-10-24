#ifndef DC_GAMEPLAY_H
#define DC_GAMEPLAY_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dc_game_player { float x,z,min_x,max_x,min_z,max_z,speed; uint32_t interaction_count; } dc_game_player;
typedef struct dc_game_input { float axis_x,axis_z; uint32_t touching; } dc_game_input;
#define DC_GAME_PLAYER_SAVE_BYTES 32u
DC_API dc_status dc_game_player_step(const dc_game_player *state,const dc_game_input *input,
    float delta_seconds,dc_game_player *out);
DC_API dc_status dc_game_player_save(const dc_game_player *state,void *bytes,size_t length);
DC_API dc_status dc_game_player_load(const void *bytes,size_t length,dc_game_player *out);
#ifdef __cplusplus
}
#endif
#endif
