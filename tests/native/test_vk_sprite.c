#include "dc_vk_sprite.h"
#include "dc_sprite_spv.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL line %d: %s (%s)\n", __LINE__, #expr, dc_vk_sprite_error(r)); goto failed; } } while (0)
#define OK(expr) CHECK((expr) == DC_OK)

static dc_sprite_pose pose(float u, float v) {
    dc_sprite_pose p = {.width = 4, .height = 4, .x = 2, .y = 2, .z = 0.5f,
        .scale_x = 1, .scale_y = 1, .alpha = 1, .red = 1, .green = 1, .blue = 1,
        .u0 = u, .u1 = u, .v0 = v, .v1 = v};
    return p;
}

static int pixel(const uint8_t *rgba, unsigned x, unsigned y, int red, int green, int blue, int alpha, int tolerance) {
    const uint8_t *p = rgba + (y * 8 + x) * 4;
    int e[4] = {red, green, blue, alpha};
    for (int c = 0; c < 4; ++c) if (abs((int)p[c] - e[c]) > tolerance) {
        fprintf(stderr, "Pixel %u,%u = [%u,%u,%u,%u], expected [%d,%d,%d,%d] +/- %d\n",
            x, y, p[0], p[1], p[2], p[3], red, green, blue, alpha, tolerance);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    dc_vk_sprite *r = NULL;
    dc_vk_sprite_config config = {.width = 8, .height = 8, .max_textures = 2, .initial_filter = 2,
        .validation = 1, .vertex_spirv = dc_sprite_vert_spv, .vertex_spirv_bytes = sizeof(dc_sprite_vert_spv),
        .fragment_spirv = dc_sprite_frag_spv, .fragment_spirv_bytes = sizeof(dc_sprite_frag_spv)};
    char error[512];
    /* MoltenVK builds may omit the optional Khronos layer; Linux CI requires it. */
    if (argc > 1 && !strcmp(argv[1], "--no-validation")) config.validation = 0;
    dc_status status = dc_vk_sprite_create(&config, &r, error, sizeof(error));
    if (status != DC_OK) { fprintf(stderr, "Create failed: %s\n", error); return 1; }
    dc_vk_sprite_info info;
    OK(dc_vk_sprite_get_info(r, &info));
    printf("Vulkan device: %s (type=%u api=%u validation=%u)\n", info.device_name, info.device_type, info.api_version, config.validation);
    uint8_t rgba[8 * 8 * 4], before[sizeof(rgba)];
    const uint8_t clear[4] = {20, 40, 60, 100};
    const uint8_t checker[16] = {255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255};
    const uint8_t translucent[4] = {200,100,50,128};
    uintptr_t texture, transparent, extra = 999;
    OK(dc_vk_sprite_upload(r, 2, 2, checker, sizeof(checker), &texture));
    OK(dc_vk_sprite_upload(r, 1, 1, translucent, sizeof(translucent), &transparent));
    CHECK(dc_vk_sprite_upload(r, 1, 1, translucent, 4, &extra) == DC_RANGE && extra == 999);
    OK(dc_vk_sprite_render(r, NULL, 0, clear, rgba, sizeof(rgba)));
    for (unsigned y = 0; y < 8; ++y) for (unsigned x = 0; x < 8; ++x) CHECK(pixel(rgba,x,y,20,40,60,100,0));
    dc_vk_sprite_item draw = {.pose = pose(0.25f,0.25f), .texture = texture, .blend_mode = 3, .point_filter = 1};
    const int colors[4][3] = {{255,0,0}, {0,255,0}, {0,0,255}, {255,255,255}};
    for (int i = 0; i < 4; ++i) {
        draw.pose = pose((i & 1) ? 0.75f : 0.25f, (i & 2) ? 0.75f : 0.25f);
        OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
        CHECK(pixel(rgba,3,3,colors[i][0],colors[i][1],colors[i][2],255,0));
        CHECK(pixel(rgba,0,0,20,40,60,100,0));
    }
    draw.pose = pose(1.25f,-0.25f); /* repeat => bottom-left blue */
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,0,0,255,255,0));
    draw.point_filter = 0;
    draw.pose = pose(0.5f,0.5f);
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,128,128,128,255,1));
    draw.pose = pose(0,0); /* bilinear repeat blends all four edge texels */
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,128,128,128,255,1));
    dc_vk_sprite_item pair[2] = {draw, draw};
    pair[0].point_filter = 1; pair[0].pose.x = -10;
    /* Native post-draw restoration changes inherited point to linear too. */
    OK(dc_vk_sprite_render(r, pair, 2, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,128,128,128,255,1));
    draw.texture = transparent; draw.pose = pose(0.5f,0.5f);
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,110,70,55,114,1));
    draw.pose.alpha = 0.5f; /* native diffuse truncates to 127, not 128 */
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,65,55,58,91,1));
    draw.texture = texture; draw.pose = pose(0.25f,0.25f); draw.point_filter = 1;
    draw.pose.red = 0.5f; draw.pose.green = 0.5f;
    for (unsigned mode = 0; mode < 3; ++mode) {
        draw.blend_mode = (uint8_t)mode;
        OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
        if (mode == 0) CHECK(pixel(rgba,3,3,127,0,0,255,1));
        if (mode == 1) CHECK(pixel(rgba,3,3,147,40,60,255,1));
        if (mode == 2) CHECK(pixel(rgba,3,3,10,0,0,100,1));
    }
    /* Ordered mode transitions, including restoration after modulation. */
    pair[0] = draw; pair[0].blend_mode = 3; pair[0].texture = transparent;
    pair[1] = draw; pair[1].blend_mode = 0;
    OK(dc_vk_sprite_render(r, pair, 2, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,127,0,0,255,1));
    OK(dc_vk_sprite_get_info(r, &info));
    uint64_t frame_count = info.submitted_frames;
    memcpy(before, rgba, sizeof(rgba));
    pair[1].texture = (uintptr_t)-1;
    CHECK(dc_vk_sprite_render(r, pair, 2, clear, rgba, sizeof(rgba)) == DC_ARGUMENT);
    CHECK(!memcmp(before, rgba, sizeof(rgba)));
    draw.texture = transparent; draw.blend_mode = 0;
    CHECK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)) == DC_FORMAT);
    draw.blend_mode = 9;
    CHECK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)) == DC_FORMAT);
    draw.blend_mode = 3; draw.pose.x = NAN;
    CHECK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)) == DC_FORMAT);
    CHECK(dc_vk_sprite_render(r, NULL, 0, clear, rgba, sizeof(rgba)-1) == DC_RANGE);
    CHECK(dc_vk_sprite_render(r, &draw, 4097, clear, rgba, sizeof(rgba)) == DC_RANGE);
    OK(dc_vk_sprite_get_info(r, &info));
    CHECK(info.submitted_frames == frame_count && !memcmp(before, rgba, sizeof(rgba)));
    draw.hidden = 1; draw.texture = (uintptr_t)-1; draw.blend_mode = 255;
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,20,40,60,100,0));
    OK(dc_vk_sprite_remove_texture(r, transparent));
    CHECK(dc_vk_sprite_remove_texture(r, transparent) == DC_ARGUMENT);
    OK(dc_vk_sprite_upload(r, 1, 1, translucent, 4, &extra));
    CHECK(extra != transparent && extra != texture);
    draw.hidden = 0; draw.pose = pose(0.5f,0.5f); draw.blend_mode = 3; draw.texture = transparent;
    CHECK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)) == DC_ARGUMENT);
    draw.texture = extra;
    for (unsigned i = 0; i < 32; ++i) OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,110,70,55,114,1));
    OK(dc_vk_sprite_get_info(r, &info));
    CHECK(info.validation_errors == 0);
    printf("PASS: sprite pixel/readback, blends, filtering, repeat, state transitions, admission, lifetime; frames=%llu validation_errors=%u\n",
        (unsigned long long)info.submitted_frames, info.validation_errors);
    dc_vk_sprite_destroy(r);
    return 0;
failed:
    dc_vk_sprite_destroy(r);
    return 1;
}
