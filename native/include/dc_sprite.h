#ifndef DC_SPRITE_H
#define DC_SPRITE_H

#include "dc_pp.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Portable reconstruction of observed sprite draw submission (0x00420e60).
 * The plan carries required state changes and a two-triangle strip submission;
 * a platform renderer must execute/translate every command in order. No GPU
 * calls occur here. Tokens are caller-owned handles, never original pointers.
 * Other render paths must invalidate cached_mode before the next sprite. */
typedef enum dc_sprite_command_kind {
    DC_SPRITE_RENDER_STATE = 1,
    DC_SPRITE_TEXTURE_STAGE = 2,
    DC_SPRITE_SAMPLER_STATE = 3,
    DC_SPRITE_SOFTWARE_VERTEX = 4,
    DC_SPRITE_TEXTURE = 5,
    DC_SPRITE_VERTEX_STREAM = 6,
    DC_SPRITE_VERTEX_FORMAT = 7,
    DC_SPRITE_DRAW = 8
} dc_sprite_command_kind;

typedef struct dc_sprite_command {
    uint32_t kind;
    uint32_t argument_count;
    uintptr_t arguments[4];
} dc_sprite_command;

typedef struct dc_sprite_draw {
    uintptr_t vertex_buffer;
    uintptr_t texture;
    uint8_t blend_mode; /* Observed modes 0..3. */
    uint8_t hidden; /* Only value 1 skips the original draw. */
    uint8_t point_filter; /* Nonzero temporarily switches min/mag to point. */
    uint8_t software_vertex; /* Original byte passed to the device, unchanged. */
} dc_sprite_draw;

#define DC_SPRITE_UNKNOWN_MODE 255u
#define DC_SPRITE_MAX_COMMANDS 17u
typedef struct dc_sprite_plan {
    uint32_t count;
    uint32_t next_mode;
    dc_sprite_command commands[DC_SPRITE_MAX_COMMANDS];
} dc_sprite_plan;

/* cached_mode is 0..3 or UNKNOWN_MODE. NULL draw is the original no-op.
 * Hidden/NULL draws preserve cached_mode. Unsupported modes fail explicitly.
 * Error leaves out unchanged. Commit next_mode only after the renderer has
 * successfully executed the complete plan; renderer errors invalidate cache.
 * This function does not establish initial depth, blend enable, alpha test,
 * texture stages beyond stage zero, or other inherited D3D state. */
DC_API dc_status dc_sprite_build_plan(const dc_sprite_draw *draw,
                                      uint32_t cached_mode, dc_sprite_plan *out);

#ifdef __cplusplus
}
#endif
#endif
