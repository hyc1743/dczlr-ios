#import <UIKit/UIKit.h>
#include "dc_pc_input.h"

NS_ASSUME_NONNULL_BEGIN
/* Main-thread producer, value-only render-thread consumer. */
dc_pc_frame dc_pc_input_read(void);
void dc_pc_input_set_active(BOOL active);

@interface DCPCInputView : UIView
- (void)reset;
- (void)setInputEnabled:(BOOL)enabled;
+ (nullable NSString *)verifyInput NS_SWIFT_NAME(verifyInput());
@end
NS_ASSUME_NONNULL_END
