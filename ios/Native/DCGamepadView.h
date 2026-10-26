#import <UIKit/UIKit.h>
#include "dc_gamepad.h"
#include "dc_touch_controls.h"
NS_ASSUME_NONNULL_BEGIN
@interface DCGamepadView : UIView
- (void)reset;
- (void)invalidateInput;
+ (nullable NSString *)verifyControls NS_SWIFT_NAME(verifyControls());
@end
/* Thread-safe snapshots: the renderer receives a value, never shared UIKit state. */
dc_pad_frame dc_gamepad_read(void);
NSString *dc_gamepad_presentation(void);
void dc_gamepad_set_active(BOOL active);
void dc_gamepad_set_context(uint32_t scene,BOOL completed,BOOL busy);
/* Debug-only input into the visible control's hit test and UIKit handlers.
 * Returns NO in Release; it never writes controller axes directly. */
BOOL dc_gamepad_test_hold(uint32_t control,float x,float y,BOOL down);
BOOL dc_gamepad_test_menu_action(uint32_t index);
NS_ASSUME_NONNULL_END
