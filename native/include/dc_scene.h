#ifndef DC_SCENE_H
#define DC_SCENE_H
#include "dc_pose.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_SCENE_NODE_LIMIT 4096u
#define DC_SCENE_NO_PARENT UINT32_MAX
typedef struct dc_scene_node {
    uint32_t parent, modifier;
    uint8_t hidden, billboard, reserved[2];
    dc_matrix local, extra;
} dc_scene_node;
/* Flat parent-before-child node order. Roots inherit world. Original
 * 0x415620 default/1/2 transform modifiers and hidden subtree suppression.
 * Hidden node/descendant global matrices retain their previous caller values.
 * Billboard modes are not yet admitted. Unsupported visible modifier values
 * fail explicitly. All validation and calculations finish before commit.
 * Input/output spans cannot overlap; count is bounded; no GPU or skinning. */
DC_API dc_status dc_scene_update(const dc_scene_node *nodes, size_t count,
    const dc_matrix *world, dc_matrix *globals, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
