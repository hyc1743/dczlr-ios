#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/* Native sprite integration scene. This view does not run the game. */
@interface DCVulkanSpriteView : UIView
@property(nonatomic, readonly) NSString *deviceName;
@property(nonatomic, readonly) uint64_t presentedFrames;
@property(nonatomic, readonly) BOOL startupCardLoaded;
@property(nonatomic, copy, nullable) NSString *startupDataDirectory;
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time
            completion:(void (^)(NSString * _Nullable error, NSString *deviceName, BOOL startupCardLoaded))completion
    NS_SWIFT_NAME(requestDraw(atX:y:time:completion:));
- (void)releaseRenderer;
@end
NS_ASSUME_NONNULL_END
