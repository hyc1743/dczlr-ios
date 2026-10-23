#ifndef DC_ANIMATION_H
#define DC_ANIMATION_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Request/query subset of the original model animation controller. The fixed
 * table has 512 slots in the analyzed object. Loading XA records, advancing
 * frames, interpolating poses/materials and rendering remain separate work. */
#define DC_ANIMATION_CLIP_LIMIT 512u
typedef struct dc_animation_clip {
    float first_frame, last_frame;
    uint32_t blend_duration;
    uint8_t loop, iterations, reverse, reserved;
} dc_animation_clip;

typedef struct dc_animation_state {
    uint32_t previous, current, pending;
    uint32_t blend_start, blend_end;
    float blend, frame, pending_frame;
    uint8_t fixed_frame;
} dc_animation_state;

/* Reconstructed from 0x004046c0. now is the host clock's 32-bit tick value.
 * The outgoing clip's duration controls immediate switch versus crossfade.
 * A duplicate request still clears fixed_frame. Only reverse == 1 starts at
 * last_frame. Immediate switches preserve pending and blend_end. Starting a
 * crossfade resets the destination's iteration byte without committing current.
 * Invalid arguments leave state and clips unchanged. */
DC_API dc_status dc_animation_request(dc_animation_state *state,
    dc_animation_clip *clips, size_t count, uint32_t requested,
    uint8_t force, uint32_t now);

/* 0x00464ab0 reports the CURRENT clip's loop byte as a boolean. It does not
 * compare clock values or report completion of a pending blend. current may be
 * null; ready is required. Invalid arguments leave both outputs unchanged. */
DC_API dc_status dc_animation_query(const dc_animation_state *state,
    const dc_animation_clip *clips, size_t count,
    uint32_t *current, uint32_t *ready);

#ifdef __cplusplus
}
#endif
#endif
