#include "dc_xl.h"

#include <math.h>
#include <string.h>

#define DC_XL_HEADER 5u
#define DC_XL_RECORD 197u
#define DC_XL_MAX_LIGHTS 64u
#define DC_XL_BODY_BYTES 169u
#define DC_XL_FLOATS 41u

static int overlap(const void *a, size_t al, const void *b, size_t bl) {
    uintptr_t aa = (uintptr_t)a, bb = (uintptr_t)b;
    return al && bl && (aa <= bb ? bb - aa < al : aa - bb < bl);
}

static int range_ok(size_t length, size_t offset, size_t span) {
    return offset <= length && span <= length - offset;
}

static uint32_t little32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int encoded_string_ok(const uint8_t *source, size_t length) {
    if (!length || source[length - 1] != 0xffu) return 0;
    for (size_t i = 0; i + 1 < length; ++i) {
        if (!source[i] || source[i] == 0xffu) return 0;
    }
    return 1;
}

static dc_status light_at_internal(const uint8_t *source, size_t length,
                                   uint32_t index, dc_xl_light *out) {
    if (!source || !out) return DC_ARGUMENT;
    if (length < DC_XL_HEADER || memcmp(source, "LLL\0", 4) != 0) return DC_FORMAT;
    uint32_t count = source[4];
    if (!count || count > DC_XL_MAX_LIGHTS || index >= count) return DC_RANGE;
    size_t record = DC_XL_HEADER + (size_t)index * DC_XL_RECORD;
    if (!range_ok(length, record, DC_XL_RECORD)) return DC_FORMAT;
    size_t cursor = record;
    if (!range_ok(length, cursor, 4)) return DC_FORMAT;
    uint32_t name_length = little32(source + cursor);
    cursor += 4;
    if (!name_length || name_length > 64 || !range_ok(length, cursor, name_length) ||
        !encoded_string_ok(source + cursor, name_length)) return DC_FORMAT;
    dc_xl_span name = {cursor, name_length};
    cursor += name_length;
    if (!range_ok(length, cursor, 4)) return DC_FORMAT;
    uint32_t target_length = little32(source + cursor);
    cursor += 4;
    if (!target_length || target_length > 128 || !range_ok(length, cursor, target_length) ||
        !encoded_string_ok(source + cursor, target_length)) return DC_FORMAT;
    dc_xl_span target = {cursor, target_length};
    cursor += target_length;
    if (!range_ok(length, cursor, 5 + DC_XL_FLOATS * sizeof(float))) return DC_FORMAT;
    uint8_t kind = source[cursor++];
    uint8_t enabled = source[cursor++];
    uint8_t flags[3] = {source[cursor], source[cursor + 1], source[cursor + 2]};
    cursor += 3;
    if (cursor - record + DC_XL_FLOATS * sizeof(float) != DC_XL_RECORD) return DC_FORMAT;
    float values[DC_XL_FLOATS];
    memcpy(values, source + cursor, sizeof(values));
    for (size_t i = 0; i < DC_XL_FLOATS; ++i)
        if (!isfinite(values[i])) return DC_FORMAT;

    memset(out, 0, sizeof(*out));
    out->name = name;
    out->target = target;
    out->kind = kind;
    out->enabled = enabled;
    memcpy(out->flags, flags, sizeof(out->flags));
    memcpy(out->diffuse, values + 0, sizeof(out->diffuse));
    memcpy(out->ambient, values + 4, sizeof(out->ambient));
    memcpy(out->specular, values + 8, sizeof(out->specular));
    memcpy(out->position, values + 12, sizeof(out->position));
    memcpy(out->direction, values + 16, sizeof(out->direction));
    memcpy(out->parameters, values + 20, sizeof(out->parameters));
    memcpy(out->transform, values + 25, sizeof(out->transform));
    return DC_OK;
}

dc_status dc_xl_probe(const void *source, size_t length, dc_xl_info *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    const uint8_t *bytes = (const uint8_t *)source;
    if (length < DC_XL_HEADER || memcmp(bytes, "LLL\0", 4) != 0) return DC_FORMAT;
    uint32_t count = bytes[4];
    if (!count || count > DC_XL_MAX_LIGHTS) return DC_FORMAT;
    if (length != DC_XL_HEADER + (size_t)count * DC_XL_RECORD) return DC_FORMAT;
    for (uint32_t i = 0; i < count; ++i) {
        dc_xl_light view;
        dc_status status = light_at_internal(bytes, length, i, &view);
        if (status != DC_OK) return status;
    }
    dc_xl_info next = {count, length};
    *out = next;
    return DC_OK;
}

dc_status dc_xl_light_at(const void *source, size_t length, uint32_t index,
                         dc_xl_light *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_xl_info info;
    dc_status status = dc_xl_probe(source, length, &info);
    if (status != DC_OK) return status;
    return light_at_internal((const uint8_t *)source, length, index, out);
}
