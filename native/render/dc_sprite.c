#include "dc_sprite.h"
#include <string.h>

static void append(dc_sprite_plan *plan, uint32_t kind, uint32_t count,
                   uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d) {
    dc_sprite_command *command = &plan->commands[plan->count++];
    command->kind = kind;
    command->argument_count = count;
    command->arguments[0] = a;
    command->arguments[1] = b;
    command->arguments[2] = c;
    command->arguments[3] = d;
}

static void stage(dc_sprite_plan *plan, uint32_t state, uint32_t value) {
    append(plan, DC_SPRITE_TEXTURE_STAGE, 3, 0, state, value, 0);
}

static void filters(dc_sprite_plan *plan, uint32_t value) {
    append(plan, DC_SPRITE_SAMPLER_STATE, 3, 0, 5, value, 0);
    append(plan, DC_SPRITE_SAMPLER_STATE, 3, 0, 6, value, 0);
}

dc_status dc_sprite_build_plan(const dc_sprite_draw *draw, uint32_t cached_mode,
                               dc_sprite_plan *out) {
    if (!out || (cached_mode > 3 && cached_mode != DC_SPRITE_UNKNOWN_MODE)) return DC_ARGUMENT;
    dc_sprite_plan plan;
    memset(&plan, 0, sizeof(plan));
    plan.next_mode = cached_mode;
    if (!draw || draw->hidden == 1) {
        *out = plan;
        return DC_OK;
    }
    if (draw->blend_mode > 3) return DC_FORMAT;
    if (cached_mode != draw->blend_mode) {
        if (cached_mode == 3) {
            stage(&plan, 1, 4);
            stage(&plan, 2, 2);
            stage(&plan, 3, 1);
            stage(&plan, 4, 1);
        }
        static const uint32_t source[] = {5, 5, 1, 5};
        static const uint32_t destination[] = {6, 2, 4, 6};
        append(&plan, DC_SPRITE_RENDER_STATE, 2, 19, source[draw->blend_mode], 0, 0);
        append(&plan, DC_SPRITE_RENDER_STATE, 2, 20, destination[draw->blend_mode], 0, 0);
        if (draw->blend_mode == 3) {
            stage(&plan, 4, 4);
            stage(&plan, 5, 2);
            stage(&plan, 6, 0);
            stage(&plan, 1, 4);
            stage(&plan, 2, 2);
            stage(&plan, 3, 0);
        }
        plan.next_mode = draw->blend_mode;
    }
    if (draw->point_filter) filters(&plan, 1);
    append(&plan, DC_SPRITE_SOFTWARE_VERTEX, 1, draw->software_vertex, 0, 0, 0);
    append(&plan, DC_SPRITE_TEXTURE, 2, 0, draw->texture, 0, 0);
    append(&plan, DC_SPRITE_VERTEX_STREAM, 4, 0, draw->vertex_buffer, 0, 32);
    append(&plan, DC_SPRITE_VERTEX_FORMAT, 1, 0x1c4, 0, 0, 0);
    append(&plan, DC_SPRITE_DRAW, 3, 5, 0, 2, 0);
    if (draw->point_filter) filters(&plan, 2);
    *out = plan;
    return DC_OK;
}
