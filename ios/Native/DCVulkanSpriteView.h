#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, DCVulkanSpriteScene) {
    DCVulkanSpriteSceneDiagnostic = 0,
    DCVulkanSpriteSceneStartupCard = 1,
    DCVulkanSpriteSceneTitle = 2
};
/* Native sprite integration scene. This view does not run the game. */
@interface DCVulkanSpriteView : UIView
@property(nonatomic, readonly) NSString *deviceName;
@property(nonatomic, readonly) uint64_t presentedFrames;
@property(nonatomic, readonly) DCVulkanSpriteScene presentedScene;
@property(nonatomic, copy, nullable) NSString *startupDataDirectory;
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time touching:(BOOL)touching
            completion:(void (^)(NSString * _Nullable error, NSString *deviceName, DCVulkanSpriteScene presentedScene))completion
    NS_SWIFT_NAME(requestDraw(atX:y:time:touching:completion:));
- (void)releaseRenderer;
@end
NS_ASSUME_NONNULL_END
