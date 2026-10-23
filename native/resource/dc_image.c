#include "dc_image.h"
#include <limits.h>
#include <string.h>

typedef struct image_layout {
    dc_image_info info;
    const uint8_t *pixels;
    size_t stride;
    unsigned pixel_bytes;
    unsigned top_origin;
    unsigned right_origin;
    unsigned rle;
} image_layout;

static uint16_t le16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static dc_status dimensions(image_layout *layout, uint32_t width, uint32_t height) {
    if (!width || !height) return DC_FORMAT;
    if (width > SIZE_MAX / 4u / height) return DC_RANGE;
    layout->info.width = width;
    layout->info.height = height;
    layout->info.rgba_bytes = (size_t)width * height * 4u;
    return DC_OK;
}

static dc_status parse_bmp(const uint8_t *data, size_t length, image_layout *layout,
                            unsigned ema) {
    if (length < 54 ||
        (memcmp(data, "BM", 2) && !(ema && data[0] == 0 && data[1] == 0)) ||
        le32(data + 14) != 40 ||
        le16(data + 26) != 1 || le16(data + 28) != 24 || le32(data + 30) != 0)
        return DC_FORMAT;
    uint32_t width = le32(data + 18), raw_height = le32(data + 22);
    if (width > INT32_MAX || raw_height == 0x80000000u) return DC_FORMAT;
    layout->top_origin = raw_height > INT32_MAX;
    uint32_t height = layout->top_origin ? 0u - raw_height : raw_height;
    dc_status status = dimensions(layout, width, height);
    if (status != DC_OK) return status;
    /* dimensions() has already proved that 4*width fits in size_t. */
    layout->stride = ((size_t)width * 3u + 3u) & ~(size_t)3u;
    size_t offset = le32(data + 10), file_size = le32(data + 2);
    if (offset < 54 || file_size > length || offset > file_size ||
        height > (file_size - offset) / layout->stride) return DC_FORMAT;
    size_t image_size = le32(data + 34);
    if (image_size && (image_size < layout->stride * height ||
                       image_size > file_size - offset)) return DC_FORMAT;
    layout->pixels = data + offset;
    layout->pixel_bytes = 3;
    return DC_OK;
}

static dc_status parse_tga(const uint8_t *data, size_t length, image_layout *layout) {
    if (length < 18 || data[1] || le16(data + 3) || le16(data + 5) || data[7] ||
        (data[2] != 2 && data[2] != 10) || (data[17] & 0xc0) ||
        !((data[16] == 24 && (data[17] & 15) == 0) ||
          (data[16] == 32 && (data[17] & 15) == 8))) return DC_FORMAT;
    dc_status status = dimensions(layout, le16(data + 12), le16(data + 14));
    if (status != DC_OK) return status;
    size_t offset = 18u + data[0];
    if (offset > length) return DC_FORMAT;
    layout->pixel_bytes = data[16] / 8u;
    layout->top_origin = (data[17] & 0x20) != 0;
    layout->right_origin = (data[17] & 0x10) != 0;
    layout->rle = data[2] == 10;
    layout->pixels = data + offset;
    size_t count = layout->info.rgba_bytes / 4u;
    if (!layout->rle) {
        if (count > (length - offset) / layout->pixel_bytes) return DC_FORMAT;
        layout->stride = (size_t)layout->info.width * layout->pixel_bytes;
    } else {
        /* Validate all packets before the first destination write. */
        while (count) {
            if (offset == length) return DC_FORMAT;
            uint8_t packet = data[offset++];
            size_t run = (packet & 127u) + 1u;
            if (run > count) return DC_FORMAT;
            size_t bytes = (packet & 128u ? 1u : run) * layout->pixel_bytes;
            if (bytes > length - offset) return DC_FORMAT;
            offset += bytes;
            count -= run;
        }
    }
    return DC_OK;
}

static dc_status parse(const void *data, size_t length, dc_image_format format,
                       image_layout *layout) {
    if (!data) return DC_ARGUMENT;
    memset(layout, 0, sizeof(*layout));
    const uint8_t *bytes = data;
    if (format == DC_IMAGE_BMP) return parse_bmp(bytes, length, layout, 0);
    if (format == DC_IMAGE_TGA) return parse_tga(bytes, length, layout);
    if (format != DC_IMAGE_EMA) return DC_ARGUMENT;
    if (length < 13) return DC_FORMAT;
    dc_status status;
    if (!memcmp(bytes + 8, ".bmp\0", 5))
        status = parse_bmp(bytes + 13, length - 13, layout, 1);
    else if (!memcmp(bytes + 8, ".tga\0", 5))
        status = parse_tga(bytes + 13, length - 13, layout);
    else return DC_FORMAT;
    if (status != DC_OK) return status;
    if (le32(bytes) != layout->info.width || le32(bytes + 4) != layout->info.height)
        return DC_FORMAT;
    return DC_OK;
}

dc_status dc_image_probe(const void *data, size_t length, dc_image_format format,
                         dc_image_info *info) {
    if (!info) return DC_ARGUMENT;
    image_layout layout;
    dc_status status = parse(data, length, format, &layout);
    if (status == DC_OK) *info = layout.info;
    return status;
}

static void write_pixel(const image_layout *layout, uint8_t *rgba, size_t index,
                         const uint8_t *pixel) {
    size_t x = index % layout->info.width, y = index / layout->info.width;
    if (layout->right_origin) x = layout->info.width - 1u - x;
    if (!layout->top_origin) y = layout->info.height - 1u - y;
    uint8_t *out = rgba + (y * layout->info.width + x) * 4u;
    out[0] = pixel[2]; out[1] = pixel[1]; out[2] = pixel[0];
    out[3] = layout->pixel_bytes == 4 ? pixel[3] : 255;
}

dc_status dc_image_decode(const void *data, size_t length, dc_image_format format,
                          void *rgba, size_t capacity, dc_image_info *info) {
    if (!rgba) return DC_ARGUMENT;
    image_layout layout;
    dc_status status = parse(data, length, format, &layout);
    if (status != DC_OK) return status;
    if (capacity < layout.info.rgba_bytes) return DC_RANGE;
    uintptr_t in = (uintptr_t)data, out = (uintptr_t)rgba;
    if ((out >= in && out - in < length) ||
        (in >= out && in - out < layout.info.rgba_bytes)) return DC_ARGUMENT;
    size_t count = layout.info.rgba_bytes / 4u;
    if (layout.rle) {
        const uint8_t *pixel = layout.pixels;
        size_t index = 0;
        while (index < count) {
            uint8_t packet = *pixel++;
            size_t run = (packet & 127u) + 1u;
            for (size_t i = 0; i < run; ++i) {
                write_pixel(&layout, rgba, index++, pixel);
                if (!(packet & 128u)) pixel += layout.pixel_bytes;
            }
            if (packet & 128u) pixel += layout.pixel_bytes;
        }
    } else {
        for (size_t y = 0; y < layout.info.height; ++y)
            for (size_t x = 0; x < layout.info.width; ++x)
                write_pixel(&layout, rgba, y * layout.info.width + x,
                            layout.pixels + y * layout.stride + x * layout.pixel_bytes);
    }
    if (info) *info = layout.info;
    return DC_OK;
}
