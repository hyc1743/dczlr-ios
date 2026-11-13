#include "dc_xl.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DC_XL_HEADER 5u
#define DC_XL_MAX_LIGHTS 64u
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

static dc_status parse_record(const uint8_t *source, size_t length,
                              size_t *cursor, dc_xl_light *out) {
    if (!source || !cursor || !out) return DC_ARGUMENT;
    size_t record = *cursor;
    if (!range_ok(length, record, 4)) return DC_FORMAT;
    size_t position = record;
    uint32_t name_length = little32(source + position);
    position += 4;
    if (!name_length || name_length > 64 || !range_ok(length, position, name_length) ||
        !encoded_string_ok(source + position, name_length)) return DC_FORMAT;
    dc_xl_span name = {position, name_length};
    position += name_length;
    if (!range_ok(length, position, 4)) return DC_FORMAT;
    uint32_t target_length = little32(source + position);
    position += 4;
    if (!target_length || target_length > 128 || !range_ok(length, position, target_length) ||
        !encoded_string_ok(source + position, target_length)) return DC_FORMAT;
    dc_xl_span target = {position, target_length};
    position += target_length;
    if (!range_ok(length, position, 5 + DC_XL_FLOATS * sizeof(float))) return DC_FORMAT;
    uint8_t kind = source[position++];
    uint8_t enabled = source[position++];
    uint8_t flags[3] = {source[position], source[position + 1], source[position + 2]};
    position += 3;
    float values[DC_XL_FLOATS];
    memcpy(values, source + position, sizeof(values));
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
    *cursor = position + sizeof(values);
    return DC_OK;
}

dc_status dc_xl_probe(const void *source, size_t length, dc_xl_info *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    const uint8_t *bytes = (const uint8_t *)source;
    if (length < DC_XL_HEADER) return DC_FORMAT;
    uint32_t count = bytes[4];
    if (!count || count > DC_XL_MAX_LIGHTS) return DC_FORMAT;
    size_t cursor = DC_XL_HEADER;
    for (uint32_t i = 0; i < count; ++i) {
        dc_xl_light view;
        dc_status status = parse_record(bytes, length, &cursor, &view);
        if (status != DC_OK) return status;
    }
    if (cursor != length) return DC_FORMAT;
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
    if (index >= info.lights) return DC_RANGE;
    size_t cursor = DC_XL_HEADER;
    for (uint32_t current = 0; current <= index; ++current) {
        status = parse_record((const uint8_t *)source, length, &cursor, out);
        if (status != DC_OK) return status;
    }
    return DC_OK;
}

dc_status dc_xl_d3d_light_at(const void *source, size_t length, uint32_t index,
                             dc_xl_d3d_light *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    dc_xl_light raw;
    dc_status status = dc_xl_light_at(source, length, index, &raw);
    if (status != DC_OK) return status;
    float values[DC_XL_FLOATS];
    memcpy(values + 0, raw.diffuse, 4 * sizeof(float));
    memcpy(values + 4, raw.ambient, 4 * sizeof(float));
    memcpy(values + 8, raw.specular, 4 * sizeof(float));
    memcpy(values + 12, raw.position, 4 * sizeof(float));
    memcpy(values + 16, raw.direction, 4 * sizeof(float));
    memcpy(values + 20, raw.parameters, 5 * sizeof(float));
    memcpy(values + 25, raw.transform, 16 * sizeof(float));

    dc_xl_d3d_light parsed;
    memset(&parsed, 0, sizeof(parsed));
    parsed.name = raw.name;
    parsed.target = raw.target;
    parsed.mode = raw.kind;
    parsed.d3d_type = (uint32_t)raw.enabled |
                      ((uint32_t)raw.flags[0] << 8) |
                      ((uint32_t)raw.flags[1] << 16) |
                      ((uint32_t)raw.flags[2] << 24);
    memcpy(parsed.diffuse, values + 0, 4 * sizeof(float));
    memcpy(parsed.specular, values + 4, 4 * sizeof(float));
    memcpy(parsed.ambient, values + 8, 4 * sizeof(float));
    memcpy(parsed.position, values + 12, 3 * sizeof(float));
    memcpy(parsed.direction, values + 15, 3 * sizeof(float));
    parsed.range = values[18];
    parsed.falloff = values[19];
    memcpy(parsed.attenuation, values + 20, 3 * sizeof(float));
    parsed.theta = values[23];
    parsed.phi = values[24];
    memcpy(parsed.transform, values + 25, 16 * sizeof(float));
    *out = parsed;
    return DC_OK;
}

