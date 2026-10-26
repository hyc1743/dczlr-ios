#import <UIKit/UIKit.h>
#include "dc_pc_input.h"

NS_ASSUME_NONNULL_BEGIN
/* Main-thread producer, value-only render-thread consumer. */
dc_pc_frame dc_pc_input_read(void);
void dc_pc_input_set_active(BOOL active);

@interface DCPCInputView : UIView
- (void)reset;
- (void)setInputEnabled:(BOOL)enabled;
/* Game-specific virtual keys share the portable PC latch with a physical
 * keyboard, but use their own owner so a touch release cannot release a
 * real key. */
+ (void)setVirtualKey:(uint32_t)scancode down:(BOOL)down;
+ (void)setVirtualMouseButton:(uint32_t)button down:(BOOL)down;
+ (void)pulseVirtualWheel:(int32_t)delta;
+ (void)pulseVirtualAltF4;
+ (void)clearVirtualInput;
+ (nullable NSString *)verifyInput NS_SWIFT_NAME(verifyInput());
@end
NS_ASSUME_NONNULL_END
