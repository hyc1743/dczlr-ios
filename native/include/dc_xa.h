#ifndef DC_XA_H
#define DC_XA_H
#include "dc_animation.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_XA_CLIP_COUNT 512u
#define DC_XA_CLIP_RECORD_BYTES 108u
typedef struct dc_xa_info {
    uint32_t material_tracks, event_tracks, morph_index_sets, morph_vector_sets;
    uint32_t morph_tracks, bone_tracks, has_clip_table, clip_count;
    size_t clip_table_offset, parsed_bytes;
} dc_xa_info;

/* Validate the admitted serialized XA profile without allocating or modifying
 * input: four 0/1 section flags, bounded variable blocks and (when present) the
 * fixed 512-record clip table. Every byte must be accounted for. Names and key
 * payloads remain opaque; framing is not pose/material/event interpretation.
 * Invalid arguments or framing leave out unchanged. out must not overlap input. */
DC_API dc_status dc_xa_probe(const void *bytes, size_t length, dc_xa_info *out);

/* Decode the clip table's numeric fields directly into controller descriptors.
 * Capacity must hold all 512 records. Runtime iterations and reserved bytes
 * initialize to zero; they are not serialized XA fields. Values/flags are
 * preserved without assigning semantics to unused fields or normalizing them;
 * dc_animation_* separately validates admitted runtime inputs. Missing tables
 * return DC_NOT_FOUND. On failure both arrays remain unchanged. Input and the
 * two output array spans must not overlap. No raw names or key data are copied. */
DC_API dc_status dc_xa_load_clips(const void *bytes, size_t length,
    dc_animation_clip *clips, dc_animation_timing *timing, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
