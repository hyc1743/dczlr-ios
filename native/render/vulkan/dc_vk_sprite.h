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
} dc_vk_sprite_config;

typedef struct dc_vk_sprite_item {
    dc_sprite_pose pose;
    uintptr_t texture;
    uint8_t blend_mode, hidden, point_filter, software_vertex;
} dc_vk_sprite_item;

typedef struct dc_vk_sprite_info {
    char device_name[256];
    uint32_t device_type, api_version, driver_version;
    uint32_t validation_errors;
    uint64_t submitted_frames;
} dc_vk_sprite_info;

/* Serial, blocking offscreen Vulkan backend. No CPU rasterizer or emulation.
 * Scope: RGBA8, no depth test/culling, one repeated texture stage, one mip,
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
 * Every frame establishes a fresh sprite state; min/mag starts at config's
 * explicit inherited value. Hidden value 1 skips an item without resolving it.
 * Semantic/admission errors do not submit a frame or modify output. */
DC_API dc_status dc_vk_sprite_render(dc_vk_sprite *renderer,
                                     const dc_vk_sprite_item *items, size_t count,
                                     const uint8_t clear_rgba[4], uint8_t *rgba, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
