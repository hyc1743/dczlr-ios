#ifndef DC_EYENECK_H
#define DC_EYENECK_H

#include <stddef.h>
#include <stdint.h>

#include "dc_pose.h"
#include "dc_pp.h"

#ifdef __cplusplus
extern "C" {
#endif

enum dc_eyeneck_kind {
    DC_EYENECK_EYES = 1,
    DC_EYENECK_NECK = 2
};

typedef struct dc_eyeneck_span {
    size_t offset;
    uint32_t length;
} dc_eyeneck_span;

typedef struct dc_eyeneck_info {
    uint32_t kind;
    uint32_t targets;
    uint32_t records;
    size_t body_offset;
    size_t parsed_bytes;
} dc_eyeneck_info;

typedef struct dc_eyeneck_slot {
    uint32_t slot_index;
    dc_eyeneck_span label;
    uint32_t behavior_mode;
    float max_yaw_rad;
    float max_pitch_rad;
    uint32_t interp_ms;
    uint32_t reserved;
    float weight;
    float param_a;
    float param_b;
    uint32_t timers_ms[4];
} dc_eyeneck_slot;

typedef struct dc_eyeneck_controller {
    dc_eyeneck_slot active;
    float q_start[4];
    float q_current[4];
    uint32_t blend_elapsed_ms;
    uint32_t saccade_timer_ms;
    uint32_t saccade_limit_ms;
    float avert_sign;
} dc_eyeneck_controller;

typedef struct dc_eyeneck_tremor_state {
    uint32_t accum_ms;
    float sign;
} dc_eyeneck_tremor_state;

typedef struct dc_spring_node_state {
    uint8_t initialized;
    float prev_world_pos[3];
    float prev_world_vel[3];
    float offset[3];
    float velocity[3];
} dc_spring_node_state;

/* Bounded admission for the two local RPP_04 special-state profiles. */
DC_API dc_status dc_eyeneck_probe(const void *source, size_t length,
                                  dc_eyeneck_info *out);
DC_API dc_status dc_eyeneck_target_at(const void *source, size_t length,
                                      uint32_t index, dc_eyeneck_span *out);
DC_API dc_status dc_eyeneck_slot_at(const void *source, size_t length,
                                    uint32_t record_index, dc_eyeneck_slot *out);

/* 0x0043a2a0 / 0x0043b940 / 0x00440790 / 0x004401d0 look-at & avert controller. */
DC_API void dc_eyeneck_controller_init(dc_eyeneck_controller *ctrl);
DC_API void dc_eyeneck_controller_set_slot(dc_eyeneck_controller *ctrl,
                                           const dc_eyeneck_slot *slot);
DC_API dc_status dc_eyeneck_controller_step(dc_eyeneck_controller *ctrl,
                                            const dc_matrix *bone_world,
                                            const float target_world[3],
                                            float convergence_x,
                                            uint32_t delta_ms,
                                            dc_matrix *out_extra);

/* 0x0047e8f0 eye-highlight arousal micro-tremor (>34ms flip, +-3 deg). */
DC_API void dc_eyeneck_tremor_init(dc_eyeneck_tremor_state *state);
DC_API dc_status dc_eyeneck_tremor_step(dc_eyeneck_tremor_state *state,
                                        uint32_t delta_ms,
                                        float arousal,
                                        uint32_t force_max,
                                        dc_matrix *out_extra);

/* 0x00608020 / 0x00480900 breast spring & 0x00475ac0 hair secondary lag. */
DC_API void dc_spring_node_init(dc_spring_node_state *state);
DC_API dc_status dc_spring_breast_step(dc_spring_node_state *state,
                                       const dc_matrix *bone_world,
                                       uint32_t delta_ms,
                                       uint32_t clothed,
                                       uint32_t locked,
                                       dc_matrix *out_extra);
DC_API dc_status dc_spring_hair_step(dc_spring_node_state *state,
                                     const dc_matrix *bone_world,
                                     uint32_t delta_ms,
                                     dc_matrix *out_extra);

#ifdef __cplusplus
}
#endif

#endif