dc_status dc_xl_ambient(const void *source, size_t length, float out_rgb[3]) {
    if (!source || !out_rgb || overlap(source, length, out_rgb, 3 * sizeof(float)))
        return DC_ARGUMENT;
    dc_xl_info info;
    dc_status status = dc_xl_probe(source, length, &info);
    if (status != DC_OK) return status;
    const uint8_t *b = (const uint8_t *)source;
    out_rgb[0] = (float)b[2] * (1.f / 255.f);
    out_rgb[1] = (float)b[1] * (1.f / 255.f);
    out_rgb[2] = (float)b[0] * (1.f / 255.f);
    return DC_OK;
}

static float read_f32_le(const uint8_t *p) {
    uint32_t bits = little32(p);
    float val = 0.f;
    memcpy(&val, &bits, sizeof(val));
    return val;
}

dc_status dc_glare_probe(const void *source, size_t length, dc_glare_info *out) {
    if (!source || !out || overlap(source, length, out, sizeof(*out))) return DC_ARGUMENT;
    if (length != 26u) return DC_FORMAT;
    const uint8_t *b = (const uint8_t *)source;
    dc_glare_info info = {0};
    info.scale = read_f32_le(b + 0);
    info.flag = b[4];
    info.threshold = read_f32_le(b + 5);
    info.intensity = read_f32_le(b + 9);
    info.spread = read_f32_le(b + 13);
    info.passes = b[17];
    info.power_a = read_f32_le(b + 18);
    info.power_b = read_f32_le(b + 22);
    if (!isfinite(info.scale) || !isfinite(info.threshold) || !isfinite(info.intensity) ||
        !isfinite(info.spread) || !isfinite(info.power_a) || !isfinite(info.power_b) ||
        info.threshold < 0.f || info.threshold > 2.f || info.passes > 8u)
        return DC_FORMAT;
    *out = info;
    return DC_OK;
}

