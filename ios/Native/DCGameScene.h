#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
#include "dc_gamepad.h"
#include "dc_pc_input.h"

NS_ASSUME_NONNULL_BEGIN
/* Story-scene host for the original chapter scene kinds (gameplay, watch,
 * night and ending). The chapter selector drives the original static
 * map/stage tables through dc_story_chapter_profile. Local RPP_10 map,
 * RPP_08 actor, RPP_09 face model/morph, RPP_04 eyes/neck binding and the
 * native camera/model/clip path render the scene; the six-row menu and the
 * chapter-end actions follow the original shared menu activation dispatch
 * (0x00532240 case 4) and the chapter-end handler (0x00523380). */
@interface DCGameScene : NSObject
@property(nonatomic,readonly) BOOL loaded;
@property(nonatomic,readonly) uint32_t visibleMapTriangles;
@property(nonatomic,readonly) uint32_t visibleActorTriangles;
@property(nonatomic,readonly) uint32_t interactionCount;
@property(nonatomic,readonly) BOOL interactionCompleted;
@property(nonatomic,readonly) BOOL interactionActive;
@property(nonatomic,readonly) BOOL gameFinished;
@property(nonatomic,readonly) BOOL actorSkinAdvanced;
@property(nonatomic,readonly) BOOL controllerMovementAdvanced;
@property(nonatomic,readonly) BOOL controllerCameraAdvanced;
@property(nonatomic,readonly) BOOL manualSaveCompleted;
@property(nonatomic,readonly) uint32_t chapter;
@property(nonatomic,readonly) uint32_t chapterEndAction;
@property(nonatomic,readonly) uint32_t stageOutcomeA;
@property(nonatomic,readonly) uint32_t stageOutcomeB;
@property(nonatomic,readonly) uint32_t storyStage;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage error:(NSString **)error;
- (void)detachRenderer;
- (nullable NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput
    width:(uint32_t)width height:(uint32_t)height;
- (nullable NSString *)takePendingVoiceName;
/* Consume one chapter-end action; returns to the interaction phase. */
- (void)consumeChapterEndAction;
/* Original edit-scene outfit effect: cycle the actor's outfit visibility
 * variants and resume the interaction phase. */
- (void)applyOutfitVariant:(uint32_t)variant;
/* Title Edit destination presentation: outfit rows replace the interaction
 * rows; row 4 finishes and returns to the title. */
- (void)setEditMode:(BOOL)editMode;
@end
NS_ASSUME_NONNULL_END
