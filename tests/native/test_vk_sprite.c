#include "dc_vk_sprite.h"
#include "dc_sprite_spv.h"
#include "dc_camera.h"
#include "dc_mesh.h"
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

int dc_vk_sprite_pixel_gate(void *metal_layer, uint32_t validation) {
    dc_vk_sprite *r = NULL;
    dc_vk_sprite_config config = {.width = 8, .height = 8, .max_textures = 2, .initial_filter = 2,
        .validation = validation, .vertex_spirv = dc_sprite_vert_spv, .vertex_spirv_bytes = sizeof(dc_sprite_vert_spv),
        .fragment_spirv = dc_sprite_frag_spv, .fragment_spirv_bytes = sizeof(dc_sprite_frag_spv), .metal_layer = metal_layer};
    char error[512];
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
    /* Varying UVs and a 90-degree pivot rotation exercise orientation and
     * interpolation through the native vertex generator, beyond solid UVs. */
    draw.pose = pose(0,0);
    draw.pose.width = draw.pose.height = 6;
    draw.pose.x = draw.pose.y = 1;
    draw.pose.u1 = draw.pose.v1 = 1;
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,2,2,255,0,0,255,0));
    CHECK(pixel(rgba,5,2,0,255,0,255,0));
    CHECK(pixel(rgba,2,5,0,0,255,255,0));
    CHECK(pixel(rgba,5,5,255,255,255,255,0));
    draw.pose.x = draw.pose.y = 4;
    draw.pose.origin_x = draw.pose.origin_y = 0.5f;
    draw.pose.rotation = 1.5707963267948966f;
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,0,0,255,255,0));
    CHECK(pixel(rgba,5,3,255,0,0,255,0));
    CHECK(pixel(rgba,3,5,255,255,255,255,0));
    CHECK(pixel(rgba,5,5,0,255,0,255,0));
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
    /* Native post-draw restoration keeps the following draw linear. */
    OK(dc_vk_sprite_render(r, pair, 2, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,128,128,128,255,1));
    draw.texture = transparent; draw.pose = pose(0.5f,0.5f);
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,110,70,55,114,1));
    OK(dc_vk_sprite_render(r, &draw, 1, clear, NULL, 0));
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
    r = NULL;
    config.initial_filter = 1;
    OK(dc_vk_sprite_create(&config, &r, error, sizeof(error)));
    OK(dc_vk_sprite_upload(r, 2, 2, checker, sizeof(checker), &texture));
    draw = (dc_vk_sprite_item){.pose = pose(0.5f,0.5f), .texture = texture, .blend_mode = 3};
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,255,255,255,255,0));
    pair[0] = pair[1] = draw;
    pair[0].point_filter = 1; pair[0].pose.x = -10;
    OK(dc_vk_sprite_render(r, pair, 2, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,128,128,128,255,1));
    /* The next frame starts from the explicit inherited point state again. */
    OK(dc_vk_sprite_render(r, &draw, 1, clear, rgba, sizeof(rgba)));
    CHECK(pixel(rgba,3,3,255,255,255,255,0));
    OK(dc_vk_sprite_get_info(r, &info));
    CHECK(info.validation_errors == 0 && info.submitted_frames == 3);
    puts("PASS: initial point filter, native restoration to linear, frame state reset");
    dc_sprite_vertex triangle[3] = {
        {.x=-.5f,.y=-.5f,.z=.5f,.rhw=1,.diffuse=0xffffffff,.u=0,.v=.25f},
        {.x=7.5f,.y=-.5f,.z=.5f,.rhw=1,.diffuse=0xffffffff,.u=1,.v=.25f},
        {.x=-.5f,.y=7.5f,.z=.5f,.rhw=1,.diffuse=0xffffffff,.u=0,.v=.25f}};
    dc_vk_geometry_item geometry = {.vertices=triangle,.vertex_count=3,.texture=texture,.blend_mode=3,.point_filter=1};
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,2,2,255,0,0,255,0));
    CHECK(pixel(rgba,7,7,20,40,60,100,0));
    geometry.cull_mode=DC_VK_FRONT_POSITIVE_AREA;
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,2,2,255,0,0,255,0));
    geometry.cull_mode=DC_VK_FRONT_NEGATIVE_AREA;
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,2,2,20,40,60,100,0));
    dc_sprite_vertex winding=triangle[1];triangle[1]=triangle[2];triangle[2]=winding;
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,2,2,255,0,0,255,0));
    winding=triangle[1];triangle[1]=triangle[2];triangle[2]=winding;
    geometry.cull_mode=DC_VK_CULL_NONE;
    puts("PASS: framebuffer winding, opposite front faces and two-sided reset");
    triangle[1].rhw=4;
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,2,2,0,255,0,255,0)); /* Positive rhw changes UV interpolation. */
    triangle[1].rhw=1;
    for (unsigned i=0;i<3;++i) {triangle[i].u=.25f;triangle[i].diffuse=0x80ffffff;}
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,2,2,138,20,30,114,1));
    memcpy(before,rgba,sizeof(rgba));
    OK(dc_vk_sprite_get_info(r,&info));frame_count=info.submitted_frames;
    triangle[1].rhw=0;
    CHECK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba))==DC_FORMAT);
    triangle[1].rhw=1;geometry.vertex_count=4;
    CHECK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba))==DC_RANGE);
    geometry.vertex_count=3;geometry.texture=(uintptr_t)-1;
    CHECK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba))==DC_ARGUMENT);
    CHECK(!memcmp(before,rgba,sizeof(rgba)));
    OK(dc_vk_sprite_get_info(r,&info));
    CHECK(info.submitted_frames==frame_count && info.validation_errors==0);
    puts("PASS: triangle-list mesh raster, perspective-correct UV, diffuse alpha and atomic admission");
    geometry.texture=texture;
    for(unsigned i=0;i<3;++i)triangle[i].diffuse=0xffffffff;
    dc_vk_clip_rect clip={1,1,2,2};
    OK(dc_vk_geometry_render_region(r,&geometry,1,clear,rgba,sizeof(rgba),&clip));
    CHECK(pixel(rgba,1,1,255,0,0,255,0));CHECK(pixel(rgba,2,2,255,0,0,255,0));
    CHECK(pixel(rgba,0,0,20,40,60,100,0));CHECK(pixel(rgba,3,1,20,40,60,100,0));
    CHECK(pixel(rgba,1,3,20,40,60,100,0));
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,0,0,255,0,0,255,0));
    memcpy(before,rgba,sizeof(rgba));OK(dc_vk_sprite_get_info(r,&info));frame_count=info.submitted_frames;
    clip=(dc_vk_clip_rect){7,1,2,2};
    CHECK(dc_vk_geometry_render_region(r,&geometry,1,clear,rgba,sizeof(rgba),&clip)==DC_RANGE);
    clip=(dc_vk_clip_rect){0xffffffff,0,1,1};
    CHECK(dc_vk_geometry_render_region(r,&geometry,1,clear,rgba,sizeof(rgba),&clip)==DC_RANGE);
    CHECK(!memcmp(before,rgba,sizeof(rgba)));OK(dc_vk_sprite_get_info(r,&info));CHECK(info.submitted_frames==frame_count);
    puts("PASS: explicit geometry scissor, full-frame reset and atomic invalid-region rejection");
    /* One input vertex is on the eye plane (W=0). Clip its visible portion
     * against the near plane before the existing XYZRHW GPU path. */
    dc_camera_orbit orbit={.base={{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}}};
    dc_camera_lens lens={1.5707963267948966f,1,10,8,8};dc_camera_matrices camera;
    OK(dc_camera_build(&orbit,&lens,&camera));
    dc_mesh_vertex mesh_vertices[3]={{{-1.5f,-1.5f,-2},{0},{.25f,.25f}},
        {{1.5f,-1.5f,-2},{0},{.25f,.25f}},{{0,1.5f,0},{0},{.25f,.25f}}};
    const uint16_t indices[3]={0,1,2};dc_viewport viewport={0,0,8,8,0,1};
    dc_sprite_vertex clipped[21];size_t written=0;
    OK(dc_mesh_clip_project(mesh_vertices,3,indices,3,&camera.view_projection,&viewport,
        0xffffffff,clipped,21,&written));CHECK(written==6);
    geometry=(dc_vk_geometry_item){.vertices=clipped,.vertex_count=written,.texture=texture,.blend_mode=3,.point_filter=1};
    OK(dc_vk_geometry_render(r,&geometry,1,clear,rgba,sizeof(rgba)));
    CHECK(pixel(rgba,4,5,255,0,0,255,0));CHECK(pixel(rgba,4,2,20,40,60,100,0));
    CHECK(pixel(rgba,0,5,20,40,60,100,0));
    puts("PASS: eye-plane/near-plane clipped mesh and camera through actual Vulkan raster");
    /* Depth ordering must be independent of submission order for the real
     * map/actor triangle lists. Two opaque self-authored quads overlap at the
     * center; the smaller Z wins in both orders. */
    OK(dc_vk_sprite_remove_texture(r,texture));
    const uint8_t red_pixel[4]={255,0,0,255},green_pixel[4]={0,255,0,255};
    uintptr_t red_texture=0,green_texture=0;
    OK(dc_vk_sprite_upload(r,1,1,red_pixel,sizeof(red_pixel),&red_texture));
    OK(dc_vk_sprite_upload(r,1,1,green_pixel,sizeof(green_pixel),&green_texture));
    dc_sprite_vertex far_quad[6],near_quad[6];
    const float xy[4][2]={{1,1},{7,1},{1,7},{7,7}};const unsigned qorder[6]={0,1,2,2,1,3};
    for(unsigned i=0;i<6;++i) {
        unsigned q=qorder[i];
        far_quad[i]=(dc_sprite_vertex){.x=xy[q][0],.y=xy[q][1],.z=.8f,.rhw=1,.diffuse=0xffffffff,.u=0,.v=0};
        near_quad[i]=(dc_sprite_vertex){.x=xy[q][0]+1,.y=xy[q][1]+1,.z=.2f,.rhw=1,.diffuse=0xffffffff,.u=0,.v=0};
    }
    dc_vk_geometry_item depth_items[2]={{.vertices=far_quad,.vertex_count=6,.texture=red_texture,.blend_mode=3,.depth_mode=DC_VK_DEPTH_WRITE},
        {.vertices=near_quad,.vertex_count=6,.texture=green_texture,.blend_mode=3,.depth_mode=DC_VK_DEPTH_WRITE}};
    OK(dc_vk_geometry_render(r,depth_items,2,clear,rgba,sizeof(rgba)));CHECK(pixel(rgba,4,4,0,255,0,255,0));
    dc_vk_geometry_item swapped=depth_items[0];depth_items[0]=depth_items[1];depth_items[1]=swapped;
    OK(dc_vk_geometry_render(r,depth_items,2,clear,rgba,sizeof(rgba)));CHECK(pixel(rgba,4,4,0,255,0,255,0));
    /* Read-only foreground must not occlude a later farther write. Default
     * geometry ignores existing depth, as overlays require. */
    depth_items[0].depth_mode=DC_VK_DEPTH_READ_ONLY;
    OK(dc_vk_geometry_render(r,depth_items,2,clear,rgba,sizeof(rgba)));CHECK(pixel(rgba,4,4,255,0,0,255,0));
    depth_items[0].depth_mode=DC_VK_DEPTH_WRITE;depth_items[1].depth_mode=DC_VK_DEPTH_DISABLED;
    OK(dc_vk_geometry_render(r,depth_items,2,clear,rgba,sizeof(rgba)));CHECK(pixel(rgba,4,4,255,0,0,255,0));
    memcpy(before,rgba,sizeof(rgba));OK(dc_vk_sprite_get_info(r,&info));frame_count=info.submitted_frames;
    depth_items[1].depth_mode=3;
    CHECK(dc_vk_geometry_render(r,depth_items,2,clear,rgba,sizeof(rgba))==DC_FORMAT);
    CHECK(!memcmp(before,rgba,sizeof(rgba)));OK(dc_vk_sprite_get_info(r,&info));CHECK(info.submitted_frames==frame_count);
    OK(dc_vk_sprite_remove_texture(r,red_texture));OK(dc_vk_sprite_remove_texture(r,green_texture));
    puts("PASS: depth-tested overlapping geometry is submission-order independent");
    dc_vk_sprite_destroy(r);
    return 0;
failed:
    dc_vk_sprite_destroy(r);
    return 1;
}

#ifndef PORTLAB_GATE_NO_MAIN
int main(int argc, char **argv) {
    /* Linux CI requires validation; MoltenVK installations may omit the layer. */
    return dc_vk_sprite_pixel_gate(NULL, !(argc > 1 && !strcmp(argv[1], "--no-validation")));
}
#endif
