#import <UIKit/UIKit.h>
#include "dc_gamepad.h"
NS_ASSUME_NONNULL_BEGIN
@interface DCGamepadView : UIView
- (void)reset;
+ (nullable NSString *)verifyControls NS_SWIFT_NAME(verifyControls());
@end
/* Thread-safe snapshots: the renderer receives a value, never shared UIKit state. */
dc_pad_frame dc_gamepad_read(void);
void dc_gamepad_set_active(BOOL active);
NS_ASSUME_NONNULL_END
