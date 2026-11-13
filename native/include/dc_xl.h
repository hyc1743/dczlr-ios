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
    float parameters[5];
    float transform[16];
} dc_xl_light;

typedef struct dc_xl_d3d_light {
    dc_xl_span name;
    dc_xl_span target;
    uint8_t mode;
    uint32_t d3d_type; /* 1=POINT, 2=SPOT, 3=DIRECTIONAL */
    float diffuse[4];
    float specular[4];
    float ambient[4];
    float position[3];
    float direction[3];
    float range;
    float falloff;
    float attenuation[3];
    float theta;
    float phi;
    float transform[16];
} dc_xl_d3d_light;

/* Strict local profile: a four-byte prefix, one-byte light count, then
 * length-prefixed records with a five-byte tag header and 41 floats. RPP_07
 * uses the "LLL\\0" prefix and four records; RPP_10 map variants use opaque
 * four-byte prefixes and one record. Unknown tag bytes are preserved in the
 * view while the numeric payload is exposed for the renderer. */
DC_API dc_status dc_xl_probe(const void *source, size_t length, dc_xl_info *out);
DC_API dc_status dc_xl_light_at(const void *source, size_t length, uint32_t index,
                                dc_xl_light *out);
DC_API dc_status dc_xl_d3d_light_at(const void *source, size_t length, uint32_t index,
                                    dc_xl_d3d_light *out);
/* Extracts the 4-byte D3DCOLOR D3DRS_AMBIENT header (BGRA -> RGB in [0,1])
 * copied into [model + 0x2b0] by 0x0040a870. */
DC_API dc_status dc_xl_ambient(const void *source, size_t length, float out_rgb[3]);

typedef struct dc_glare_info {
    float scale;
    uint8_t flag;
    float threshold;
    float intensity;
    float spread;
    uint8_t passes;
    float power_a;
    float power_b;
} dc_glare_info;

/* Bounded 26-byte RPP_10 .glare post-bloom profile (e.g. mm00_07.glare) and
 * separable IDR_GLARE bright-pass Gaussian additive bloom filter. */
DC_API dc_status dc_glare_probe(const void *source, size_t length, dc_glare_info *out);
DC_API dc_status dc_glare_apply_rgba(const dc_glare_info *glare,
                                     uint8_t *rgba, uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif

#endif
