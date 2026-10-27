#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
#include "dc_mesh.h"
NS_ASSUME_NONNULL_BEGIN
/* Original two-card startup resources, numeric actions and transition mesh.
 * Subsequent title/menu gameplay remains a separate host state. */
@interface DCStartupScene : NSObject
@property(nonatomic,readonly) BOOL finished;
@property(nonatomic,readonly) uint32_t card;
@property(nonatomic,readonly) BOOL cardReady;
@property(nonatomic,readonly) BOOL skinAdvanced;
- (nullable instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer error:(NSString **)error;
- (void)detachRenderer;
- (nullable NSString *)attachRenderer:(dc_vk_sprite *)renderer;
- (nullable NSString *)drawAtTick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height;
/* Shared original transition model continues after startup. Query before
 * request/update; external scenes supply sprites beneath the projected mesh. */
- (dc_status)queryTransitionReady:(uint32_t *)ready;
- (dc_status)requestTransition:(uint32_t)request tick:(uint32_t)tick;
@property(nonatomic,readonly) size_t transitionMeshCapacity;
/* Append the shared original transition above an already-built 3D scene.
 * The caller retains storage through its single Vulkan submission. */
- (nullable NSString *)appendTransitionAtTick:(uint32_t)tick viewport:(dc_viewport)viewport
    draws:(dc_vk_geometry_item *)draws capacity:(size_t)capacity count:(size_t *)count storage:(NSMutableArray *)storage;
- (nullable NSString *)drawSprites:(const dc_vk_sprite_item *)items count:(size_t)count
    tick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height;
- (nullable NSString *)drawSprites:(const dc_vk_sprite_item *)items count:(size_t)count
    tick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height readback:(nullable NSMutableData *)readback;
@end
NS_ASSUME_NONNULL_END
