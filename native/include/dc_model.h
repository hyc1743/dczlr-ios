#ifndef DC_MODEL_H
#define DC_MODEL_H
#include "dc_xx.h"
#include "dc_xa.h"
#include "dc_scene.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dc_model dc_model;
/* Runtime connection of decoded XX nodes/meshes/materials with XA numeric
 * controller, mode-0 poses and material tracks. Sources remain borrowed.
 * Explicit current admission: no skin bones, events, morphs, billboards or
 * crossfades. Missing named tracks are inert, as unmatched original targets.
 * Root local starts as identity, matching the final original XX loader setup.
 * Unknown/unimplemented content fails; no resource fallback is substituted. */
DC_API dc_status dc_model_open(const void *xx,size_t xx_length,const void *xa,size_t xa_length,dc_model **out);
DC_API void dc_model_close(dc_model *model);
DC_API dc_status dc_model_request(dc_model *model,uint32_t clip,uint32_t now);
DC_API dc_status dc_model_query(const dc_model *model,uint32_t *clip,uint32_t *ready);
/* Controller, per-track local pose/material, then hierarchy. Failed updates
 * preserve all externally visible model state, clips and matrices. */
DC_API dc_status dc_model_tick(dc_model *model,uint32_t delta,uint32_t now,const dc_matrix *world);
DC_API dc_status dc_model_get_info(const dc_model *model,dc_xx_info *out);
DC_API dc_status dc_model_material(const dc_model *model,uint32_t index,dc_material_value *out);
DC_API dc_status dc_model_global(const dc_model *model,uint32_t index,dc_matrix *out);
DC_API dc_status dc_model_mesh(const dc_model *model,uint32_t index,dc_xx_submesh *out);
DC_API dc_status dc_model_project(const dc_model *model,uint32_t mesh,const dc_matrix *view_projection,
    const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