dc_status dc_glare_apply_rgba(const dc_glare_info *glare,
                              uint8_t *rgba, uint32_t width, uint32_t height) {
    if (!glare || !rgba || !width || !height || width > 4096u || height > 4096u)
        return DC_ARGUMENT;
    if (!isfinite(glare->threshold) || !isfinite(glare->intensity) || !isfinite(glare->spread))
        return DC_RANGE;
    if (glare->intensity <= 0.f || glare->passes == 0u) return DC_OK;
    uint32_t bw = width >= 4u ? width / 2u : width;
    uint32_t bh = height >= 4u ? height / 2u : height;
    size_t count = (size_t)bw * bh * 3u;
    float *buf_a = (float *)calloc(count, sizeof(float));
    float *buf_b = (float *)calloc(count, sizeof(float));
    if (!buf_a || !buf_b) {
        free(buf_a);
        free(buf_b);
        return DC_MEMORY;
    }
    float thresh = fmaxf(0.f, fminf(1.f, glare->threshold));
    float inv_span = 1.f / fmaxf(0.05f, 1.f - thresh);
    for (uint32_t y = 0; y < bh; ++y) {
        uint32_t sy = (y * height) / bh;
        for (uint32_t x = 0; x < bw; ++x) {
            uint32_t sx = (x * width) / bw;
            const uint8_t *px = rgba + ((size_t)sy * width + sx) * 4u;
            float r = (float)px[0] * (1.f / 255.f);
            float g = (float)px[1] * (1.f / 255.f);
            float b = (float)px[2] * (1.f / 255.f);
            float lum = 0.299f * r + 0.587f * g + 0.114f * b;
            size_t dst = ((size_t)y * bw + x) * 3u;
            if (lum > thresh) {
                float k = (lum - thresh) * inv_span;
                buf_a[dst + 0] = r * k;
                buf_a[dst + 1] = g * k;
                buf_a[dst + 2] = b * k;
            }
        }
    }
    static const float kWeights[5] = {0.227027f, 0.1945946f, 0.1216216f, 0.054054f, 0.016216f};
    uint32_t passes = glare->passes > 4u ? 4u : glare->passes;
    int step = glare->spread > 1.2f ? 2 : 1;
    for (uint32_t p = 0; p < passes; ++p) {
        for (uint32_t y = 0; y < bh; ++y) {
            for (uint32_t x = 0; x < bw; ++x) {
                float acc[3] = {
                    buf_a[((size_t)y * bw + x) * 3u + 0] * kWeights[0],
                    buf_a[((size_t)y * bw + x) * 3u + 1] * kWeights[0],
                    buf_a[((size_t)y * bw + x) * 3u + 2] * kWeights[0]
                };
                for (int t = 1; t < 5; ++t) {
                    int xl = (int)x - t * step; if (xl < 0) xl = 0;
                    int xr = (int)x + t * step; if (xr >= (int)bw) xr = (int)bw - 1;
                    const float *pl = buf_a + ((size_t)y * bw + (size_t)xl) * 3u;
                    const float *pr = buf_a + ((size_t)y * bw + (size_t)xr) * 3u;
                    for (int c = 0; c < 3; ++c) acc[c] += (pl[c] + pr[c]) * kWeights[t];
                }
                size_t dst = ((size_t)y * bw + x) * 3u;
                buf_b[dst + 0] = acc[0]; buf_b[dst + 1] = acc[1]; buf_b[dst + 2] = acc[2];
            }
        }
        for (uint32_t y = 0; y < bh; ++y) {
            for (uint32_t x = 0; x < bw; ++x) {
                float acc[3] = {
                    buf_b[((size_t)y * bw + x) * 3u + 0] * kWeights[0],
                    buf_b[((size_t)y * bw + x) * 3u + 1] * kWeights[0],
                    buf_b[((size_t)y * bw + x) * 3u + 2] * kWeights[0]
                };
                for (int t = 1; t < 5; ++t) {
                    int yu = (int)y - t * step; if (yu < 0) yu = 0;
                    int yd = (int)y + t * step; if (yd >= (int)bh) yd = (int)bh - 1;
                    const float *pu = buf_b + ((size_t)yu * bw + x) * 3u;
                    const float *pd = buf_b + ((size_t)yd * bw + x) * 3u;
                    for (int c = 0; c < 3; ++c) acc[c] += (pu[c] + pd[c]) * kWeights[t];
                }
                size_t dst = ((size_t)y * bw + x) * 3u;
                buf_a[dst + 0] = acc[0]; buf_a[dst + 1] = acc[1]; buf_a[dst + 2] = acc[2];
            }
        }
    }
    float gain = glare->intensity * (glare->scale > 0.f ? glare->scale : 1.f);
    for (uint32_t y = 0; y < height; ++y) {
        uint32_t by = (y * bh) / height;
        if (by >= bh) by = bh - 1u;
        for (uint32_t x = 0; x < width; ++x) {
            uint32_t bx = (x * bw) / width;
            if (bx >= bw) bx = bw - 1u;
            const float *bl = buf_a + ((size_t)by * bw + bx) * 3u;
            uint8_t *px = rgba + ((size_t)y * width + x) * 4u;
            for (int c = 0; c < 3; ++c) {
                float v = (float)px[c] + bl[c] * gain * 255.f;
                px[c] = (uint8_t)(v >= 255.f ? 255u : (v <= 0.f ? 0u : (uint32_t)(v + 0.5f)));
            }
        }
    }
    free(buf_a);
    free(buf_b);
    return DC_OK;
}
