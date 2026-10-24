#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, DCVulkanSpriteScene) {
    DCVulkanSpriteSceneDiagnostic = 0,
    DCVulkanSpriteSceneStartupCard = 1,
    DCVulkanSpriteSceneTitle = 2,
    DCVulkanSpriteSceneStartupWarning = 3,
    DCVulkanSpriteSceneStartupTransition = 4,
    DCVulkanSpriteSceneIntro = 5,
    DCVulkanSpriteSceneGameplay = 6,
    DCVulkanSpriteSceneGameComplete = 7
};
/* Native sprite integration scene. Startup, title, intro and the local
 * chapter-3 gameplay path are driven by the native renderer. */
@interface DCVulkanSpriteView : UIView
@property(nonatomic, readonly) NSString *deviceName;
@property(nonatomic, readonly) uint64_t presentedFrames;
@property(nonatomic, readonly) DCVulkanSpriteScene presentedScene;
@property(nonatomic, copy, nullable) NSString *startupDataDirectory;
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time touching:(BOOL)touching
            completion:(void (^)(NSString * _Nullable error, NSString *deviceName, DCVulkanSpriteScene presentedScene, BOOL animationAdvanced, BOOL materialAdvanced, BOOL poseAdvanced, BOOL musicAdvanced, NSString *introState, BOOL skinAdvanced, BOOL gameplaySkinAdvanced, BOOL interactionCompleted))completion
    NS_SWIFT_NAME(requestDraw(atX:y:time:touching:completion:));
- (void)releaseRenderer;
@end
NS_ASSUME_NONNULL_END
