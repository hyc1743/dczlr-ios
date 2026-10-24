#ifndef DC_XA_H
#define DC_XA_H
#include "dc_animation.h"
#include "dc_material.h"
#include "dc_pose.h"
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

typedef struct dc_xa_material_track {
    size_t name_offset, keys_offset;
    uint32_t name_length, key_count;
} dc_xa_material_track;
/* Serialized event-track metadata. The original loader stores these fields
 * next to the target object lookup; the flags and parameter remain opaque
 * until their runtime consumer is verified. */
typedef struct dc_xa_event_track {
    size_t name_offset, keys_offset, tail_offset;
    uint32_t type, name_length, parameter, key_count, tail_value;
    uint8_t flag_a, flag_b, flag_c, flag_d, tail_flag;
} dc_xa_event_track;
typedef struct dc_xa_event_key {
    uint32_t frame;
    uint8_t value;
} dc_xa_event_key;
typedef struct dc_xa_pose_track {
    size_t name_offset, keys_offset;
    uint32_t name_length, key_count, mode;
} dc_xa_pose_track;
typedef struct dc_xa_morph_index_set { size_t indices_offset, data_offset; uint32_t count, data_length; uint8_t selector; } dc_xa_morph_index_set;
typedef struct dc_xa_morph_vector_set {
    size_t vectors_offset, data_offset;
    uint32_t count, data_length;
} dc_xa_morph_vector_set;
typedef struct dc_xa_morph_track { size_t name_offset, target_offset, keys_offset, tail_offset; uint32_t name_length, target_length, key_count; } dc_xa_morph_track;
typedef struct dc_xa_morph_key { size_t value_offset; uint32_t value_length; uint8_t raw[6]; } dc_xa_morph_key;

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

/* Material tracks retain file order. Name spans refer to encoded opaque input
 * bytes; keys are 17 binary32 components and a signed timestamp per 72-byte
 * record. The whole input profile is validated before returning a view or
 * writing any keys. Track views contain offsets, not borrowed pointers.
 * Model name matching, target binding and baseline capture are not performed.
 * Missing tracks return DC_NOT_FOUND. Failures leave outputs unchanged.
 * Input/output spans must not overlap. Empty tracks admit null keys/capacity 0. */
DC_API dc_status dc_xa_material_track_at(const void *bytes, size_t length,
    uint32_t index, dc_xa_material_track *out);
DC_API dc_status dc_xa_load_material_keys(const void *bytes, size_t length,
    uint32_t index, dc_material_key *keys, size_t capacity);
/* Event tracks are admitted as bounded serialized views. The model controller
 * consumes verified type-0/1 target UV scrolling; remaining target names,
 * flags, parameters and byte-valued frame keys stay available without
 * assigning unverified gameplay/effect semantics. */
DC_API dc_status dc_xa_event_track_at(const void *bytes, size_t length,
    uint32_t index, dc_xa_event_track *out);
DC_API dc_status dc_xa_event_key_at(const void *bytes, size_t length,
    uint32_t index, uint32_t key, dc_xa_event_key *out);
/* Node/bone tracks follow the numeric clip table. The entire XA framing is
 * checked before outputs are written. Unknown mode values remain metadata;
 * dc_pose_sample separately admits mode 0. No target lookup or skinning. */
DC_API dc_status dc_xa_pose_track_at(const void *bytes, size_t length,
    uint32_t index, dc_xa_pose_track *out);
DC_API dc_status dc_xa_load_pose_keys(const void *bytes, size_t length,
    uint32_t index, dc_pose_key *keys, size_t capacity);
/* Morph section views. Name/value blocks remain encoded borrowed spans; vector
 * records retain their serialized six-float stride and block length. No target
 * binding, vertex deformation or interpolation is implied by these views. */
DC_API dc_status dc_xa_morph_index_set_at(const void *bytes,size_t length,uint32_t index,dc_xa_morph_index_set *out);
DC_API dc_status dc_xa_morph_vector_set_at(const void *bytes,size_t length,uint32_t index,dc_xa_morph_vector_set *out);
DC_API dc_status dc_xa_load_morph_vector_sets(const void *bytes,size_t length,
    dc_xa_morph_vector_set *out,size_t capacity);
DC_API dc_status dc_xa_morph_track_at(const void *bytes,size_t length,uint32_t index,dc_xa_morph_track *out);
DC_API dc_status dc_xa_morph_key_at(const void *bytes,size_t length,uint32_t track,uint32_t key,dc_xa_morph_key *out);
DC_API dc_status dc_xa_load_morph_indices(const void *bytes,size_t length,uint32_t index,uint32_t *out,size_t capacity);
/* Six binary32 values per vector record: two three-component positions. */
DC_API dc_status dc_xa_load_morph_vectors(const void *bytes,size_t length,uint32_t index,float *out,size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
