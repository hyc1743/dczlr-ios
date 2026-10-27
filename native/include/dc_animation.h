#ifndef DC_ANIMATION_H
#define DC_ANIMATION_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Reconstructed numeric subset of the original model animation controller. The fixed
 * table has 512 slots in the analyzed object. Loading XA records,
 * interpolating poses/materials and rendering remain separate work. */
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

typedef struct dc_animation_timing {
    float duration_seconds;
    uint32_t next_clip;
    uint8_t loop_limit, chain, reserved[2];
} dc_animation_timing;

typedef struct dc_animation_tick_result {
    float previous_frame, samples[2];
    uint32_t sample_count;
} dc_animation_tick_result;

#define DC_ANIMATION_WRAP_LIMIT 4096u

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
/* Original 00404630/00404680 configuration leaves. Negative values disable
 * chaining/looping; disabling a loop preserves its iteration-limit byte.
 * Nonnegative loop limits truncate to a byte, matching the original store. */
DC_API dc_status dc_animation_set_chain(dc_animation_timing *timing,size_t count,uint32_t clip,int32_t next_clip);
DC_API dc_status dc_animation_set_loop(dc_animation_clip *clips,dc_animation_timing *timing,size_t count,uint32_t clip,int32_t limit);

/* Numeric frame getter/update reconstructed from 0x00404bd0. lane 0 advances
 * current; lane 1 advances pending. Exact fixed_frame==1 returns current frame
 * without advancing either lane. delta is the original UNSIGNED tick count.
 * The original stores a float step before multiplying by speed; that rounding
 * boundary is preserved. During a blend (<1), endpoints clamp without chaining.
 * Otherwise exact loop/chain bytes of 1 select their respective behavior.
 * Loop counters wrap as bytes; crossing an endpoint increments once per call,
 * including when one update wraps multiple spans. Chaining invokes the same
 * request operation above. Blend promotion/pose sampling are not performed here.
 * Finite inputs with first<=last are admitted. Invalid/nonfinite inputs,
 * out-of-range chains and wrapping that cannot progress or exceeds WRAP_LIMIT
 * fail atomically: state, clips and frame remain unchanged. The iteration limit
 * bounds the original potentially unbounded loop without using a different
 * arithmetic formula. frame must not overlap state/clips/timing. */
DC_API dc_status dc_animation_advance(dc_animation_state *state,
    dc_animation_clip *clips, const dc_animation_timing *timing, size_t count,
    uint32_t lane, uint32_t delta, float speed, uint32_t now, float *frame);

/* Numeric update order from the animated-track path of 0x00405670. Evaluates
 * current once, or current then pending while initially blending. After both
 * samples it updates blend progress or promotes pending, using the original
 * unsigned now<blend_end comparison (not a replacement wrap-safe clock rule).
 * The numerator and denominator are separately rounded to float before division.
 * Result records the old current frame and evaluated sample order. Pose/root/
 * material/morph/event/visibility operations are outside this API. Empty or
 * missing animation tracks are a separate host boundary. Invalid input or any
 * failed advancement leaves all outputs unchanged. Result must not overlap
 * state, clips or timing. */
DC_API dc_status dc_animation_tick(dc_animation_state *state,
    dc_animation_clip *clips, const dc_animation_timing *timing, size_t count,
    uint32_t delta, float speed, uint32_t now, dc_animation_tick_result *result);

#ifdef __cplusplus
}
#endif
#endif
