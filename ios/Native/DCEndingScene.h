#import <Foundation/Foundation.h>
#include "dc_pc_input.h"
#include "dc_story.h"
#include "dc_vk_sprite.h"
@class DCStartupScene;
NS_ASSUME_NONNULL_BEGIN
@interface DCEndingScene : NSObject
@property(nonatomic,readonly) uint32_t action;
@property(nonatomic,readonly) BOOL routeReady;
@property(nonatomic,readonly) uint32_t category,mapIndex,stageMask,firstStage,secondStage;
- (nullable instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    transition:(DCStartupScene *)transition story:(const dc_story_state *)story error:(NSString **)error;
- (nullable NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input
    width:(uint32_t)width height:(uint32_t)height;
- (void)detachRenderer;
@end
NS_ASSUME_NONNULL_END
