#import <Foundation/Foundation.h>
#include "dc_pc_input.h"
#include "dc_vk_sprite.h"
@class DCStartupScene;
NS_ASSUME_NONNULL_BEGIN
/* Original type8 page. The host owns canonical state and all save-file writes.
 * Actions match0052b320:1 owner,2 title,3 config,4 quit,5 load,6 dummy. */
@interface DCSaveScene : NSObject
@property(nonatomic,readonly) uint32_t action;
@property(nonatomic,readonly) uint32_t selectedSlot;
@property(nonatomic,readonly) BOOL saveRequested;
/* Encoded original slot bytes. Load captures these before its fade begins. */
@property(nonatomic,readonly,nullable) NSData *selectedSlotData;
@property(nonatomic,readonly) NSString *presentationContext;
@property(nonatomic,readonly,nullable) NSDictionary *lastRenderCapture;
- (nullable instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    transition:(DCStartupScene *)transition ownerSceneType:(uint32_t)ownerSceneType
    chapter:(uint32_t)chapter error:(NSString **)error;
- (nullable NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input
    width:(uint32_t)width height:(uint32_t)height;
- (void)consumeSaveRequest;
- (void)refreshSlots;
- (void)requestRenderCapture:(NSString *)name;
- (void)detachRenderer;
- (void)pause;
- (void)resumeFromTemporaryScreen;
@end
NS_ASSUME_NONNULL_END
