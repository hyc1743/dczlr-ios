#include "dc_animation.h"
#include <math.h>

dc_status dc_animation_set_chain(dc_animation_timing *timing,size_t count,uint32_t clip,int32_t next_clip) {
    if(!timing||!count||count>DC_ANIMATION_CLIP_LIMIT||clip>=count||(next_clip>=0&&(uint32_t)next_clip>=count))return DC_ARGUMENT;
    timing[clip].chain=next_clip>=0;
    timing[clip].next_clip=next_clip<0?0:(uint32_t)next_clip;
    return DC_OK;
}
dc_status dc_animation_set_loop(dc_animation_clip *clips,dc_animation_timing *timing,size_t count,uint32_t clip,int32_t limit) {
    if(!clips||!timing||!count||count>DC_ANIMATION_CLIP_LIMIT||clip>=count)return DC_ARGUMENT;
    clips[clip].loop=limit>=0;
    if(limit>=0)timing[clip].loop_limit=(uint8_t)limit;
    return DC_OK;
}

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

dc_status dc_animation_advance(dc_animation_state *state,
        dc_animation_clip *clips, const dc_animation_timing *timing, size_t count,
        uint32_t lane, uint32_t delta, float speed, uint32_t now, float *frame) {
    if (!state || !clips || !timing || !frame || !count ||
        count > DC_ANIMATION_CLIP_LIMIT || lane > 1 || state->current >= count)
        return DC_ARGUMENT;
    if (state->fixed_frame == 1) {
        if (!isfinite(state->frame)) return DC_RANGE;
        *frame = state->frame;
        return DC_OK;
    }
    uint32_t selected = lane ? state->pending : state->current;
    if (selected >= count) return DC_ARGUMENT;
    dc_animation_clip clip = clips[selected];
    dc_animation_timing config = timing[selected];
    float value = lane ? state->pending_frame : state->frame;
    if (!isfinite(value) || !isfinite(state->blend) || !isfinite(speed) ||
        !isfinite(config.duration_seconds) || !isfinite(clip.first_frame) ||
        !isfinite(clip.last_frame) || clip.first_frame > clip.last_frame) return DC_RANGE;

    /* x87 stores this intermediate to binary32 before the speed multiply. */
    volatile float step = config.duration_seconds == 0.0f ? 0.0f :
        (float)(((double)clip.last_frame - clip.first_frame) *
            ((double)delta / ((double)config.duration_seconds * 1000.0)));
    if (config.duration_seconds != 0.0f) step = (float)((double)step * speed);
    value = clip.reverse == 1 ? (float)((double)value - step) : (float)((double)value + step);
    if (!isfinite(step) || !isfinite(value)) return DC_RANGE;

    dc_animation_state next = *state;
    dc_animation_clip updated[DC_ANIMATION_CLIP_LIMIT];
    for (size_t i = 0; i < count; ++i) updated[i] = clips[i];
    float *position = lane ? &next.pending_frame : &next.frame;
    *position = value;
    int crossed = clip.reverse == 1 ? value < clip.first_frame : value > clip.last_frame;
    if (crossed) {
        if (state->blend < 1.0f) {
            *position = clip.reverse == 1 ? clip.first_frame : clip.last_frame;
        } else {
            int wrap = clip.loop == 1;
            int chain = config.chain == 1;
            if (chain && wrap) {
                updated[selected].iterations = (uint8_t)(clip.iterations + 1u);
                wrap = updated[selected].iterations < config.loop_limit;
            }
            if (chain && !wrap) {
                if (config.next_clip >= count) return DC_ARGUMENT;
                dc_animation_clip destination = updated[config.next_clip];
                if (!isfinite(destination.first_frame) || !isfinite(destination.last_frame) ||
                    destination.first_frame > destination.last_frame) return DC_RANGE;
                dc_status status = dc_animation_request(&next, updated, count, config.next_clip, 0, now);
                if (status != DC_OK) return status;
            } else if (wrap) {
                if (clip.first_frame == clip.last_frame) return DC_RANGE;
                uint32_t iterations = 0;
                do {
                    if (++iterations > DC_ANIMATION_WRAP_LIMIT) return DC_RANGE;
                    float previous = *position;
                    *position = clip.reverse == 1 ?
                        (float)(((double)previous - clip.first_frame) + clip.last_frame) :
                        (float)(((double)previous - clip.last_frame) + clip.first_frame);
                    if (!isfinite(*position) || *position == previous) return DC_RANGE;
                    crossed = clip.reverse == 1 ? *position < clip.first_frame : *position > clip.last_frame;
                } while (crossed);
            } else {
                *position = clip.reverse == 1 ? clip.first_frame : clip.last_frame;
            }
        }
    }
    if (!isfinite(*position)) return DC_RANGE;
    float result = *position;
    *state = next;
    for (size_t i = 0; i < count; ++i) clips[i] = updated[i];
    *frame = result;
    return DC_OK;
}

dc_status dc_animation_tick(dc_animation_state *state,
        dc_animation_clip *clips, const dc_animation_timing *timing, size_t count,
        uint32_t delta, float speed, uint32_t now, dc_animation_tick_result *result) {
    if (!state || !clips || !timing || !result || !count ||
        count > DC_ANIMATION_CLIP_LIMIT || state->current >= count ||
        (state->blend < 1.0f && state->pending >= count)) return DC_ARGUMENT;
    if (!isfinite(state->blend) || !isfinite(state->frame) ||
        (state->blend < 1.0f && !isfinite(state->pending_frame))) return DC_RANGE;
    dc_animation_state next = *state;
    dc_animation_clip updated[DC_ANIMATION_CLIP_LIMIT];
    for (size_t i = 0; i < count; ++i) updated[i] = clips[i];
    dc_animation_tick_result output = {0};
    output.previous_frame = state->frame;
    dc_status status = dc_animation_advance(&next, updated, timing, count,
        0, delta, speed, now, &output.samples[0]);
    if (status != DC_OK) return status;
    output.sample_count = 1;
    /* The branch is chosen before evaluating current, even if that getter
     * itself requests a new crossfade. */
    if (state->blend < 1.0f) {
        status = dc_animation_advance(&next, updated, timing, count,
            1, delta, speed, now, &output.samples[1]);
        if (status != DC_OK) return status;
        output.sample_count = 2;
        if (now < next.blend_end) {
            float span = (float)(uint32_t)(next.blend_end - next.blend_start);
            float elapsed = (float)(uint32_t)(now - next.blend_start);
            next.blend = span == 0.0f ? 0.0f : (float)((double)elapsed / span);
        } else {
            next.blend = 1.0f;
            next.previous = next.current;
            next.current = next.pending;
            next.pending = 0;
            next.frame = next.pending_frame;
        }
    }
    *state = next;
    for (size_t i = 0; i < count; ++i) clips[i] = updated[i];
    *result = output;
    return DC_OK;
}
