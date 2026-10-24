#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"

NS_ASSUME_NONNULL_BEGIN
/* First real chapter-3 scene: local RPP_10 map (including mn00_01.xa when the
 * original map loader supplies it), RPP_08 actor, RPP_09 face model/morph,
 * RPP_04 eyes/neck binding and the native camera/model/clip path. Unsupported
 * later systems still fail explicitly instead of substituting generated content. */
@interface DCGameScene : NSObject
@property(nonatomic,readonly) BOOL loaded;
@property(nonatomic,readonly) uint32_t visibleMapTriangles;
@property(nonatomic,readonly) uint32_t visibleActorTriangles;
@property(nonatomic,readonly) uint32_t interactionCount;
@property(nonatomic,readonly) BOOL interactionCompleted;
@property(nonatomic,readonly) BOOL gameFinished;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer error:(NSString **)error;
- (void)detachRenderer;
- (nullable NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching
    width:(uint32_t)width height:(uint32_t)height;
@end
NS_ASSUME_NONNULL_END
