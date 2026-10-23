#include "dc_pose.h"
#include <math.h>
#include <limits.h>
#include <string.h>

static int overlaps(const void *a, size_t al, const void *b, size_t bl) {
    uintptr_t aa = (uintptr_t)a, bb = (uintptr_t)b;
    return al && bl && (aa <= bb ? bb - aa < al : aa - bb < bl);
}
dc_status dc_pose_select(const dc_pose_key *keys, size_t count, float frame, dc_pose_selection *out) {
    if (!keys || !out || count < 2 || count > DC_POSE_KEY_LIMIT || count > SIZE_MAX / sizeof(*keys)) return DC_ARGUMENT;
    if (overlaps(keys, count * sizeof(*keys), out, sizeof(*out))) return DC_ARGUMENT;
    if (!isfinite(frame) || (double)frame < INT32_MIN || (double)frame >= 2147483648.0) return DC_RANGE;
    for (size_t i = 1; i < count; ++i) if (keys[i].frame < keys[i-1].frame) return DC_RANGE;
    int32_t target = (int32_t)frame;
    uint32_t low = 0, high = (uint32_t)count - 1, left;
    for (;;) {
        uint32_t mid = low + (high - low) / 2;
        if (low + 1 == high) { left = low; break; }
        if (keys[mid].frame == target) { left = mid; break; }
        if (target < keys[mid].frame) high = mid;
        else low = mid;
    }
    low = 0; high = (uint32_t)count - 1;
    while (low + 1 != high) {
        uint32_t mid = low + (high - low) / 2;
        if (target < keys[mid].frame) high = mid;
        else low = mid;
    }
    uint32_t bits = (uint32_t)keys[high].frame - (uint32_t)keys[left].frame;
    int32_t difference;
    memcpy(&difference, &bits, sizeof(difference));
    float span = (float)difference;
    float numerator = (float)((double)frame - keys[left].frame);
    float weight = span == 0 ? 0 : numerator / span;
    if (!isfinite(weight)) return DC_RANGE;
    *out = (dc_pose_selection){left, high, weight};
    return DC_OK;
}

dc_status dc_matrix_multiply(const dc_matrix *left, const dc_matrix *right, dc_matrix *out) {
    if (!left || !right || !out) return DC_ARGUMENT;
    dc_matrix result;
    for (unsigned r = 0; r < 4; ++r) for (unsigned c = 0; c < 4; ++c) {
        float sum = 0;
        for (unsigned k = 0; k < 4; ++k) {
            float a = left->values[r*4+k], b = right->values[k*4+c];
            if (!isfinite(a) || !isfinite(b)) return DC_RANGE;
            volatile float product = a * b;
            sum += product;
        }
        if (!isfinite(sum)) return DC_RANGE;
        result.values[r*4+c] = sum;
    }
    *out = result;
    return DC_OK;
}

dc_status dc_pose_sample(const dc_pose_key *keys, size_t count, uint32_t mode, float frame, dc_matrix *out) {
    if (!out) return DC_ARGUMENT;
    if (mode != 0) return DC_FORMAT;
    dc_pose_selection selected;
    dc_status status = dc_pose_select(keys, count, frame, &selected);
    if (status != DC_OK) return status;
    if (overlaps(keys, count * sizeof(*keys), out, sizeof(*out))) return DC_ARGUMENT;
    if (selected.weight < -1 || selected.weight > 2) return DC_RANGE;
    const float *a = keys[selected.left].values, *b = keys[selected.right].values;
    double dot = 0, an = 0, bn = 0;
    for (unsigned i = 0; i < 12; ++i) {
        if (i == 4 || i == 5) continue;
        if (!isfinite(a[i]) || !isfinite(b[i])) return DC_RANGE;
        if (i < 4) { dot += (double)a[i]*b[i]; an += (double)a[i]*a[i]; bn += (double)b[i]*b[i]; }
    }
    if (fabs(an-1) > .002 || fabs(bn-1) > .002) return DC_RANGE;
    double sign = dot < 0 ? -1 : 1;
    dot = fabs(dot);
    double wa = 1.0 - selected.weight, wb = selected.weight;
    if (dot < .999999) {
        double angle = acos(dot), divisor = sin(angle);
        wa = sin(wa * angle) / divisor;
        wb = sin(wb * angle) / divisor;
    }
    float q[4], t[3], s[3];
    for (unsigned i = 0; i < 4; ++i) q[i] = (float)(wa*a[i] + sign*wb*b[i]);
    for (unsigned i = 0; i < 3; ++i) {
        volatile double td = (double)b[i+6] - a[i+6], sd = (double)b[i+9] - a[i+9];
        volatile double tp = td * selected.weight, sp = sd * selected.weight;
        t[i] = (float)(tp + a[i+6]); s[i] = (float)(sp + a[i+9]);
    }
    float x=q[0], y=q[1], z=q[2], w=q[3];
    dc_matrix rotation = {{1-2*(y*y+z*z), 2*(x*y+z*w), 2*(x*z-y*w), 0,
        2*(x*y-z*w), 1-2*(x*x+z*z), 2*(y*z+x*w), 0,
        2*(x*z+y*w), 2*(y*z-x*w), 1-2*(x*x+y*y), 0, 0,0,0,1}};
    dc_matrix scaling = {{s[0],0,0,0, 0,s[1],0,0, 0,0,s[2],0, 0,0,0,1}};
    dc_matrix translation = {{1,0,0,0, 0,1,0,0, 0,0,1,0, t[0],t[1],t[2],1}}, st, result;
    status = dc_matrix_multiply(&scaling, &translation, &st);
    if (status == DC_OK) status = dc_matrix_multiply(&rotation, &st, &result);
    if (status == DC_OK) *out = result;
    return status;
}
