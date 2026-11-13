#include "dc_eyeneck.h"

#include <math.h>
#include <string.h>

static int overlap(const void *a, size_t al, const void *b, size_t bl) {
    uintptr_t aa = (uintptr_t)a, bb = (uintptr_t)b;
    return al && bl && (aa <= bb ? bb - aa < al : aa - bb < bl);
}

static uint16_t little16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t little32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static float little_f32(const uint8_t *p) {
    uint32_t bits = little32(p);
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static int range_ok(size_t length, size_t offset, size_t span) {
    return offset <= length && span <= length - offset;
}

static int encoded_name_ok(const uint8_t *source, size_t length) {
    if (!length) return 0;
    for (size_t i = 0; i < length; ++i)
        if (!source[i] || source[i] == 0xffu) return 0;
    return 1;
}

static dc_status parse(const uint8_t *source, size_t length,
                       dc_eyeneck_info *info, dc_eyeneck_span spans[2]) {
    if (!source || !info) return DC_ARGUMENT;
    if (!length || source[0] != 0) return DC_FORMAT;
    size_t cursor = 1;
    if (!range_ok(length, cursor, 1)) return DC_FORMAT;
    uint32_t first_length = source[cursor++];
    if (!first_length || first_length > 64 || !range_ok(length, cursor, first_length) ||
        !encoded_name_ok(source + cursor, first_length)) return DC_FORMAT;
    spans[0] = (dc_eyeneck_span){cursor, first_length};
    cursor += first_length;
    uint32_t targets = 1;
    uint32_t kind = DC_EYENECK_NECK;
    uint32_t records = 3;
    if (range_ok(length, cursor, 1)) {
        uint32_t second_length = source[cursor];
        if (second_length && second_length <= 64 &&
            range_ok(length, cursor + 1, 1u + second_length) &&
            encoded_name_ok(source + cursor + 1, second_length)) {
            ++cursor;
            spans[1] = (dc_eyeneck_span){cursor, second_length};
            cursor += second_length;
            targets = 2;
            kind = DC_EYENECK_EYES;
            records = 5;
        }
    }
    if (!range_ok(length, cursor, 4)) return DC_FORMAT;
    uint32_t serialized_records = little32(source + cursor);
    cursor += 4;
    if (serialized_records != records || !range_ok(length, cursor, 4) ||
        memcmp(source + cursor, "\x04pvu", 4) != 0) return DC_FORMAT;
    size_t expected = kind == DC_EYENECK_EYES ? 326u : 197u;
    if (length != expected || cursor > length) return DC_FORMAT;
    dc_eyeneck_info next = {kind, targets, records, cursor, length};
    *info = next;
    return DC_OK;
}

dc_status dc_eyeneck_probe(const void *source, size_t length,
                           dc_eyeneck_info *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_eyeneck_span spans[2];
    return parse((const uint8_t *)source, length, out, spans);
}

dc_status dc_eyeneck_target_at(const void *source, size_t length,
                               uint32_t index, dc_eyeneck_span *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_eyeneck_info info;
    dc_eyeneck_span spans[2];
    dc_status status = parse((const uint8_t *)source, length, &info, spans);
    if (status != DC_OK) return status;
    if (index >= info.targets) return DC_RANGE;
    *out = spans[index];
    return DC_OK;
}

dc_status dc_eyeneck_slot_at(const void *source, size_t length,
                             uint32_t record_index, dc_eyeneck_slot *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    const uint8_t *bytes = (const uint8_t *)source;
    dc_eyeneck_info info;
    dc_eyeneck_span spans[2];
    dc_status status = parse(bytes, length, &info, spans);
    if (status != DC_OK) return status;
    if (record_index >= info.records) return DC_RANGE;
    /* Note: parse() read uint32_t at cursor-4 because record 0's slot_index (uint16_t) == 0!
     * Record 0's slot_index actually starts 2 bytes before info.body_offset. */
    size_t cursor = info.body_offset - 2u;
    dc_eyeneck_slot parsed = {0};
    for (uint32_t r = 0; r <= record_index; ++r) {
        if (!range_ok(length, cursor, 3u)) return DC_FORMAT;
        uint16_t slot_idx = little16(bytes + cursor);
        uint8_t label_len = bytes[cursor + 2u];
        cursor += 3u;
        if (!label_len || label_len > 64u || !range_ok(length, cursor, (size_t)label_len + 48u))
            return DC_FORMAT;
        dc_eyeneck_span label = {cursor, label_len};
        cursor += label_len;
        const uint8_t *p = bytes + cursor;
        cursor += 48u;
        float max_yaw = little_f32(p + 4);
        float max_pitch = little_f32(p + 8);
        float weight = little_f32(p + 20);
        float param_a = little_f32(p + 24);
        float param_b = little_f32(p + 28);
        if (!isfinite(max_yaw) || !isfinite(max_pitch) || !isfinite(weight) ||
            !isfinite(param_a) || !isfinite(param_b)) return DC_FORMAT;
        parsed.slot_index = slot_idx;
        parsed.label = label;
        parsed.behavior_mode = little32(p + 0);
        parsed.max_yaw_rad = max_yaw;
        parsed.max_pitch_rad = max_pitch;
        parsed.interp_ms = little32(p + 12);
        parsed.reserved = little32(p + 16);
        parsed.weight = weight;
        parsed.param_a = param_a;
        parsed.param_b = param_b;
        parsed.timers_ms[0] = little32(p + 32);
        parsed.timers_ms[1] = little32(p + 36);
        parsed.timers_ms[2] = little32(p + 40);
        parsed.timers_ms[3] = little32(p + 44);
    }
    *out = parsed;
    return DC_OK;
}

static dc_matrix identity_matrix(void) {
    dc_matrix m = {{
        1.f, 0.f, 0.f, 0.f,
        0.f, 1.f, 0.f, 0.f,
        0.f, 0.f, 1.f, 0.f,
        0.f, 0.f, 0.f, 1.f
    }};
    return m;
}

static dc_matrix rot_x_matrix(float rad) {
    float c = cosf(rad), s = sinf(rad);
    dc_matrix m = {{
        1.f, 0.f, 0.f, 0.f,
        0.f,   c,   s, 0.f,
        0.f,  -s,   c, 0.f,
        0.f, 0.f, 0.f, 1.f
    }};
    return m;
}

static dc_matrix rot_y_matrix(float rad) {
    float c = cosf(rad), s = sinf(rad);
    dc_matrix m = {{
          c, 0.f,  -s, 0.f,
        0.f, 1.f, 0.f, 0.f,
          s, 0.f,   c, 0.f,
        0.f, 0.f, 0.f, 1.f
    }};
    return m;
}

static void quat_from_matrix(const dc_matrix *m, float q[4]) {
    const float *v = m->values;
    float tr = v[0] + v[5] + v[10];
    if (tr > 0.f) {
        float s = sqrtf(tr + 1.f) * 2.f;
        q[3] = 0.25f * s;
        q[0] = (v[6] - v[9]) / s;
        q[1] = (v[8] - v[2]) / s;
        q[2] = (v[1] - v[4]) / s;
    } else if (v[0] > v[5] && v[0] > v[10]) {
        float s = sqrtf(1.f + v[0] - v[5] - v[10]) * 2.f;
        q[3] = (v[6] - v[9]) / s;
        q[0] = 0.25f * s;
        q[1] = (v[1] + v[4]) / s;
        q[2] = (v[8] + v[2]) / s;
    } else if (v[5] > v[10]) {
        float s = sqrtf(1.f + v[5] - v[0] - v[10]) * 2.f;
        q[3] = (v[8] - v[2]) / s;
        q[0] = (v[1] + v[4]) / s;
        q[1] = 0.25f * s;
        q[2] = (v[6] + v[9]) / s;
    } else {
        float s = sqrtf(1.f + v[10] - v[0] - v[5]) * 2.f;
        q[3] = (v[1] - v[4]) / s;
        q[0] = (v[8] + v[2]) / s;
        q[1] = (v[6] + v[9]) / s;
        q[2] = 0.25f * s;
    }
    float len = sqrtf(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
    if (len > 1e-6f) {
        for (int i = 0; i < 4; ++i) q[i] /= len;
    } else {
        q[0] = q[1] = q[2] = 0.f;
        q[3] = 1.f;
    }
}

static dc_matrix matrix_from_quat(const float q[4]) {
    float x = q[0], y = q[1], z = q[2], w = q[3];
    float xx = x * x, yy = y * y, zz = z * z;
    float xy = x * y, xz = x * z, yz = y * z;
    float wx = w * x, wy = w * y, wz = w * z;
    dc_matrix m = {{
        1.f - 2.f * (yy + zz), 2.f * (xy + wz),       2.f * (xz - wy),       0.f,
        2.f * (xy - wz),       1.f - 2.f * (xx + zz), 2.f * (yz + wx),       0.f,
        2.f * (xz + wy),       2.f * (yz - wx),       1.f - 2.f * (xx + yy), 0.f,
        0.f,                   0.f,                   0.f,                   1.f
    }};
    return m;
}

static void quat_slerp(const float a[4], const float b_in[4], float t, float out[4]) {
    float b[4] = {b_in[0], b_in[1], b_in[2], b_in[3]};
    float dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3];
    if (dot < 0.f) {
        dot = -dot;
        for (int i = 0; i < 4; ++i) b[i] = -b[i];
    }
    float s0, s1;
    if (dot > 0.9995f) {
        s0 = 1.f - t;
        s1 = t;
    } else {
        float omega = acosf(fminf(1.f, dot));
        float inv_sin = 1.f / sinf(omega);
        s0 = sinf((1.f - t) * omega) * inv_sin;
        s1 = sinf(t * omega) * inv_sin;
    }
    for (int i = 0; i < 4; ++i) out[i] = s0 * a[i] + s1 * b[i];
    float len = sqrtf(out[0]*out[0] + out[1]*out[1] + out[2]*out[2] + out[3]*out[3]);
    if (len > 1e-6f) {
        for (int i = 0; i < 4; ++i) out[i] /= len;
    } else {
        out[0] = out[1] = out[2] = 0.f;
        out[3] = 1.f;
    }
}

static int transform_world_to_bone_local(const dc_matrix *bone_world,
                                         const float target_world[3],
                                         float local_out[3]) {
    const float *m = bone_world->values;
    /* Row-vector affine inverse: p_world = p_local * R + T => p_local = (p_world - T) * M_3x3^{-1}. */
    float dx = target_world[0] - m[12];
    float dy = target_world[1] - m[13];
    float dz = target_world[2] - m[14];
    float a00 = m[0], a01 = m[1], a02 = m[2];
    float a10 = m[4], a11 = m[5], a12 = m[6];
    float a20 = m[8], a21 = m[9], a22 = m[10];
    float c00 = a11 * a22 - a12 * a21;
    float c01 = -(a01 * a22 - a02 * a21);
    float c02 = a01 * a12 - a02 * a11;
    float c10 = -(a10 * a22 - a12 * a20);
    float c11 = a00 * a22 - a02 * a20;
    float c12 = -(a00 * a12 - a02 * a10);
    float c20 = a10 * a21 - a11 * a20;
    float c21 = -(a00 * a21 - a01 * a20);
    float c22 = a00 * a11 - a01 * a10;
    float det = a00 * c00 + a10 * c01 + a20 * c02;
    if (!isfinite(det) || fabsf(det) < 1e-8f) return 0;
    float inv_det = 1.f / det;
    local_out[0] = (dx * c00 + dy * c10 + dz * c20) * inv_det;
    local_out[1] = (dx * c01 + dy * c11 + dz * c21) * inv_det;
    local_out[2] = (dx * c02 + dy * c12 + dz * c22) * inv_det;
    return isfinite(local_out[0]) && isfinite(local_out[1]) && isfinite(local_out[2]);
}

void dc_eyeneck_controller_init(dc_eyeneck_controller *ctrl) {
    if (!ctrl) return;
    memset(ctrl, 0, sizeof(*ctrl));
    ctrl->q_start[3] = 1.f;
    ctrl->q_current[3] = 1.f;
    ctrl->avert_sign = 1.f;
    ctrl->saccade_limit_ms = 600u;
}

void dc_eyeneck_controller_set_slot(dc_eyeneck_controller *ctrl,
                                    const dc_eyeneck_slot *slot) {
    if (!ctrl || !slot) return;
    int changed = (ctrl->active.slot_index != slot->slot_index ||
                   ctrl->active.behavior_mode != slot->behavior_mode);
    ctrl->active = *slot;
    if (changed) {
        memcpy(ctrl->q_start, ctrl->q_current, sizeof(ctrl->q_start));
        ctrl->blend_elapsed_ms = 0u;
    }
}

dc_status dc_eyeneck_controller_step(dc_eyeneck_controller *ctrl,
                                     const dc_matrix *bone_world,
                                     const float target_world[3],
                                     float convergence_x,
                                     uint32_t delta_ms,
                                     dc_matrix *out_extra) {
    if (!ctrl || !bone_world || !target_world || !out_extra) return DC_ARGUMENT;
    for (unsigned i = 0; i < 3; ++i)
        if (!isfinite(target_world[i])) return DC_RANGE;
    if (!isfinite(convergence_x)) return DC_RANGE;

    dc_matrix r_goal = identity_matrix();
    uint32_t mode = ctrl->active.behavior_mode;
    if (mode == 7u || mode == 5u) {
        float v[3];
        if (transform_world_to_bone_local(bone_world, target_world, v)) {
            float d = sqrtf(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
            if (d > 1e-5f) {
                v[0] += convergence_x / d;
            }
            float w = fmaxf(0.f, fminf(1.f, ctrl->active.weight > 0.f ? ctrl->active.weight : 1.f));
            float yaw = 0.f;
            float pitch = 0.f;
            if (mode == 7u) {
                float raw_yaw = atan2f(v[0], v[2]) * w;
                float lim_y = fabsf(ctrl->active.max_yaw_rad);
                yaw = fmaxf(-lim_y, fminf(lim_y, raw_yaw));
                float vz_yaw = v[0] * sinf(yaw) + v[2] * cosf(yaw);
                float raw_pitch = -atan2f(v[1], vz_yaw) * w;
                float lim_p = fabsf(ctrl->active.max_pitch_rad);
                pitch = fmaxf(-lim_p, fminf(lim_p, raw_pitch));
            } else {
                ctrl->saccade_timer_ms += delta_ms;
                uint32_t min_t = ctrl->active.timers_ms[0] ? ctrl->active.timers_ms[0] : 400u;
                uint32_t max_t = ctrl->active.timers_ms[1] > min_t ? ctrl->active.timers_ms[1] : (min_t + 400u);
                if (ctrl->saccade_timer_ms >= ctrl->saccade_limit_ms) {
                    ctrl->saccade_timer_ms = 0u;
                    ctrl->saccade_limit_ms = min_t + ((ctrl->saccade_limit_ms * 1103515245u + 12345u) % (max_t - min_t + 1u));
                    ctrl->avert_sign = (v[0] >= 0.f) ? -1.f : 1.f;
                    memcpy(ctrl->q_start, ctrl->q_current, sizeof(ctrl->q_start));
                    ctrl->blend_elapsed_ms = 0u;
                }
                float lim_y = fabsf(ctrl->active.max_yaw_rad);
                float lim_p = fabsf(ctrl->active.max_pitch_rad);
                float ay = (ctrl->active.param_a > 0.f ? ctrl->active.param_a : lim_y) * ctrl->avert_sign * w;
                float ap = fabsf(ctrl->active.param_b > 0.f ? ctrl->active.param_b : lim_p) * w;
                yaw = fmaxf(-lim_y, fminf(lim_y, ay));
                pitch = fmaxf(-lim_p, fminf(lim_p, ap));
            }
            dc_matrix rx = rot_x_matrix(pitch);
            dc_matrix ry = rot_y_matrix(yaw);
            dc_matrix_multiply(&rx, &ry, &r_goal);
        }
    }

    float q_goal[4];
    quat_from_matrix(&r_goal, q_goal);
    uint32_t interp = ctrl->active.interp_ms ? ctrl->active.interp_ms : 500u;
    if (ctrl->blend_elapsed_ms < interp) {
        uint32_t next_ms = ctrl->blend_elapsed_ms + delta_ms;
        ctrl->blend_elapsed_ms = next_ms > interp ? interp : next_ms;
        float t = (float)ctrl->blend_elapsed_ms / (float)interp;
        quat_slerp(ctrl->q_start, q_goal, t, ctrl->q_current);
    } else {
        float track_t = delta_ms == 0u ? 1.f : fminf(1.f, (float)delta_ms / 90.f);
        quat_slerp(ctrl->q_current, q_goal, track_t, ctrl->q_current);
    }
    *out_extra = matrix_from_quat(ctrl->q_current);
    return DC_OK;
}

void dc_eyeneck_tremor_init(dc_eyeneck_tremor_state *state) {
    if (!state) return;
    state->accum_ms = 0u;
    state->sign = 1.f;
}

dc_status dc_eyeneck_tremor_step(dc_eyeneck_tremor_state *state,
                                 uint32_t delta_ms,
                                 float arousal,
                                 uint32_t force_max,
                                 dc_matrix *out_extra) {
    if (!state || !out_extra || !isfinite(arousal)) return DC_ARGUMENT;
    if (state->sign == 0.f) state->sign = 1.f;
    state->accum_ms += delta_ms;
    if (state->accum_ms > 34u) {
        state->sign = -state->sign;
        state->accum_ms = 0u;
    }
    float deg = 0.f;
    if (force_max) {
        deg = 3.0f * state->sign;
    } else if (arousal >= 49.0f) {
        float clamped = fminf(50.0f, arousal - 49.0f);
        deg = (3.0f * (clamped / 50.0f)) * state->sign;
    }
    *out_extra = rot_y_matrix(deg * 0.0174532925f);
    return DC_OK;
}

void dc_spring_node_init(dc_spring_node_state *state) {
    if (state) memset(state, 0, sizeof(*state));
}

static dc_status spring_step_params(dc_spring_node_state *state,
                                    const dc_matrix *bone_world,
                                    uint32_t delta_ms,
                                    float ks,
                                    float kd,
                                    float max_r,
                                    float max_ang,
                                    uint32_t locked,
                                    dc_matrix *out_extra) {
    if (!state || !bone_world || !out_extra) return DC_ARGUMENT;
    if (locked) {
        state->initialized = 0;
        *out_extra = identity_matrix();
        return DC_OK;
    }
    const float *m = bone_world->values;
    float cur_pos[3] = {m[12], m[13], m[14]};
    if (!isfinite(cur_pos[0]) || !isfinite(cur_pos[1]) || !isfinite(cur_pos[2])) {
        *out_extra = identity_matrix();
        return DC_OK;
    }
    float jump_dx = cur_pos[0] - state->prev_world_pos[0];
    float jump_dy = cur_pos[1] - state->prev_world_pos[1];
    float jump_dz = cur_pos[2] - state->prev_world_pos[2];
    float jump_sq = jump_dx * jump_dx + jump_dy * jump_dy + jump_dz * jump_dz;
    float dt = fminf((float)delta_ms, 100.f) * 0.001f;
    if (!state->initialized || dt <= 1e-5f || jump_sq > 16.0f) {
        memcpy(state->prev_world_pos, cur_pos, sizeof(cur_pos));
        memcpy(state->offset, cur_pos, sizeof(cur_pos));
        memset(state->velocity, 0, sizeof(state->velocity));
        state->initialized = 1;
        *out_extra = identity_matrix();
        return DC_OK;
    }
    memcpy(state->prev_world_pos, cur_pos, sizeof(cur_pos));
    int substeps = dt > 0.008f ? (int)ceilf(dt / 0.008f) : 1;
    float sub_dt = dt / (float)substeps;
    for (int step = 0; step < substeps; ++step) {
        for (int i = 0; i < 3; ++i) {
            float disp = state->offset[i] - cur_pos[i];
            float force = -ks * disp - kd * state->velocity[i];
            state->velocity[i] += force * sub_dt;
            state->offset[i] += state->velocity[i] * sub_dt;
        }
        float dx = state->offset[0] - cur_pos[0];
        float dy = state->offset[1] - cur_pos[1];
        float dz = state->offset[2] - cur_pos[2];
        float rad = sqrtf(dx * dx + dy * dy + dz * dz);
        if (rad > max_r && rad > 1e-6f) {
            float scale = max_r / rad;
            state->offset[0] = cur_pos[0] + dx * scale;
            state->offset[1] = cur_pos[1] + dy * scale;
            state->offset[2] = cur_pos[2] + dz * scale;
            for (int i = 0; i < 3; ++i) state->velocity[i] *= 0.7f;
        }
    }
    float wx = state->offset[0] - cur_pos[0];
    float wy = state->offset[1] - cur_pos[1];
    float wz = state->offset[2] - cur_pos[2];
    float r0_len = fmaxf(1e-4f, sqrtf(m[0]*m[0] + m[1]*m[1] + m[2]*m[2]));
    float r1_len = fmaxf(1e-4f, sqrtf(m[4]*m[4] + m[5]*m[5] + m[6]*m[6]));
    float local_x = (wx * m[0] + wy * m[1] + wz * m[2]) / r0_len;
    float local_y = (wx * m[4] + wy * m[5] + wz * m[6]) / r1_len;
    float yaw = fmaxf(-max_ang, fminf(max_ang, (local_x / max_r) * max_ang));
    float pitch = fmaxf(-max_ang, fminf(max_ang, -(local_y / max_r) * max_ang));
    dc_matrix rx = rot_x_matrix(pitch);
    dc_matrix ry = rot_y_matrix(yaw);
    dc_matrix_multiply(&rx, &ry, out_extra);
    return DC_OK;
}

dc_status dc_spring_breast_step(dc_spring_node_state *state,
                                const dc_matrix *bone_world,
                                uint32_t delta_ms,
                                uint32_t clothed,
                                uint32_t locked,
                                dc_matrix *out_extra) {
    float ks = clothed ? 256.f : 144.f;
    float kd = clothed ? 14.5f : 6.8f;
    float max_r = clothed ? 0.25f : 0.45f;
    float max_ang = clothed ? 0.14f : 0.28f;
    return spring_step_params(state, bone_world, delta_ms, ks, kd, max_r, max_ang, locked, out_extra);
}

dc_status dc_spring_hair_step(dc_spring_node_state *state,
                              const dc_matrix *bone_world,
                              uint32_t delta_ms,
                              dc_matrix *out_extra) {
    return spring_step_params(state, bone_world, delta_ms, 196.f, 11.0f, 0.35f, 0.18f, 0u, out_extra);
}
