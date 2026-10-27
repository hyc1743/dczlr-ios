#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
#include "dc_gamepad.h"
#include "dc_pc_input.h"
#include "dc_config.h"
@class DCStartupScene;

NS_ASSUME_NONNULL_BEGIN
/* Story-scene host for the original chapter scene kinds (gameplay, watch,
 * night and ending). The chapter selector drives the original static
 * map/stage tables through dc_story_chapter_profile. Local RPP_10 map,
 * RPP_08 actor, RPP_09 face model/morph, RPP_04 eyes/neck binding and the
 * native camera/model/clip path render the scene. Main scene icons and the
 * initial type-4 right-click menus are separate from context action callbacks,
 * which are still being recovered. */
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
@property(nonatomic,readonly) NSString *presentationContext;
@property(nonatomic,readonly,nullable) NSDictionary *lastRenderCapture;
- (void)requestRenderCapture:(NSString *)name;
@property(nonatomic,readonly) uint32_t chapter;
@property(nonatomic,readonly) uint32_t chapterEndAction;
@property(nonatomic,readonly) uint32_t stageOutcomeA;
@property(nonatomic,readonly) uint32_t stageOutcomeB;
@property(nonatomic,readonly) uint32_t storyStage;
@property(nonatomic,readonly) uint32_t sceneKind;
@property(nonatomic,readonly) uint32_t sceneType;
@property(nonatomic,readonly) BOOL interactiveScene;
@property(nonatomic) BOOL secondaryViewVisible;
@property(nonatomic,strong,nullable) DCStartupScene *transitionScene;
- (uint32_t)takePendingEffectSlot;
- (nullable NSString *)updateCharacterWithExitSoundBusy:(BOOL)busy tick:(uint32_t)tick;
- (nullable NSString *)updateSystemWithSelectionSoundBusy:(BOOL)busy tick:(uint32_t)tick;
- (nullable NSString *)applyConfiguration:(const dc_config *)configuration;
- (void)resumeAtTick:(uint32_t)tick;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage stageProgress:(uint32_t)progress resumeSavedPlayer:(BOOL)resume error:(NSString **)error;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage stageProgress:(uint32_t)progress
    sceneTypeOverride:(uint32_t)sceneTypeOverride resumeSavedPlayer:(BOOL)resume error:(NSString **)error;
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
