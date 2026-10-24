#ifndef DC_MESH_H
#define DC_MESH_H
#include "dc_pose.h"
#include "dc_sprite.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dc_mesh_vertex { float position[3], normal[3], uv[2]; } dc_mesh_vertex;
typedef struct dc_viewport { float x,y,width,height,min_z,max_z; } dc_viewport;
/* Project an indexed unskinned triangle list into the D3D9 XYZRHW layout.
 * Matrix order is row-vector position*mvp. Perspective division is retained
 * as positive rhw for GPU interpolation. Triangles crossing w<=0 are outside
 * this admitted profile; GPU clips projected x/y/z against its clip volume.
 * No normal lighting, skinning, sorting, effect or blend-state inference.
 * A bounded temporary output makes every failure atomic. Inputs/output cannot
 * overlap; both counts <=1048576, all referenced positions/UVs finite. */
DC_API dc_status dc_mesh_project(const dc_mesh_vertex *vertices,size_t vertex_count,
    const uint16_t *indices,size_t index_count,const dc_matrix *mvp,
    const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity);
/* Six-plane homogeneous clipping before perspective division. Retains visible
 * portions of triangles crossing W=0/near/side/far planes and interpolates UVs
 * in homogeneous edge space. Does not discard a mesh because a source vertex
 * is behind the camera. Zero surviving triangles is a successful empty draw.
 * out=NULL/capacity=0 queries the required count. All outputs, including count,
 * are preserved on failure. Inputs, output and count must not overlap.
 * Counts/capacity/output <=1048576; positive finite W is required only for
 * surviving vertices. Same viewport, unlit and unsorted profile as above. */
DC_API dc_status dc_mesh_clip_project(const dc_mesh_vertex *vertices,size_t vertex_count,
    const uint16_t *indices,size_t index_count,const dc_matrix *mvp,
    const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity,
    size_t *written);
#ifdef __cplusplus
}
#endif
#endif
