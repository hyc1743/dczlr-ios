#include "dc_material.h"
#include <math.h>
#include <limits.h>

static int selected(uint32_t component) {
    return component != 7 && component != 11 && component != 15;
}

dc_status dc_material_interpolate(const dc_material_key *left,
        const dc_material_key *right, float frame, dc_material_value *inout) {
    if (!left || !right || !inout) return DC_ARGUMENT;
    if (!isfinite(frame)) return DC_RANGE;
    float span = (float)((double)right->frame - (double)left->frame);
    float weight = span == 0.0f ? 0.0f : (float)(((double)frame - left->frame) / span);
    if (!isfinite(weight)) return DC_RANGE;
    dc_material_value value = *inout;
    for (uint32_t i = 0; i < DC_MATERIAL_COMPONENTS; ++i) {
        if (!selected(i)) continue;
        float a = left->value.components[i], b = right->value.components[i];
        if (!isfinite(a) || !isfinite(b)) return DC_RANGE;
        /* Keep the original non-fused multiply/add boundaries. Volatile
         * binary64 intermediates also prohibit contraction on ARM64. */
        volatile double difference = (double)b - a;
        volatile double product = difference * weight;
        value.components[i] = (float)(product + a);
        if (!isfinite(value.components[i])) return DC_RANGE;
    }
    *inout = value;
    return DC_OK;
}

dc_status dc_material_sample(const dc_material_key *keys, size_t count,
        const dc_material_value *baseline, float frame, dc_material_value *inout) {
    if (!inout || count > INT32_MAX || count > SIZE_MAX / sizeof(*keys) ||
        (count && (!keys || !baseline))) return DC_ARGUMENT;
    if (!isfinite(frame)) return DC_RANGE;
    if (!count) return DC_OK;
    for (size_t i = 0; i + 1 < count; ++i) {
        if ((double)keys[i].frame <= (double)frame && (double)frame <= (double)keys[i + 1].frame)
            return dc_material_interpolate(&keys[i], &keys[i + 1], frame, inout);
    }
    *inout = *baseline;
    return DC_OK;
}
