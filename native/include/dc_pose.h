#ifndef DC_POSE_H
#define DC_POSE_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Serialized XA node key: quaternion 0..3, opaque 4..5, translation 6..8,
 * scale 9..11. Keep the signed timestamp first, exactly 52 bytes per record. */
typedef struct dc_pose_key { int32_t frame; float values[12]; } dc_pose_key;
typedef struct dc_pose_selection { uint32_t left, right; float weight; } dc_pose_selection;
typedef struct dc_matrix { float values[16]; } dc_matrix;
#define DC_POSE_KEY_LIMIT 1048576u

/* Original binary searches 0x412ff0/0x413080, within a bounded profile:
 * 2..DC_POSE_KEY_LIMIT nondecreasing timestamps and a finite signed-int32 frame.
 * Search uses truncation toward zero; interpolation uses the original float.
 * Timestamp subtraction wraps to signed 32 bits before rounding to binary32.
 * Numerator and weight each have their own binary32 store. No clamping.
 * All failures preserve output; source/output must not overlap. */
DC_API dc_status dc_pose_select(const dc_pose_key *keys, size_t count, float frame,
    dc_pose_selection *out);
/* Mode 0 only. Unit quaternion inputs (norm squared within .002 of one),
 * finite selected values and finite results. Fields 4/5 are not interpreted.
 * Selected weight must be within [-1,2]; unsupported extrapolation is rejected,
 * not clamped. Shortest-arc slerp; no input quaternion normalization. Matrix uses the
 * observed row-vector rotation * (scale * translation) composition.
 * This is a numeric local transform, not hierarchy, skinning or GPU output. */
DC_API dc_status dc_pose_sample(const dc_pose_key *keys, size_t count, uint32_t mode,
    float frame, dc_matrix *out);
DC_API dc_status dc_matrix_multiply(const dc_matrix *left, const dc_matrix *right, dc_matrix *out);
#ifdef __cplusplus
}
#endif
#endif
