#include "dc_sprite.h"
#include <math.h>
#include <string.h>

_Static_assert(sizeof(dc_sprite_pose) == 18 * sizeof(float), "sprite pose layout");
_Static_assert(sizeof(dc_sprite_vertex) == 32, "sprite vertex stride");

static int valid_int32(double value) {
    return value >= -2147483648.0 && value < 2147483648.0;
}

dc_status dc_sprite_build_vertices(const dc_sprite_pose *pose, dc_sprite_vertex vertices[4]) {
    if (!pose || !vertices) return DC_ARGUMENT;
    float values[18];
    memcpy(values, pose, sizeof(values));
    for (size_t i = 0; i < 18; ++i)
        if (!isfinite(values[i])) return DC_FORMAT;
    float width = (float)((double)pose->width * pose->scale_x);
    float height = (float)((double)pose->height * pose->scale_y);
    if (!isfinite(width) || !isfinite(height)) return DC_RANGE;
    double channels[] = {(double)pose->blue * 255, (double)pose->green * 255,
                         (double)pose->red * 255, (double)pose->alpha * 255};
    uint32_t color = 0;
    for (size_t i = 0; i < 4; ++i) {
        if (!valid_int32(channels[i])) return DC_RANGE;
        color |= ((uint32_t)(int32_t)channels[i] & 255u) << (i * 8);
    }
    dc_sprite_vertex out[4];
    memset(out, 0, sizeof(out));
    if (pose->rotation == 0) {
        float left = (float)((double)pose->x - (double)width * pose->origin_x);
        float top = (float)((double)pose->y - (double)height * pose->origin_y);
        if (!valid_int32(left) || !valid_int32(top)) return DC_RANGE;
        left = (float)(int32_t)left;
        top = (float)(int32_t)top;
        out[0].x = out[1].x = left;
        out[0].y = out[2].y = top;
        out[2].x = out[3].x = (float)((double)left + width);
        out[1].y = out[3].y = (float)((double)top + height);
    } else {
        float left = (float)(-((double)width * pose->origin_x));
        float right = (float)((1.0 - pose->origin_x) * width);
        float top = (float)(-((double)height * pose->origin_y));
        float bottom = (float)((1.0 - pose->origin_y) * height);
        float cosine = cosf(pose->rotation), sine = sinf(pose->rotation);
        float xs[] = {left, left, right, right};
        float ys[] = {top, bottom, top, bottom};
        for (size_t i = 0; i < 4; ++i) {
            float rotated_x = (float)((double)xs[i] * cosine - (double)ys[i] * sine);
            float rotated_y = (float)((double)xs[i] * sine + (double)ys[i] * cosine);
            out[i].x = (float)((double)rotated_x + pose->x);
            out[i].y = (float)((double)rotated_y + pose->y);
        }
    }
    for (size_t i = 0; i < 4; ++i) {
        if (!isfinite(out[i].x) || !isfinite(out[i].y)) return DC_RANGE;
        out[i].z = pose->z;
        out[i].rhw = 1;
        out[i].diffuse = color;
        out[i].specular = 0xff000000;
        out[i].u = i < 2 ? pose->u0 : pose->u1;
        out[i].v = i % 2 ? pose->v1 : pose->v0;
    }
    memcpy(vertices, out, sizeof(out));
    return DC_OK;
}
