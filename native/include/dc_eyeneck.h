#ifndef DC_EYENECK_H
#define DC_EYENECK_H

#include <stddef.h>
#include <stdint.h>

#include "dc_pp.h"

#ifdef __cplusplus
extern "C" {
#endif

enum dc_eyeneck_kind {
    DC_EYENECK_EYES = 1,
    DC_EYENECK_NECK = 2
};

typedef struct dc_eyeneck_span {
    size_t offset;
    uint32_t length;
} dc_eyeneck_span;

typedef struct dc_eyeneck_info {
    uint32_t kind;
    uint32_t targets;
    uint32_t records;
    size_t body_offset;
    size_t parsed_bytes;
} dc_eyeneck_info;

/* Bounded admission for the two local RPP_04 special-state profiles. The
 * payload body remains opaque; target names and exact framing are exposed so
 * callers can bind them without inventing eye/neck control semantics. */
DC_API dc_status dc_eyeneck_probe(const void *source, size_t length,
                                  dc_eyeneck_info *out);
DC_API dc_status dc_eyeneck_target_at(const void *source, size_t length,
                                      uint32_t index, dc_eyeneck_span *out);

#ifdef __cplusplus
}
#endif

#endif
