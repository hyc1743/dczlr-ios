#import <Foundation/Foundation.h>
#include "dc_pc_input.h"
#include "dc_vk_sprite.h"
#include "dc_edit.h"
@class DCStartupScene;

NS_ASSUME_NONNULL_BEGIN
/* Original scene type 11 (Edit Studio, 0x005fa970..0x00603800):
 * Chara setup tab, Motion playlist/parameter tab, .edt file browser tab,
 * and Caution confirmation modal.
 * Actions: 1 = Play (enter Type 12 3D Playback), 2 = Title/Quit, 3 = Dummy (Esc). */
@interface DCEditScene : NSObject
@property(nonatomic,readonly) uint32_t action;
@property(nonatomic,readonly) NSString *presentationContext;
@property(nonatomic,readonly,nullable) NSDictionary *lastRenderCapture;
- (nullable instancetype)initWithDirectory:(NSString *)directory
                                  renderer:(dc_vk_sprite *)renderer
                                transition:(DCStartupScene *)transition
                                     error:(NSString **)error;
- (const dc_edit_state *)editState;
- (nullable NSString *)drawAtTick:(uint32_t)tick
                          pcInput:(dc_pc_frame)input
                            width:(uint32_t)width
                           height:(uint32_t)height;
- (void)requestRenderCapture:(NSString *)name;
- (nullable NSString *)attachRenderer:(dc_vk_sprite *)renderer;
- (void)detachRenderer;
- (void)pause;
- (void)consumeAction;
- (void)resumeFromTemporaryScreen;
- (void)resumeFromPlaybackAtTick:(uint32_t)tick;
@end
NS_ASSUME_NONNULL_END
