#ifndef DC_MATERIAL_H
#define DC_MATERIAL_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_MATERIAL_COMPONENTS 17u
typedef struct dc_material_value { float components[DC_MATERIAL_COMPONENTS]; } dc_material_value;
typedef struct dc_material_key { dc_material_value value; int32_t frame; } dc_material_key;

/* Numeric interpolation from 0x00416cd0. Components 7/11/15 retain their
 * current destination values. Signed timestamps are subtracted before the
 * binary32 span store; weight is stored as binary32 before interpolation.
 * Coincident timestamps use weight zero. Extrapolation is not clamped.
 * Finite frame/selected component inputs and finite calculated results are
 * admitted. Failures leave inout unchanged. Inout may alias either key value. */
DC_API dc_status dc_material_interpolate(const dc_material_key *left,
    const dc_material_key *right, float frame, dc_material_value *inout);

/* One-track equivalent of the numeric path in 0x00416ee0. First inclusive
 * [key_i.frame,key_(i+1).frame] interval wins, preserving file order. Comparisons
 * retain signed timestamp precision instead of first rounding timestamps to
 * float. If no interval matches (including one key), copy all 17 baseline
 * values. With zero keys, leave destination unchanged as the original did.
 * Keys need not be sorted; later tracks/target binding are host operations.
 * Finite frame is required. Array length is caller-owned; count must fit an
 * original signed count. Baseline is required only for a nonempty track.
 * All failures preserve inout; no heap allocations or GPU calls. */
DC_API dc_status dc_material_sample(const dc_material_key *keys, size_t count,
    const dc_material_value *baseline, float frame, dc_material_value *inout);

#ifdef __cplusplus
}
#endif
#endif
