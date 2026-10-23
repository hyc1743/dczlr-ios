#include "dc_xa.h"
#include <float.h>
#include <string.h>

_Static_assert(sizeof(float) == 4 && FLT_RADIX == 2 && FLT_MANT_DIG == 24 &&
    FLT_MAX_EXP == 128, "XA numeric fields require IEEE binary32");

typedef struct cursor { const uint8_t *data; size_t length, position; } cursor;

static uint32_t word(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
        (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static int skip(cursor *c, size_t length) {
    if (length > c->length - c->position) return 0;
    c->position += length;
    return 1;
}
static int integer(cursor *c, uint32_t *out) {
    if (c->length - c->position < 4) return 0;
    *out = word(c->data + c->position);
    c->position += 4;
    return 1;
}
static int flag(cursor *c, uint32_t *out) {
    if (c->position == c->length) return 0;
    *out = c->data[c->position++];
    return *out <= 1;
}
static int block(cursor *c) {
    uint32_t length;
    return integer(c, &length) && skip(c, length);
}
static int array(cursor *c, uint32_t count, size_t stride) {
    if (count > (c->length - c->position) / stride) return 0;
    return skip(c, (size_t)count * stride);
}
static int records(cursor *c, uint32_t *count, size_t minimum) {
    return integer(c, count) && *count <= (c->length - c->position) / minimum;
}
static int overlaps(const void *a, size_t a_length, const void *b, size_t b_length) {
    if (!a_length || !b_length) return 0;
    uintptr_t aa = (uintptr_t)a, bb = (uintptr_t)b;
    return aa <= bb ? bb - aa < a_length : aa - bb < b_length;
}

#define REQUIRE(expression) do { if (!(expression)) return DC_FORMAT; } while (0)

dc_status dc_xa_probe(const void *bytes, size_t length, dc_xa_info *out) {
    if (!bytes || !out || overlaps(bytes, length, out, sizeof(*out))) return DC_ARGUMENT;
    cursor c = {(const uint8_t *)bytes, length, 0};
    dc_xa_info info = {0};
    uint32_t present, count;
    REQUIRE(flag(&c, &present));
    if (present) {
        REQUIRE(records(&c, &info.material_tracks, 8));
        for (uint32_t i = 0; i < info.material_tracks; ++i) {
            REQUIRE(block(&c));
            REQUIRE(integer(&c, &count) && array(&c, count, 72));
        }
    }
    REQUIRE(flag(&c, &present));
    if (present) {
        REQUIRE(records(&c, &info.event_tracks, 25));
        for (uint32_t i = 0; i < info.event_tracks; ++i) {
            REQUIRE(skip(&c, 4) && block(&c) && skip(&c, 8));
            REQUIRE(integer(&c, &count) && array(&c, count, 5) && skip(&c, 5));
        }
    }
    REQUIRE(flag(&c, &present));
    if (present) {
        REQUIRE(records(&c, &info.morph_index_sets, 9));
        for (uint32_t i = 0; i < info.morph_index_sets; ++i) {
            REQUIRE(skip(&c, 1) && integer(&c, &count) && array(&c, count, 4) && block(&c));
        }
        REQUIRE(records(&c, &info.morph_vector_sets, 8));
        for (uint32_t i = 0; i < info.morph_vector_sets; ++i) {
            REQUIRE(integer(&c, &count) && array(&c, count, 24) && block(&c));
        }
        REQUIRE(records(&c, &info.morph_tracks, 16));
        for (uint32_t i = 0; i < info.morph_tracks; ++i) {
            REQUIRE(block(&c) && block(&c) && records(&c, &count, 10));
            for (uint32_t j = 0; j < count; ++j) REQUIRE(skip(&c, 6) && block(&c));
            REQUIRE(skip(&c, 4));
        }
    }
    REQUIRE(flag(&c, &present));
    if (present) {
        info.has_clip_table = 1;
        info.clip_count = DC_XA_CLIP_COUNT;
        info.clip_table_offset = c.position;
        REQUIRE(array(&c, DC_XA_CLIP_COUNT, DC_XA_CLIP_RECORD_BYTES));
        REQUIRE(records(&c, &info.bone_tracks, 12));
        for (uint32_t i = 0; i < info.bone_tracks; ++i) {
            REQUIRE(block(&c) && integer(&c, &count) && skip(&c, 4) && array(&c, count, 52));
        }
    }
    REQUIRE(c.position == c.length);
    info.parsed_bytes = c.position;
    *out = info;
    return DC_OK;
}

static float real(const uint8_t *p) {
    uint32_t bits = word(p);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

dc_status dc_xa_load_clips(const void *bytes, size_t length,
        dc_animation_clip *clips, dc_animation_timing *timing, size_t capacity) {
    if (!bytes || !clips || !timing) return DC_ARGUMENT;
    if (capacity < DC_XA_CLIP_COUNT) return DC_RANGE;
    size_t clip_bytes = sizeof(*clips) * DC_XA_CLIP_COUNT;
    size_t timing_bytes = sizeof(*timing) * DC_XA_CLIP_COUNT;
    if (overlaps(bytes, length, clips, clip_bytes) || overlaps(bytes, length, timing, timing_bytes) ||
        overlaps(clips, clip_bytes, timing, timing_bytes)) return DC_ARGUMENT;
    dc_xa_info info;
    dc_status status = dc_xa_probe(bytes, length, &info);
    if (status != DC_OK) return status;
    if (!info.has_clip_table) return DC_NOT_FOUND;
    const uint8_t *record = (const uint8_t *)bytes + info.clip_table_offset;
    /* Full framing and span validation precedes the first output write. */
    for (uint32_t i = 0; i < DC_XA_CLIP_COUNT; ++i, record += DC_XA_CLIP_RECORD_BYTES) {
        dc_animation_clip clip = {0};
        dc_animation_timing config = {0};
        config.duration_seconds = real(record + 64);
        clip.first_frame = real(record + 72);
        clip.last_frame = real(record + 76);
        clip.loop = record[80];
        config.loop_limit = record[81];
        config.chain = record[82];
        config.next_clip = word(record + 83);
        clip.reverse = record[87];
        clip.blend_duration = word(record + 88);
        clips[i] = clip;
        timing[i] = config;
    }
    return DC_OK;
}

dc_status dc_xa_material_track_at(const void *bytes, size_t length,
        uint32_t index, dc_xa_material_track *out) {
    if (!bytes || !out || overlaps(bytes, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_xa_info info;
    dc_status status = dc_xa_probe(bytes, length, &info);
    if (status != DC_OK) return status;
    if (index >= info.material_tracks) return DC_NOT_FOUND;
    cursor c = {(const uint8_t *)bytes, length, 5};
    for (uint32_t i = 0; i <= index; ++i) {
        dc_xa_material_track track = {0};
        REQUIRE(integer(&c, &track.name_length));
        track.name_offset = c.position;
        REQUIRE(skip(&c, track.name_length) && integer(&c, &track.key_count));
        track.keys_offset = c.position;
        REQUIRE(array(&c, track.key_count, 72));
        if (i == index) { *out = track; return DC_OK; }
    }
    return DC_NOT_FOUND;
}

dc_status dc_xa_load_material_keys(const void *bytes, size_t length,
        uint32_t index, dc_material_key *keys, size_t capacity) {
    dc_xa_material_track track;
    dc_status status = dc_xa_material_track_at(bytes, length, index, &track);
    if (status != DC_OK) return status;
    if (capacity < track.key_count || (track.key_count && sizeof(*keys) > SIZE_MAX / track.key_count)) return DC_RANGE;
    if (!track.key_count) return DC_OK;
    if (!keys || overlaps(bytes, length, keys, track.key_count * sizeof(*keys))) return DC_ARGUMENT;
    const uint8_t *record = (const uint8_t *)bytes + track.keys_offset;
    for (uint32_t i = 0; i < track.key_count; ++i, record += 72) {
        dc_material_key key;
        for (uint32_t j = 0; j < DC_MATERIAL_COMPONENTS; ++j) key.value.components[j] = real(record + j * 4);
        uint32_t bits = word(record + 68);
        memcpy(&key.frame, &bits, sizeof(bits));
        keys[i] = key;
    }
    return DC_OK;
}
