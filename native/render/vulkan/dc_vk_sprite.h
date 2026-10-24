#ifndef DC_VK_SPRITE_H
#define DC_VK_SPRITE_H

#include "dc_sprite.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dc_vk_sprite dc_vk_sprite;

typedef struct dc_vk_sprite_config {
    uint32_t width, height;
    uint32_t max_textures;
    uint32_t initial_filter; /* Explicit inherited min/mag state: 1 point, 2 linear. */
    uint32_t validation; /* Requires Khronos validation layer and debug-utils. */
    const uint32_t *vertex_spirv;
    size_t vertex_spirv_bytes;
    const uint32_t *fragment_spirv;
    size_t fragment_spirv_bytes;
    void *metal_layer; /* Optional retained-by-caller CAMetalLayer, Apple only. */
} dc_vk_sprite_config;

typedef struct dc_vk_sprite_item {
    dc_sprite_pose pose;
    uintptr_t texture;
    uint8_t blend_mode, hidden, point_filter, software_vertex;
} dc_vk_sprite_item;
/* Preprojected, non-indexed triangle-list vertices. RGB and alpha modulate
 * texture with diffuse; blend modes 0/3 standard, 1 additive, 2 modulation.
 * Explicit unlit one-texture profile; no culling/skinning/effect claim.
 * Positive rhw enables perspective-correct interpolation through the shader. */
typedef struct dc_vk_geometry_item {
    const dc_sprite_vertex *vertices;
    size_t vertex_count;
    uintptr_t texture;
    uint8_t blend_mode, hidden, point_filter, depth_mode;
} dc_vk_geometry_item;
enum dc_vk_depth_mode {
    DC_VK_DEPTH_DISABLED=0,
    DC_VK_DEPTH_WRITE=1, /* LESS_OR_EQUAL test and write. */
    DC_VK_DEPTH_READ_ONLY=2 /* LESS_OR_EQUAL test without writes. */
};
typedef struct dc_vk_clip_rect { uint32_t x,y,width,height; } dc_vk_clip_rect;

typedef struct dc_vk_sprite_info {
    char device_name[256];
    uint32_t device_type, api_version, driver_version;
    uint32_t validation_errors;
    uint64_t submitted_frames;
} dc_vk_sprite_info;

/* Serial, blocking Vulkan backend with optional Apple surface presentation.
 * Scope: RGBA8, D32 depth cleared to1 each frame, no culling, one repeated texture stage, one mip,
 * observed sprite blend modes. Unsupported effective state fails explicitly.
 * A visible textured draw requires a live texture handle. Alpha-op DISABLE is
 * accepted only for opaque texture + opaque diffuse; other transparency uses
 * the recovered mode-3 modulation. This is not a complete D3D9 implementation.
 * These entry points are separate from the CPU-only portable native library. */
DC_API dc_status dc_vk_sprite_create(const dc_vk_sprite_config *config,
                                     dc_vk_sprite **out, char *error, size_t error_capacity);
DC_API void dc_vk_sprite_destroy(dc_vk_sprite *renderer);
DC_API const char *dc_vk_sprite_error(const dc_vk_sprite *renderer);
DC_API dc_status dc_vk_sprite_get_info(const dc_vk_sprite *renderer, dc_vk_sprite_info *out);
DC_API dc_status dc_vk_sprite_upload(dc_vk_sprite *renderer, uint32_t width, uint32_t height,
                                     const uint8_t *rgba, size_t bytes, uintptr_t *handle);
DC_API dc_status dc_vk_sprite_remove_texture(dc_vk_sprite *renderer, uintptr_t handle);
/* Executes native entry/draw plans and vertex generation, clears and renders
 * the full frame, then reads tightly packed top-left RGBA8 attachment bytes
 * without unpremultiplication.
 * rgba may be NULL with capacity zero to omit CPU readback. An Apple surface,
 * when configured, receives the Vulkan target through a GPU blit and swapchain.
 * Sprite draws always disable depth testing/writes. Geometry explicitly selects
 * disabled/read-write/read-only depth; zero-initialized geometry disables it.
 * Every frame establishes a fresh sprite state; min/mag starts at config's
 * explicit inherited value. Hidden value 1 skips an item without resolving it.
 * Semantic/admission errors do not submit a frame or modify output. */
DC_API dc_status dc_vk_sprite_render(dc_vk_sprite *renderer,
                                     const dc_vk_sprite_item *items, size_t count,
                                     const uint8_t clear_rgba[4], uint8_t *rgba, size_t capacity);
DC_API dc_status dc_vk_geometry_render(dc_vk_sprite *renderer,
    const dc_vk_geometry_item *items, size_t count,
    const uint8_t clear_rgba[4], uint8_t *rgba, size_t capacity);
/* Same geometry path with an explicit nonempty pixel scissor. The full target
 * is still cleared/read back; only draws are clipped. NULL means full target.
 * Every call establishes its own scissor; sprite/default geometry calls reset
 * it to full target. Invalid regions do not submit or modify readback. */
DC_API dc_status dc_vk_geometry_render_region(dc_vk_sprite *renderer,
    const dc_vk_geometry_item *items,size_t count,const uint8_t clear_rgba[4],
    uint8_t *rgba,size_t capacity,const dc_vk_clip_rect *clip);

#ifdef __cplusplus
}
#endif
#endif
