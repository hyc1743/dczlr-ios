#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
NS_ASSUME_NONNULL_BEGIN
@class DCStartupScene;
/* Numbered new-game script host with original numeric layout/fade and chapter
 * routing. CP936 uses Apple's font rasterizer. Nonscript scenes are pending. */
@interface DCIntroScene : NSObject
@property(nonatomic,readonly) uint32_t frame;
@property(nonatomic,readonly) uint32_t chapter;
@property(nonatomic,readonly) NSString *presentationState;
@property(nonatomic,readonly) BOOL completed;
@property(nonatomic,readonly) BOOL audioAdvanced;
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error;
- (void)detachRenderer;
- (void)pause;
- (nullable NSString *)drawWithRenderer:(dc_vk_sprite *)renderer transition:(DCStartupScene *)transition
    tick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height;
@end
NS_ASSUME_NONNULL_END
