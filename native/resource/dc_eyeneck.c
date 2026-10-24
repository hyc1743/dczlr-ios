#include "dc_eyeneck.h"

#include <string.h>

static int overlap(const void *a, size_t al, const void *b, size_t bl) {
    uintptr_t aa = (uintptr_t)a, bb = (uintptr_t)b;
    return al && bl && (aa <= bb ? bb - aa < al : aa - bb < bl);
}

static uint32_t little32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int range_ok(size_t length, size_t offset, size_t span) {
    return offset <= length && span <= length - offset;
}

static int encoded_name_ok(const uint8_t *source, size_t length) {
    if (!length) return 0;
    for (size_t i = 0; i < length; ++i)
        if (!source[i] || source[i] == 0xffu) return 0;
    return 1;
}

static dc_status parse(const uint8_t *source, size_t length,
                       dc_eyeneck_info *info, dc_eyeneck_span spans[2]) {
    if (!source || !info) return DC_ARGUMENT;
    if (!length || source[0] != 0) return DC_FORMAT;
    size_t cursor = 1;
    if (!range_ok(length, cursor, 1)) return DC_FORMAT;
    uint32_t first_length = source[cursor++];
    if (!first_length || first_length > 64 || !range_ok(length, cursor, first_length) ||
        !encoded_name_ok(source + cursor, first_length)) return DC_FORMAT;
    spans[0] = (dc_eyeneck_span){cursor, first_length};
    cursor += first_length;
    uint32_t targets = 1;
    uint32_t kind = DC_EYENECK_NECK;
    uint32_t records = 3;
    if (range_ok(length, cursor, 1)) {
        uint32_t second_length = source[cursor];
        if (second_length && second_length <= 64 &&
            range_ok(length, cursor + 1, 1u + second_length) &&
            encoded_name_ok(source + cursor + 1, second_length)) {
            ++cursor;
            spans[1] = (dc_eyeneck_span){cursor, second_length};
            cursor += second_length;
            targets = 2;
            kind = DC_EYENECK_EYES;
            records = 5;
        }
    }
    if (!range_ok(length, cursor, 4)) return DC_FORMAT;
    uint32_t serialized_records = little32(source + cursor);
    cursor += 4;
    if (serialized_records != records || !range_ok(length, cursor, 4) ||
        memcmp(source + cursor, "\x04pvu", 4) != 0) return DC_FORMAT;
    size_t expected = kind == DC_EYENECK_EYES ? 326u : 197u;
    if (length != expected || cursor > length) return DC_FORMAT;
    dc_eyeneck_info next = {kind, targets, records, cursor, length};
    *info = next;
    return DC_OK;
}

dc_status dc_eyeneck_probe(const void *source, size_t length,
                           dc_eyeneck_info *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_eyeneck_span spans[2];
    return parse((const uint8_t *)source, length, out, spans);
}

dc_status dc_eyeneck_target_at(const void *source, size_t length,
                               uint32_t index, dc_eyeneck_span *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_eyeneck_info info;
    dc_eyeneck_span spans[2];
    dc_status status = parse((const uint8_t *)source, length, &info, spans);
    if (status != DC_OK) return status;
    if (index >= info.targets) return DC_RANGE;
    *out = spans[index];
    return DC_OK;
}
