#ifndef DC_MORPH_H
#define DC_MORPH_H
#include "dc_xx.h"
#include "dc_xa.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_morph dc_morph;
#define DC_MORPH_NO_TARGET UINT32_MAX
#define DC_MORPH_TRACK_LIMIT 4096u
#define DC_MORPH_ELEMENT_LIMIT 1048576u

typedef struct dc_morph_info {
    uint32_t tracks,index_sets,vector_sets,meshes;
    /* The original random eye scheduler and voice/scene control setters are
     * separate consumers. This runtime does not invent their input values. */
    uint32_t random_eye_scheduler_pending;
} dc_morph_info;
typedef struct dc_morph_track_info {
    uint32_t type,mesh,index_set,key_count,mapping_count;
    uint8_t enabled,manual_mode,reserved[2];
} dc_morph_track_info;
typedef struct dc_morph_expression {
    int32_t previous,current;
    uint32_t blend_start,blend_end;
    float blend;
    uint8_t state,reserved[3]; /* 0 settled, 1 just completed, 2 blending. */
} dc_morph_expression;
typedef struct dc_morph_controls {
    dc_morph_expression mouth,eyes;
    float mouth_phase,left_phase,right_phase;
    float eye_min,eye_max,mouth_min,mouth_max;
    uint8_t scheduler_mode,link_eyes,reserved[2];
} dc_morph_controls;
typedef struct dc_morph_mesh_buffer {
    dc_mesh_vertex *vertices;
    size_t count;
} dc_morph_mesh_buffer;

/* Bind immutable XX/XA data using original 0x40e8e0 names and the index-set
 * selector. xx must describe exactly xx_bytes and stay alive until close.
 * Both source spans remain borrowed. Missing node/index/vector names are
 * inert, not substitute resources. Types 0/1/3/4/5 are implemented; a bound
 * unsupported type fails DC_FORMAT. No XA clip table is required.
 * Open initializes zero controls, then the exact 0x418c00 bounds/flags; it
 * does not manufacture expression indices, voice phases or random blinking.
 * Open sets *out=NULL on failure; sources and output must not overlap. */
DC_API dc_status dc_morph_open(const dc_xx *xx,const void *xx_bytes,size_t xx_length,
    const void *xa_bytes,size_t xa_length,dc_morph **out);
DC_API void dc_morph_close(dc_morph *morph);
DC_API dc_status dc_morph_get_info(const dc_morph *morph,dc_morph_info *out);
DC_API dc_status dc_morph_get_track_info(const dc_morph *morph,uint32_t track,dc_morph_track_info *out);
DC_API dc_status dc_morph_get_controls(const dc_morph *morph,dc_morph_controls *out);
DC_API dc_status dc_morph_set_controls(dc_morph *morph,const dc_morph_controls *controls);
/* Original 0x418c00 only: bounds9/0, scheduler_mode0, link_eyes1. Existing
 * expression groups and phase values are preserved. */
DC_API dc_status dc_morph_reset_controls(dc_morph *morph);
DC_API dc_status dc_morph_set_track_enabled(dc_morph *morph,uint32_t track,uint32_t enabled);
/* Type1 manual frame selects 0x419780. Three-vector mode selects 0x41cc20:
 * lerp(lerp(vector0,vector1,weights[0]),vector2,weights[1]). Indices refer to
 * serialized vector-set order. NO_TARGET retains an original null pointer
 * and makes that mode inert. Finite weights are not artificially clamped. */
DC_API dc_status dc_morph_set_manual_frame(dc_morph *morph,uint32_t track,float frame);
DC_API dc_status dc_morph_set_three_vectors(dc_morph *morph,uint32_t track,
    const uint32_t vectors[3],const float weights[2]);
DC_API dc_status dc_morph_find_vector_encoded(const dc_morph *morph,
    const void *name,size_t length,uint32_t *out);

/* Apply once before CPU skinning to persistent LOCAL buffers, in track order.
 * Exactly info.meshes descriptors are required; NULL/0 is allowed for a mesh
 * with no selected write. Nonempty buffers must have its exact vertex count.
 * Buffers must not overlap each other, descriptors, runtime or borrowed data.
 * Only mapped positions/normals change; UV/untouched bytes stay unchanged.
 * Outside an interval, disabled/missing targets and absent weighted vectors
 * preserve previous buffer contents. Phases clamp to their original bounds.
 * Every validation/allocation/arithmetic failure preserves ALL buffers and
 * runtime controls. The caller must also keep borrowed data immutable.
 * apply uses supplied expression states; tick first advances expression
 * blend clocks as 0x418d90 does. Both complete state1's blend after sampling.
 * Neither function runs the pending random eye scheduler (0x41c530/0x41c730)
 * or generates voice/scene inputs. */
DC_API dc_status dc_morph_apply(dc_morph *morph,float clip_frame,
    const dc_morph_mesh_buffer *buffers,size_t count);
DC_API dc_status dc_morph_tick(dc_morph *morph,float clip_frame,uint32_t now,
    const dc_morph_mesh_buffer *buffers,size_t count);

#ifdef __cplusplus
}
#endif
#endif
