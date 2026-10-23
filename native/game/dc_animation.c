#include "dc_animation.h"

dc_status dc_animation_request(dc_animation_state *state,
        dc_animation_clip *clips, size_t count, uint32_t requested,
        uint8_t force, uint32_t now) {
    if (!state || !clips || !count || count > DC_ANIMATION_CLIP_LIMIT ||
        state->current >= count || requested >= count) return DC_ARGUMENT;
    dc_animation_state next = *state;
    next.fixed_frame = 0;
    uint32_t duration = clips[state->current].blend_duration;
    if ((!duration || state->pending != requested) &&
            (force || state->current != requested)) {
        next.blend_start = 0;
        next.blend = 1.0f;
        dc_animation_clip *target = &clips[requested];
        float first = target->reverse == 1 ? target->last_frame : target->first_frame;
        if (!duration) {
            next.previous = state->current;
            next.current = requested;
            next.frame = first;
        } else {
            next.pending = requested;
            next.pending_frame = first;
            next.blend = 0.0f;
            next.blend_start = now;
            next.blend_end = now + duration; /* Original modulo-2^32 addition. */
        }
        target->iterations = 0;
    }
    *state = next;
    return DC_OK;
}

dc_status dc_animation_query(const dc_animation_state *state,
        const dc_animation_clip *clips, size_t count,
        uint32_t *current, uint32_t *ready) {
    if (!state || !clips || !ready || !count ||
        count > DC_ANIMATION_CLIP_LIMIT || state->current >= count) return DC_ARGUMENT;
    uint32_t selected = state->current;
    uint32_t result = clips[selected].loop != 0;
    if (current) *current = selected;
    *ready = result;
    return DC_OK;
}
