#import <Foundation/Foundation.h>
#include "dc_config.h"
#include "dc_pc_input.h"
#include "dc_vk_sprite.h"
@class DCStartupScene;
NS_ASSUME_NONNULL_BEGIN
/* Original type9 page. Actions retain0052aef0's numeric destinations:
 * 1 root callbacks,2 title,3 save/load,4 exit,5 dummy screen. */
@interface DCConfigScene : NSObject
@property(nonatomic,readonly) NSData *configuration;
@property(nonatomic,readonly) uint32_t action;
@property(nonatomic,readonly) BOOL persistOnDeparture;
@property(nonatomic,readonly) NSString *presentationContext;
@property(nonatomic,readonly,nullable) NSDictionary *lastRenderCapture;
- (nullable instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    configuration:(NSData *)configuration transition:(DCStartupScene *)transition error:(NSString **)error;
- (nullable NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input width:(uint32_t)width height:(uint32_t)height;
- (void)requestRenderCapture:(NSString *)name;
- (void)detachRenderer;
- (void)pause;
- (void)resumeFromTemporaryScreen;
@end
NS_ASSUME_NONNULL_END
