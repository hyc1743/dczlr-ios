#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
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
- (nullable NSString *)drawSprites:(const dc_vk_sprite_item *)items count:(size_t)count
    tick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height;
- (nullable NSString *)drawSprites:(const dc_vk_sprite_item *)items count:(size_t)count
    tick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height readback:(nullable NSMutableData *)readback;
@end
NS_ASSUME_NONNULL_END
