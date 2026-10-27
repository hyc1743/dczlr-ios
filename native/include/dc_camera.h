#ifndef DC_CAMERA_H
#define DC_CAMERA_H
#include "dc_pose.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_camera_orbit {
    dc_matrix base;
    float stored_distance, height, pitch, yaw;
} dc_camera_orbit;

typedef struct dc_camera_lens {
    float fov_y, near_z, far_z;
    uint32_t viewport_width, viewport_height;
} dc_camera_lens;

typedef struct dc_camera_matrices {
    dc_matrix world, view, projection, view_projection;
} dc_camera_matrices;

/* Shared row-vector affine inverse for camera and bind-pose attachment.
 * Failure preserves output; in-place inversion is supported. */
DC_API dc_status dc_matrix_inverse_affine(const dc_matrix *source, dc_matrix *out);

/* Row vectors, RH D3D depth [0,1]. Reconstructs the matrix part of the two
 * original orbit controllers (0x4656c0/0x4790d0) and lens (0x407020).
 * world = Tz(-stored_distance) * Rx(pitch) * Ry(yaw) * Ty(height) * base.
 * base must be finite, affine and invertible. FOV is radians in (0, pi),
 * 0 < near < far, viewport dimensions nonzero. Output is atomic and may
 * overlap inputs. No controller limits, collision, tracking or GPU state. */
DC_API dc_status dc_camera_build(const dc_camera_orbit *orbit,
    const dc_camera_lens *lens, dc_camera_matrices *out);

/* CAM profiles observed locally: one or nine little-endian seven-float
 * records (28/252 bytes). Each is height, stored distance, pitch, yaw, XYZ.
 * All records must be finite. For the 252-byte game preset table, original
 * selectors address records 0,3,6 (84-byte stride). Other records are retained
 * as readable poses; their controller roles are not established here.
 * Decode supplies a translation base, matching the preset initialization.
 * Failure preserves output; input/output aliasing is supported. */
DC_API dc_status dc_camera_read_preset(const void *data, size_t length,
    uint32_t record, dc_camera_orbit *out);

/* FUN_0047e110 resource naming for ordinary scene types 4/5/6. This is
 * independent of a visibility heuristic or the model-placement profile. */
DC_API dc_status dc_camera_scene_resource(uint32_t scene_type,uint32_t map,uint32_t stage,
    char *out,size_t capacity);
/* Numeric retarget bodies FUN_00581380 (primary=1) / FUN_00581af0
 * (primary=0). Uses the target matrix translation, the original one-degree
 * yaw probes and one-unit side probes; resets height and reanchors base.
 * Tracking, target-node selection and controller publication are host work.
 * Finite affine input with nondegenerate angle vectors is admitted. */
DC_API dc_status dc_camera_retarget(const dc_camera_orbit *source,const dc_matrix *target,
    uint32_t primary,dc_camera_orbit *out);

enum dc_camera_scene_binding {
    DC_CAMERA_FACE_TARGET=0,DC_CAMERA_BODY_TARGET=1,
    DC_CAMERA_ANIMATION_TARGET=2,DC_CAMERA_ANIMATION_EYE=3
};
/* Type-4 bindings from 005181f0/00512cc0. FACE belongs to the face model;
 * BODY and ANIMATION_TARGET to the actor; ANIMATION_EYE to the separate
 * RPP17 auto_cam model. No substitute node is returned for a missing binding. */
DC_API dc_status dc_camera_scene_node(uint32_t stage,uint32_t binding,char *out,size_t capacity);

/* Original 00417ac0: orient a world matrix toward target translation using
 * world up (0,1,0), preserving its eye and affine column. No roll is added.
 * Inputs must be finite affine matrices. Coincident/vertical targets that
 * cannot supply an invertible camera fail atomically; aliasing is supported. */
DC_API dc_status dc_camera_look_at(const dc_matrix *source,const dc_matrix *target,dc_matrix *out);

#ifdef __cplusplus
}
#endif
#endif
