#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/* Native sprite integration scene. This view does not run the game. */
@interface DCVulkanSpriteView : UIView
@property(nonatomic, readonly) NSString *deviceName;
@property(nonatomic, readonly) uint64_t presentedFrames;
- (nullable NSString *)drawAtX:(float)x y:(float)y time:(double)time NS_SWIFT_NAME(renderSprite(x:y:time:));
- (void)releaseRenderer;
@end
NS_ASSUME_NONNULL_END
