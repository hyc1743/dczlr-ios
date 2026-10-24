#ifndef DC_SKIN_H
#define DC_SKIN_H
#include "dc_xx.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_SKIN_PALETTE_LIMIT 256u
typedef struct dc_skin_bone { uint32_t index,target;dc_matrix offset; } dc_skin_bone;
typedef struct dc_skin_palette { dc_matrix world[DC_SKIN_PALETTE_LIMIT]; } dc_skin_palette;
enum dc_skin_normal_mode {
    DC_SKIN_KEEP_NORMAL=0,
    DC_SKIN_TRANSFORM_NORMAL=1,
    DC_SKIN_NORMALIZE=2
};
/* Direct3D9 default indexed world matrices are identity, including index255.
 * Original 0x4132e0 updates offset*bound_global at each serialized index,
 * skipping255; later duplicate indices overwrite earlier ones. Untouched
 * slots retain previous state. Host resolves named targets with dc_xx.
 * Palette/source spans cannot overlap; a failed update preserves palette. */
DC_API dc_status dc_skin_palette_init(dc_skin_palette *palette);
DC_API dc_status dc_skin_palette_update(dc_skin_palette *palette,const dc_skin_bone *bones,
    size_t count,const dc_matrix *globals,size_t global_count);
/* Indexed four-matrix blending from three explicit weights. The fourth is
 * 1-(w0+w1+w2), retaining float32 residuals without clamping/renormalization.
 * Index255 uses the actual palette state, rather than being dropped.
 * Finite affine matrices admitted. Normals can remain untouched, transform
 * by weighted inverse-transpose world matrices, or additionally normalize.
 * Camera normal transformation is separate. Singular normal transforms fail;
 * keep-normal mode still permits singular position transforms. UVs retain
 * source bits. Input/output cannot overlap, count<=1048576, failure atomic. */
DC_API dc_status dc_skin_apply(const dc_skin_palette *palette,const dc_mesh_vertex *vertices,
    const dc_xx_weights *weights,size_t count,uint32_t normal_mode,
    dc_mesh_vertex *out,size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
