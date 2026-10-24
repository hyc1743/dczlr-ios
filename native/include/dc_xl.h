#ifndef DC_XL_H
#define DC_XL_H

#include <stddef.h>
#include <stdint.h>

#include "dc_pp.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The observed .xl light archive is a compact table used by the map scene.
 * Strings retain the game's byte encoding (each byte XOR 0xff, including the
 * 0xff terminator); callers may decode them without copying the source. */
typedef struct dc_xl_span {
    size_t offset;
    uint32_t length;
} dc_xl_span;

typedef struct dc_xl_info {
    uint32_t lights;
    size_t parsed_bytes;
} dc_xl_info;

typedef struct dc_xl_light {
    dc_xl_span name;
    dc_xl_span target;
    uint8_t kind;
    uint8_t enabled;
    uint8_t flags[3];
    float diffuse[4];
    float ambient[4];
    float specular[4];
    float position[4];
    float direction[4];
    float parameters[6];
    float transform[16];
} dc_xl_light;

/* Strict local profile: magic "LLL\\0", one-byte light count, then exactly
 * 197 bytes per record. Unknown tag bytes are preserved in the view while
 * the numeric payload is exposed for the renderer. */
DC_API dc_status dc_xl_probe(const void *source, size_t length, dc_xl_info *out);
DC_API dc_status dc_xl_light_at(const void *source, size_t length, uint32_t index,
                                dc_xl_light *out);

#ifdef __cplusplus
}
#endif

#endif
