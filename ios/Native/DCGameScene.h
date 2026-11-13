#import <Foundation/Foundation.h>
#include "dc_vk_sprite.h"
#include "dc_gamepad.h"
#include "dc_pc_input.h"
#include "dc_config.h"
#include "dc_type7.h"
#include "dc_edit.h"
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
@property(nonatomic,readonly) uint32_t watchClimaxElapsedMs;
@property(nonatomic,readonly) uint32_t outfitVariant;
@property(nonatomic,readonly) uint32_t pos2SelectedCount;
@property(nonatomic,readonly) uint32_t strippedCountAtClimax;
@property(nonatomic,readonly) uint32_t oralClimaxCount;
@property(nonatomic,readonly) uint32_t oralSwallowCount;
@property(nonatomic,readonly) uint32_t nightInternalVagCount;
@property(nonatomic,readonly) uint32_t nightInternalAnalCount;
@property(nonatomic,readonly) BOOL nightAnyClimax;
@property(nonatomic,readonly) BOOL vibeNekoUsed;
@property(nonatomic,readonly) BOOL vibeToriUsed;
@property(nonatomic,readonly) BOOL vibratorLoopActive;
@property(nonatomic,readonly) BOOL accessoryToggled;
@property(nonatomic,readonly) uint32_t flowLevel;
@property(nonatomic,readonly) uint32_t flowFlagB;
@property(nonatomic,readonly) uint32_t flowCount;
@property(nonatomic,readonly) uint32_t storyStage;
@property(nonatomic,readonly) uint32_t sceneKind;
@property(nonatomic,readonly) uint32_t sceneType;
@property(nonatomic,readonly) uint32_t mapSelector;
@property(nonatomic,readonly) uint8_t type7InitialSubMode;
@property(nonatomic,readonly) uint8_t type7LiveSubMode;
@property(nonatomic,readonly) uint8_t type7Slot0;
@property(nonatomic,readonly) uint8_t type7Slot1;
@property(nonatomic,readonly) uint8_t type7Slot2;
@property(nonatomic,readonly,nullable) NSString *bgmTrackName;
@property(nonatomic,readonly) BOOL editMode;
@property(nonatomic,readonly) BOOL interactiveScene;
@property(nonatomic) BOOL secondaryViewVisible;
@property(nonatomic) float voiceMouthPhase;
- (void)setVoiceMouthPhase:(float)phase forPrefix:(char)prefix;
- (void)applyType7PregnancyCycles:(const uint8_t *)cycles;
- (void)applyType7PubicMask:(uint8_t)pubicMask nonVirginMask:(uint8_t)nonVirginMask;
@property(nonatomic,strong,nullable) DCStartupScene *transitionScene;
- (BOOL)takeEditPauseStopRequest;
- (uint32_t)takePendingEffectSlot;
- (nullable NSString *)updateCharacterWithExitSoundBusy:(BOOL)busy tick:(uint32_t)tick;
- (nullable NSString *)updateSystemWithSelectionSoundBusy:(BOOL)busy tick:(uint32_t)tick;
- (nullable NSString *)applyConfiguration:(const dc_config *)configuration;
- (void)syncConfiguration:(dc_config *)configuration;
- (void)pause;
- (void)resumeAtTick:(uint32_t)tick;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage stageProgress:(uint32_t)progress resumeSavedPlayer:(BOOL)resume error:(NSString **)error;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage stageProgress:(uint32_t)progress
    sceneTypeOverride:(uint32_t)sceneTypeOverride resumeSavedPlayer:(BOOL)resume error:(NSString **)error;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer type7SubMode:(uint8_t)subMode
    mapSelector:(uint32_t)mapSelector slot0:(uint8_t)slot0 slot1:(uint8_t)slot1 slot2:(uint8_t)slot2
    conqueredMask:(uint8_t)conqueredMask error:(NSString **)error;
- (nullable instancetype)initWithDirectory:(NSString *)directory
    renderer:(dc_vk_sprite *)renderer editState:(const dc_edit_state *)editState error:(NSString **)error;
- (dc_status)commitType7ExitIntoFlow:(dc_flow_state *)flow outcome:(dc_type7_exit_outcome *)outcome;
- (nullable NSString *)attachRenderer:(dc_vk_sprite *)renderer;
- (void)detachRenderer;
- (nullable NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput
    width:(uint32_t)width height:(uint32_t)height;
- (nullable NSString *)takePendingVoiceName;
- (nullable NSString *)takePendingEffectName;
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
