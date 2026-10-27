#import <Foundation/Foundation.h>
#include "dc_pc_input.h"
#include "dc_vk_sprite.h"
@class DCStartupScene;
NS_ASSUME_NONNULL_BEGIN
@interface DCDummyScene : NSObject
@property(nonatomic,readonly) uint32_t action;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer transition:(DCStartupScene *)transition
    error:(NSString **)error;
- (nullable NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input
    width:(uint32_t)width height:(uint32_t)height;
- (void)detachRenderer;
- (void)pause;
@end
NS_ASSUME_NONNULL_END
