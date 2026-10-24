#ifndef DC_XX_H
#define DC_XX_H
#include "dc_material.h"
#include "dc_image.h"
#include "dc_pose.h"
#include "dc_mesh.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_XX_NODE_LIMIT 4096u
#define DC_XX_SUBMESH_LIMIT 16384u
#define DC_XX_MATERIAL_LIMIT 4096u
#define DC_XX_TEXTURE_LIMIT 1024u
#define DC_XX_DEPTH_LIMIT 64u
#define DC_XX_NO_PARENT UINT32_MAX
typedef struct dc_xx dc_xx;
typedef struct dc_xx_span { size_t offset, length; } dc_xx_span;
typedef struct dc_xx_info {
    uint32_t nodes, submeshes, materials, textures, bones, version_bits;
    size_t parsed_bytes;
    dc_xx_span opaque_tail;
} dc_xx_info;
typedef struct dc_xx_node {
    dc_xx_span name;
    size_t matrix_offset;
    uint32_t parent, children, first_submesh, submeshes;
} dc_xx_node;
typedef struct dc_xx_submesh {
    dc_xx_span indices, vertices, extra_uv[3];
    uint32_t node, material, index_count, vertex_count, uv_sets;
} dc_xx_submesh;
typedef struct dc_xx_material {
    dc_xx_span name, texture_names[8];
    size_t value_offset;
} dc_xx_material;
typedef struct dc_xx_texture {
    dc_xx_span name, image;
    size_t descriptor_offset;
} dc_xx_texture;

typedef struct dc_xx_skin {
    dc_xx_span shared_vertices;
    uint32_t node,shared_count,first_bone,bones,vertex_format;
} dc_xx_skin;
typedef struct dc_xx_bone {
    dc_xx_span name;
    size_t matrix_offset;
    uint32_t node,index;
} dc_xx_bone;
typedef struct dc_xx_weights {
    float weights[3];
    uint8_t indices[4];
} dc_xx_weights;

/* Admitted observed 3.17/3.19 profiles (bits 0x404ae148/0x404c28f6), 21-byte header,
 * recursive node/mesh layout, material table and embedded-image blocks. The
 * structured prefix must frame within input. Bytes after the embedded images
 * are retained as an opaque tail span: the observed original loader does not
 * read them. Their semantics are not validated. First pass validates bounds and limits;
 * second pass allocates only bounded metadata. No GPU or animation executes.
 * Source remains borrowed: caller must keep it immutable/alive until close.
 * All spans refer to this source; encoded names and geometry remain opaque.
 * Probe leaves out unchanged on failure. Open sets *out=NULL on failure.
 * Output and source must not overlap. Unknown profiles fail explicitly. */
DC_API dc_status dc_xx_probe(const void *bytes, size_t length, dc_xx_info *out);
DC_API dc_status dc_xx_open(const void *bytes, size_t length, dc_xx **out);
DC_API void dc_xx_close(dc_xx *model);
DC_API dc_status dc_xx_get_info(const dc_xx *model, dc_xx_info *out);
DC_API dc_status dc_xx_node_at(const dc_xx *model, uint32_t index, dc_xx_node *out);
DC_API dc_status dc_xx_submesh_at(const dc_xx *model, uint32_t index, dc_xx_submesh *out);
DC_API dc_status dc_xx_material_at(const dc_xx *model, uint32_t index, dc_xx_material *out);
DC_API dc_status dc_xx_texture_at(const dc_xx *model, uint32_t index, dc_xx_texture *out);
/* Per-node shared vertex table/FVF and bone ranges. Bone indices retain the
 * serialized values; no dense-index or palette-order inference is applied.
 * Original 0x40a6d0 copies the 64-byte matrix verbatim after the name/index. */
DC_API dc_status dc_xx_skin_at(const dc_xx *model,uint32_t node,dc_xx_skin *out);
DC_API dc_status dc_xx_bone_at(const dc_xx *model,uint32_t index,dc_xx_bone *out);
DC_API dc_status dc_xx_bone_matrix(const dc_xx *model,uint32_t index,dc_matrix *out);
/* Original 0x409830/0x4131f0 binding: last exact named root descendant.
 * Missing names produce UINT32_MAX, matching an original null global pointer.
 * No identity-transform fallback is inferred. Invalid names/capacity preserve
 * all outputs. An empty bone range accepts a null zero-capacity output. */
DC_API dc_status dc_xx_bind_bones(const dc_xx *model,uint32_t node,uint32_t *targets,size_t capacity);
/* Original 0x408f60 FVF 0x111c/0x141c source: three raw finite weights at
 * offsets 16/20/24 and four byte indices at 28..31 of a 52-byte record.
 * Weight normalization, implied fourth weight and palette lookup are separate
 * runtime operations; index 255 remains raw rather than being clamped. */
DC_API dc_status dc_xx_load_mesh_weights(const dc_xx *model,uint32_t mesh,dc_xx_weights *out,size_t capacity);
/* Decode the first UV stream and unskinned position/normal from 52-byte XX
 * records, matching 0x408f60's FVF 0x112 source offsets. Indices retain file
 * order and must form a valid in-range triangle list. Capacity and complete
 * selected mesh validation precede writes. Source/output must not overlap. */
DC_API dc_status dc_xx_load_mesh_vertices(const dc_xx *model,uint32_t index,
    dc_mesh_vertex *out,size_t capacity);
DC_API dc_status dc_xx_load_mesh_indices(const dc_xx *model,uint32_t index,
    uint16_t *out,size_t capacity);

/* First exact case-sensitive C-string match in file order. Query is the
 * encoded (bytewise complemented) name span from XA; requires an encoded NUL.
 * Matching stops at the first encoded NUL, as original strcmp did. No locale
 * conversion. An un-terminated query/model name is rejected, not over-read.
 * Missing matches return DC_NOT_FOUND; failure preserves index. */
DC_API dc_status dc_xx_find_material_encoded(const dc_xx *model,
    const void *name, size_t length, uint32_t *index);
/* Node lookup walks root descendants in preorder and keeps the LAST match, as
 * 0x4131f0/0x413270 do. This differs from material-name lookup above.
 * Node matrix copies the serialized local baseline; no hierarchy executes. */
DC_API dc_status dc_xx_find_node_encoded(const dc_xx *model,
    const void *name, size_t length, uint32_t *index);
DC_API dc_status dc_xx_node_matrix(const dc_xx *model, uint32_t index, dc_matrix *out);

/* Fresh material baseline: negate original components 0..15, preserve power
 * component 16. Finite inputs admitted; failure leaves out unchanged. This
 * does not perform checksum validation, effect setup or model target updates. */
DC_API dc_status dc_xx_material_baseline(const dc_xx *model, uint32_t index, dc_material_value *out);

/* Uses encoded texture-name suffix .bmp/.tga to select the existing bounded
 * image decoder. BMP permits the zero signature restored by the original XX
 * loader. No input modification, resampling, mipmaps or texture upload.
 * Unknown image profiles fail; decoder errors preserve outputs. */
DC_API dc_status dc_xx_image_probe(const dc_xx *model, uint32_t index, dc_image_info *out);
DC_API dc_status dc_xx_image_decode(const dc_xx *model, uint32_t index,
    void *rgba, size_t capacity, dc_image_info *out);
#ifdef __cplusplus
}
#endif
#endif
