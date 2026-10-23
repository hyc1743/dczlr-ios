#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
NS_ASSUME_NONNULL_BEGIN
@class DCStartupScene;
/* First new-game script host. Numeric initialization/parser are reconstructed;
 * text uses Apple's font adapter. Later game-scene dispatch remains pending. */
@interface DCIntroScene : NSObject
@property(nonatomic,readonly) uint32_t frame;
@property(nonatomic,readonly) BOOL completed;
@property(nonatomic,readonly) BOOL audioAdvanced;
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error;
- (void)detachRenderer;
- (void)pause;
- (nullable NSString *)drawWithRenderer:(dc_vk_sprite *)renderer transition:(DCStartupScene *)transition
    tick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height;
@end
NS_ASSUME_NONNULL_END
