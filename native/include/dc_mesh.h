#ifndef DC_MESH_H
#define DC_MESH_H
#include "dc_material.h"
#include "dc_pose.h"
#include "dc_sprite.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dc_mesh_vertex { float position[3], normal[3], uv[2]; } dc_mesh_vertex;
typedef struct dc_viewport { float x,y,width,height,min_z,max_z; } dc_viewport;

#define DC_LIGHT_RIG_MAX 8u
enum dc_shading_mode {
    DC_SHADING_D3D9 = 0,
    DC_SHADING_TOON = 1
};
enum dc_sheen_tci_mode {
    DC_SHEEN_TCI_NONE = 0,
    DC_SHEEN_TCI_CAMERASPACENORMAL = 1,
    DC_SHEEN_TCI_CAMERASPACEREFLECTION = 3
};
typedef struct dc_light_entry {
    uint32_t d3d_type; /* 1=POINT, 2=SPOT, 3=DIRECTIONAL */
    float diffuse[3];
    float specular[3];
    float ambient[3];
    float position[3];
    float direction[3];
    float range;
    float falloff;
    float attenuation[3];
    float theta;
    float phi;
} dc_light_entry;
typedef struct dc_light_rig {
    uint32_t count;
    dc_light_entry lights[DC_LIGHT_RIG_MAX];
    float global_ambient[3];
    float camera_eye[3];
    dc_matrix view_matrix;
    uint32_t shading_mode;
    uint32_t enable_specular;
    uint32_t sheen_tci;
} dc_light_rig;
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
/* Six-plane homogeneous clipping with D3D9 Gouraud/IDR_TOON per-vertex diffuse,
 * optional Blinn-Phong vertex specular (spec_out + *out_has_specular), and
 * optional Stage 1 camera-space normal/reflection sphere-map UVs (sheen_out).
 * world_transform is NULL when vertices are already world-skinned. */
DC_API dc_status dc_mesh_clip_project_lit(const dc_mesh_vertex *vertices,size_t vertex_count,
    const uint16_t *indices,size_t index_count,const dc_matrix *world_transform,
    const dc_matrix *mvp,const dc_viewport *viewport,const dc_material_value *material,
    const dc_light_rig *rig,dc_sprite_vertex *out,dc_sprite_vertex *spec_out,
    dc_sprite_vertex *sheen_out,size_t capacity,size_t *written,uint32_t *out_has_specular);
#ifdef __cplusplus
}
#endif
#endif
