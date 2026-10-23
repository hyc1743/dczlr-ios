#include "dc_pp.h"
#include <stdlib.h>
#include <string.h>

#define DC_PP_MAX_ENTRIES 65535u

struct dc_pp {
    dc_source source;
    uint32_t count;
    dc_pp_entry *entries;
};

static uint32_t little32(const uint8_t bytes[4]) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

dc_status dc_pp_decode_bytes(void *bytes, size_t length) {
    uint8_t *out = (uint8_t *)bytes;
    if (length && !out) return DC_ARGUMENT;
    for (size_t i = 0; i < length; ++i) out[i] = (uint8_t)(0u - out[i]);
    return DC_OK;
}

dc_status dc_pp_open(const dc_source *source, dc_pp **out) {
    uint8_t header[8];
    if (!out) return DC_ARGUMENT;
    *out = NULL;
    if (!source || !source->read_at) return DC_ARGUMENT;
    if (source->length < sizeof(header)) return DC_FORMAT;
    if (!source->read_at(source->context, 0, header, sizeof(header))) return DC_IO;
    uint32_t count = little32(header);
    uint32_t payload_size = little32(header + 4);
    if (count > DC_PP_MAX_ENTRIES) return DC_FORMAT;
    uint64_t payload_start = 8u + (uint64_t)count * 36u;
    if (payload_start > source->length ||
        source->length - payload_start != payload_size) return DC_FORMAT;
    dc_pp *archive = (dc_pp *)calloc(1, sizeof(*archive));
    if (!archive) return DC_MEMORY;
    archive->source = *source;
    archive->count = count;
    if (count) {
        archive->entries = (dc_pp_entry *)calloc(count, sizeof(*archive->entries));
        if (!archive->entries) {
            dc_pp_close(archive);
            return DC_MEMORY;
        }
    }
    uint64_t position = payload_start;
    for (uint32_t i = 0; i < count; ++i) {
        dc_pp_entry *entry = archive->entries + i;
        uint8_t size_bytes[4];
        if (!source->read_at(source->context, 8u + (uint64_t)i * 32u, entry->name, 32) ||
            !source->read_at(source->context, 8u + (uint64_t)count * 32u + (uint64_t)i * 4u,
                             size_bytes, sizeof(size_bytes))) {
            dc_pp_close(archive);
            return DC_IO;
        }
        dc_pp_decode_bytes(entry->name, 32);
        while (entry->name_length < 32 && entry->name[entry->name_length]) ++entry->name_length;
        entry->size = little32(size_bytes);
        entry->offset = position;
        if (position > source->length || entry->size > source->length - position) {
            dc_pp_close(archive);
            return DC_FORMAT;
        }
        position += entry->size;
    }
    if (position != source->length) {
        dc_pp_close(archive);
        return DC_FORMAT;
    }
    *out = archive;
    return DC_OK;
}

void dc_pp_close(dc_pp *archive) {
    if (archive) {
        free(archive->entries);
        free(archive);
    }
}

uint32_t dc_pp_count(const dc_pp *archive) { return archive ? archive->count : 0; }

dc_status dc_pp_entry_at(const dc_pp *archive, uint32_t index, dc_pp_entry *out) {
    if (!archive || !out) return DC_ARGUMENT;
    if (index >= archive->count) return DC_RANGE;
    *out = archive->entries[index];
    return DC_OK;
}

dc_status dc_pp_find_exact(const dc_pp *archive, const void *name, size_t length, uint32_t *index) {
    if (!archive || !name || !index) return DC_ARGUMENT;
    for (uint32_t i = 0; i < archive->count; ++i) {
        const dc_pp_entry *entry = archive->entries + i;
        if (length == entry->name_length && !memcmp(name, entry->name, length)) {
            *index = i;
            return DC_OK;
        }
    }
    return DC_NOT_FOUND;
}

dc_status dc_pp_read(const dc_pp *archive, uint32_t index, uint64_t offset, void *out, size_t length) {
    if (!archive || (length && !out)) return DC_ARGUMENT;
    if (index >= archive->count) return DC_RANGE;
    const dc_pp_entry *entry = archive->entries + index;
    if (offset > entry->size || length > entry->size - offset) return DC_RANGE;
    if (!length) return DC_OK;
    if (!archive->source.read_at(archive->source.context, entry->offset + offset, out, length)) return DC_IO;
    return dc_pp_decode_bytes(out, length);
}
