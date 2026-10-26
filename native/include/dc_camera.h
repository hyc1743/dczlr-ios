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

#ifdef __cplusplus
}
#endif
#endif
