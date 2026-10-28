#ifndef DC_MODEL_H
#define DC_MODEL_H
#include "dc_xx.h"
#include "dc_xa.h"
#include "dc_scene.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dc_model dc_model;
#define DC_MODEL_NO_ANIMATION UINT32_MAX
enum dc_model_vertex_space { DC_MODEL_SPACE_LOCAL=0,DC_MODEL_SPACE_WORLD=1 };
/* Runtime connection of decoded XX nodes/meshes/materials with XA numeric
 * controller, mode-0 poses and material tracks. Sources remain borrowed.
 * Explicit current admission: mode-0 poses, material tracks, unfiltered
 * type-0/1 no-key event UV scrolling, and indexed four-matrix skinning. Other
 * event types, keyed/filtered events, morphs, billboards and crossfades remain
 * unsupported. Missing animation targets are inert; active skin bones need
 * a named target. Serialized indices and default palette255 are retained.
 * Root local starts as identity, matching the final original XX loader setup.
 * Unknown content still fails; event names remain borrowed and unsupported
 * event types are inert. No resource fallback is substituted. */
DC_API dc_status dc_model_open(const void *xx,size_t xx_length,const void *xa,size_t xa_length,dc_model **out);
/* Explicit XX-only static path. Original 0x45c090 leaves a model without XA
 * when archive lookup fails; 0x51e3b0 permits this for ordinary static maps.
 * Same XX/mesh/material/hierarchy admission and borrowed-source lifetime as
 * above. There is no invented clip or substitute XA: requests return
 * DC_NOT_FOUND, query returns NO_ANIMATION/ready=1, and ticks only update
 * hierarchy/palettes with the supplied world matrix; no clock changes poses. */
DC_API dc_status dc_model_open_static(const void *xx,size_t xx_length,dc_model **out);
DC_API void dc_model_close(dc_model *model);
DC_API dc_status dc_model_request(dc_model *model,uint32_t clip,uint32_t now);
DC_API dc_status dc_model_set_chain(dc_model *model,uint32_t clip,int32_t next_clip);
DC_API dc_status dc_model_set_loop(dc_model *model,uint32_t clip,int32_t limit);
DC_API dc_status dc_model_query(const dc_model *model,uint32_t *clip,uint32_t *ready);
/* Snapshot of the animated controller for scene logic. Static models return
 * DC_NOT_FOUND without writing a fabricated controller state. */
DC_API dc_status dc_model_get_animation(const dc_model *model,dc_animation_state *out);
/* Host lifecycle: preserve animation deadlines when a scene's callbacks are
 * suspended while an independently timed system page runs. */
DC_API dc_status dc_model_shift_clock(dc_model *model,uint32_t elapsed);
/* Controller, per-track local pose/material, then hierarchy. Failed updates
 * preserve all externally visible model state, clips and matrices. */
DC_API dc_status dc_model_tick(dc_model *model,uint32_t delta,uint32_t now,const dc_matrix *world);
DC_API dc_status dc_model_get_info(const dc_model *model,dc_xx_info *out);
DC_API dc_status dc_model_material(const dc_model *model,uint32_t index,dc_material_value *out);
DC_API dc_status dc_model_global(const dc_model *model,uint32_t index,dc_matrix *out);
DC_API dc_status dc_model_mesh(const dc_model *model,uint32_t index,dc_xx_submesh *out);
/* After a successful tick, unskinned positions/normals remain node-local;
 * skinned positions and inverse-transpose blended normals are world-space.
 * Source vertices/weights are retained separately and never accumulated.
 * Failed ticks preserve both palettes and deformed mesh buffers. */
DC_API dc_status dc_model_vertex_space(const dc_model *model,uint32_t mesh,uint32_t *out);
DC_API dc_status dc_model_load_vertices(const dc_model *model,uint32_t mesh,dc_mesh_vertex *out,size_t capacity);
/* Original source-space vertex buffer before event UV updates, morphs or CPU
 * skinning.  Morph consumers use this buffer and then feed the result through
 * the model's existing skin palette exactly once. */
DC_API dc_status dc_model_load_source_vertices(const dc_model *model,uint32_t mesh,dc_mesh_vertex *out,size_t capacity);
/* Render-hidden byte +0x1f0 controls this mesh. An ancestor's transform-skip
 * +0x1f8 suppresses traversal. Material alpha/effects are separate admission.
 * Projection itself remains a low-level operation without culling. */
DC_API dc_status dc_model_mesh_visible(const dc_model *model,uint32_t mesh,uint32_t *out);
/* Original 0x412450: recursively set the render-hidden byte (+0x1f0) for
 * this node and descendants. A later child call may reveal that subtree.
 * Render hiding does not suppress transforms (+0x1f8) or animation. */
DC_API dc_status dc_model_hide_node(dc_model *model,uint32_t node,uint32_t hidden);
DC_API dc_status dc_model_project(const dc_model *model,uint32_t mesh,const dc_matrix *view_projection,
    const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity);
/* Same world/local vertex-space selection with six-plane clipping and a
 * variable triangle count. NULL output/capacity0 queries the required count.
 * Hidden/effect/sort admission remains the caller's responsibility. */
DC_API dc_status dc_model_project_clipped(const dc_model *model,uint32_t mesh,const dc_matrix *view_projection,
    const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity,size_t *written);
#ifdef __cplusplus
}
#endif
#endif
