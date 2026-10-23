#ifndef DC_IMAGE_H
#define DC_IMAGE_H

#include "dc_pp.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum dc_image_format {
    DC_IMAGE_BMP = 1,
    DC_IMAGE_TGA = 2,
    DC_IMAGE_EMA = 3
} dc_image_format;

typedef struct dc_image_info {
    uint32_t width;
    uint32_t height;
    size_t rgba_bytes;
} dc_image_info;

/* Observed profiles: BITMAPINFOHEADER uncompressed 24-bit BMP; unmapped,
 * noninterleaved 24/32-bit truecolor TGA (raw or RLE); EMA's two LE uint32
 * dimensions, five-byte ".bmp\0"/".tga\0" tag and matching embedded image.
 * EMA BMP permits a zeroed two-byte signature, restored by the original loader.
 * Unknown profiles fail. Optional TGA metadata after pixels is not decoded.
 * Probe validates the complete pixel stream without allocating an image. */
DC_API dc_status dc_image_probe(const void *data, size_t length,
                                dc_image_format format, dc_image_info *info);
/* Tightly packed, top-left RGBA8, straight alpha; BMP/24-bit TGA alpha is 255.
 * Caller owns both buffers; input and output must not overlap. No allocation.
 * Capacity is checked before writing; every failure leaves output unchanged.
 * The input must remain immutable during the call. info may be NULL here. */
DC_API dc_status dc_image_decode(const void *data, size_t length,
                                 dc_image_format format, void *rgba,
                                 size_t capacity, dc_image_info *info);

#ifdef __cplusplus
}
#endif
#endif
