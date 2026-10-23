#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
NS_ASSUME_NONNULL_BEGIN
/* Original two-card startup resources, numeric actions and transition mesh.
 * Subsequent title/menu gameplay remains a separate host state. */
@interface DCStartupScene : NSObject
@property(nonatomic,readonly) BOOL finished;
@property(nonatomic,readonly) uint32_t card;
@property(nonatomic,readonly) BOOL cardReady;
- (nullable instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer error:(NSString **)error;
- (void)detachRenderer;
- (nullable NSString *)attachRenderer:(dc_vk_sprite *)renderer;
- (nullable NSString *)drawAtTick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height;
@end
NS_ASSUME_NONNULL_END
