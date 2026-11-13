#import "DCGameScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <ImageIO/ImageIO.h>
#include "dc_camera.h"
#include "dc_eyeneck.h"
#include "dc_gameplay.h"
#include "dc_scene_ui.h"
#include "dc_scene_motion.h"
#include "dc_menu.h"
#include "dc_model.h"
#include "dc_morph.h"
#include "dc_story.h"
#include "dc_xl.h"
#include <math.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct dc_game_model {
    __strong NSData *xxData,*xaData;
    dc_model *model;
    dc_xx *xx;
    dc_xx_info info;
    dc_xa_info xaInfo;
    struct dc_morph_track_cache *morphTracks;
    uint32_t morphTrackCount;
    dc_morph *morph;
    uintptr_t *textures;
    uintptr_t *baseTextures;
    uint32_t textureCount;
    dc_matrix world;
} dc_game_model;
typedef struct dc_morph_key_cache { uint32_t frame; size_t vectorsOffset; uint32_t count; } dc_morph_key_cache;
typedef struct dc_morph_track_cache {
    uint32_t meshIndex, indexCount;
    uint32_t *indices;
    uint32_t keyCount;
    dc_morph_key_cache *keys;
} dc_morph_track_cache;
typedef struct dc_walk_surface { float x[3],y[3],z[3]; } dc_walk_surface;

static dc_matrix gameIdentity(void) { return (dc_matrix){{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}}; }
static NSArray<NSNumber *> *gameMatrixValues(const dc_matrix *matrix) {
    NSMutableArray<NSNumber *> *values=[NSMutableArray arrayWithCapacity:16];
    for(unsigned i=0;i<16;++i)[values addObject:@(matrix->values[i])];
    return values;
}
static dc_vk_clip_rect gameClip(dc_viewport viewport,uint32_t width,uint32_t height) {
    uint32_t left=(uint32_t)fmaxf(0,ceilf(viewport.x-.5f)),top=(uint32_t)fmaxf(0,ceilf(viewport.y-.5f));
    uint32_t right=(uint32_t)fminf(width,ceilf(viewport.x+viewport.width-.5f));
    uint32_t bottom=(uint32_t)fminf(height,ceilf(viewport.y+viewport.height-.5f));
    return (dc_vk_clip_rect){left,top,right-left,bottom-top};
}
static dc_status gameRenderPasses(dc_vk_sprite *renderer,const dc_vk_geometry_item *draws,
        size_t primaryCount,size_t secondaryStart,size_t secondaryCount,size_t overlayStart,size_t overlayCount,
        dc_vk_clip_rect primaryClip,dc_vk_clip_rect secondaryClip,BOOL secondaryVisible,
        const uint8_t clear[4],uint8_t *pixels,size_t bytes) {
    dc_vk_geometry_pass passes[3]={{.items=draws,.count=primaryCount,.clip=primaryClip}};size_t count=1;
    if(secondaryVisible)passes[count++]=(dc_vk_geometry_pass){.items=draws+secondaryStart,.count=secondaryCount,.clip=secondaryClip,
        .clear_flags=DC_VK_CLEAR_COLOR|DC_VK_CLEAR_DEPTH,.clear_rgba={0,0,0,255}};
    if(secondaryVisible)memcpy(passes[1].clear_rgba,clear,4);
    if(overlayCount)passes[count++]=(dc_vk_geometry_pass){.items=draws+overlayStart,.count=overlayCount,.clip=primaryClip};
    return dc_vk_geometry_render_passes(renderer,passes,count,clear,pixels,bytes);
}
static uint32_t gameColor(const dc_material_value *value) {
    uint32_t out=0;
    for(uint32_t i=0;i<4;++i) {
        float v=fminf(1,fmaxf(0,value->components[i]));
        uint32_t c=(uint32_t)(v*255);
        out|=c<<(i==3?24:16-i*8);
    }
    return out;
}
static void freeMorphCaches(dc_game_model *slot) {
    if(!slot)return;
    if(slot->morph) {
        dc_morph_close(slot->morph);
        slot->morph=NULL;
    }
    if(slot->morphTracks) {
        for(uint32_t i=0;i<slot->morphTrackCount;++i) {
            free(slot->morphTracks[i].indices);
            free(slot->morphTracks[i].keys);
        }
        free(slot->morphTracks);
    }
    slot->morphTracks=NULL;slot->morphTrackCount=0;
}

@implementation DCGameScene {
    NSString *_directory;
    NSData *_eyesData,*_neckData;
    NSData *_lightData;
    dc_xl_info _lightInfo;
    dc_xl_light _mapLight;
    dc_xl_d3d_light _charD3DLights[8];
    uint32_t _charD3DLightCount;
    float _charGlobalAmbient[3];
    NSData *_mapVariantLightData;
    dc_xl_info _mapVariantLightInfo;
    dc_xl_light _mapVariantLight;
    dc_xl_d3d_light _mapD3DLights[8];
    uint32_t _mapD3DLightCount;
    float _mapGlobalAmbient[3];
    dc_glare_info _glareInfo;
    BOOL _hasGlare,_bypassLighting;
    uint8_t _sweatSheenLevel;
    dc_vk_sprite *_renderer;
    dc_game_model _map,_actor,_autoCamera,_cameraTarget;
    dc_game_model _face,_watchAuxiliary[2];
    dc_game_model _extraActors[3],_extraFaces[2];
    uint8_t _extraActorCount,_extraFaceCount;
    uint8_t _headHeroines[3],_headBodyIndices[3];
    uint32_t _extraActorHeadNodes[2];
    dc_matrix _extraFaceBindInverses[2];
    int8_t _extraEyeBlinkState[2][2];
    uint32_t _extraEyeBlinkDuration[2][2],_extraEyeBlinkEndTick[2][2];
    int32_t _extraEyeBlinkWaitTicks[2][2],_extraEyeBlinkHoldTicks[2][2];
    NSData *_extraEyesData[2],*_extraNeckData[2];
    BOOL _extraEyeNeckValid[2];
    dc_eyeneck_slot _extraEyeSlots[2][5],_extraNeckSlots[2][3];
    dc_eyeneck_controller _extraEyeControllers[2][2],_extraNeckController[2];
    dc_eyeneck_tremor_state _extraEyeTremor[2];
    uint32_t _extraNeckNodes[2],_extraEyeNodes[2][2],_extraEyeHighlightNodes[2][2];
    uint32_t _extraSpringBreastNodes[2][2],_extraHairSpringNodes[2][6];
    dc_spring_node_state _extraBreastSprings[2][2],_extraHairSprings[2][6];
    dc_type7_state _type7State;
    dc_type7_assets _type7Assets;
    dc_type7_menu _type7Menu;
    uint8_t _type7PregnancyCycles[3],_type7PubicMask,_type7NonVirginMask;
    dc_animation_clip _type7Clips[512];
    BOOL _type7SwapPending,_type7SwapFadeInActive;
    float _type7FeedbackStep,_type7HubOriginX,_type7HubOriginY;
    dc_edit_state _editStateCopy;
    dc_edit_assets _editAssets;
    dc_edit_player _editPlayer;
    dc_edit_step_plan _editStepPlan;
    dc_animation_clip _editClips[512];
    NSData *_editNormalBodyXA,*_editOralBodyXA,*_editNormalCamData,*_editOralCamData;
    NSData *_editNormalBodyXAMulti[4],*_editOralBodyXAMulti[4];
    uint32_t _editExpectedClip,_editClimaxCount;
    uint8_t _editCamTargetHeroine,_editVagPenMask,_editAnalPenMask;
    BOOL _editUsingOralRig,_editExitFadeStarted,_editClickCandidate;
    float _editClickOriginX,_editClickOriginY;
    NSString *_pendingEffectName;
    uintptr_t _whiteTexture,_glareTexture;
    dc_matrix _cameraBase,_actorWorld;
    float _cameraOriginX,_cameraOriginZ,_actorOriginX,_actorOriginY,_actorOriginZ;
    float _cameraDistance,_cameraHeight,_cameraPitch,_cameraYaw;
    float _padCameraYaw,_padCameraPitch,_padCameraZoom,_padCameraHeight;
    float _padCameraPanX,_padCameraPanZ;
    BOOL _mapLayerVisible[3];
    uint32_t _cameraPreset;
    NSData *_cameraPresetData;
    dc_camera_orbit _secondaryCamera;
    dc_camera_pointer_limits _secondaryLimits;
    dc_matrix _secondaryRenderedWorld,_secondaryTarget;
    dc_viewport _secondaryViewport;
    BOOL _secondaryVisible;
    uint32_t _pointerCameraOwner;
    uint32_t _secondaryActions,_secondaryRetargets,_secondaryResets,_secondaryAutoFrames,_secondaryPointerUpdates,_secondaryVisibilityChanges;
    uint32_t _secondaryAutoEnters,_secondaryAutoLeaves,_secondaryLastPointerOperation;
    dc_camera_orbit _secondaryPointerBefore;
    dc_camera_pointer_input _secondaryLastPointer;
    uint32_t _secondaryTargetBinding;
    dc_matrix _lastCameraTarget;
    uint32_t _primaryCameraMode,_secondaryCameraMode;
    uint32_t _cameraActionCount,_cameraResetCount,_cameraRetargetCount,_pendingContextActions;
    uint32_t _cameraBodyRetargetCount,_cameraAutoEnterCount,_cameraAutoLeaveCount,_cameraAutoFrames;
    uint32_t _lastCameraTargetBinding;
    dc_matrix _renderedCameraWorld,_autoCameraEye,_autoCameraTarget;
    BOOL _cameraAutoSelected;
    NSMutableDictionary<NSNumber *, NSValue *> *_cameraFallbacks;
    uint32_t _actorHeadNode;
    dc_matrix _faceBindInverse;
    int8_t _eyeBlinkState[2];
    uint32_t _eyeBlinkDuration[2],_eyeBlinkEndTick[2];
    int32_t _eyeBlinkWaitTicks[2],_eyeBlinkHoldTicks[2];
    float _actorRootFloorOffset;
    BOOL _captureGameplayFrame,_capturedGameplayFrame;
    BOOL _framePresented,_resumedPlayer;
    NSString *_anchorName,*_cameraSource,*_requestedRenderCapture;
    NSDictionary *_lastRenderCapture;
    uint32_t _lastTick; BOOL _tickInitialized,_needsResumeAtNextTick;
    float _lastInputX,_lastInputY; BOOL _inputInitialized;
    dc_menu_state _gameMenu; BOOL _gameMenuInitialized,_previousGameMenuTouch;
    float _walkMinX,_walkMaxX,_walkMinZ,_walkMaxZ;
    dc_game_player _player;
    BOOL _playerSaveDirty,_manualSaveCompleted;
    dc_game_interaction_state _interactionState;
    DCArchive *_sceneUIArchive;
    NSMutableDictionary<NSString *,NSNumber *> *_sceneUITextures;
    DCArchive *_rpp15Archive;
    NSMutableDictionary<NSString *,NSNumber *> *_rpp15Textures;
    dc_scene_context _contextMenu;
    BOOL _contextOpen;
    dc_scene_character_state _characterAction;
    dc_scene_motion_state _motionState;
    BOOL _motionStateInitialized,_motionAudioReady;
    uint32_t _pendingEffectSlot,_characterActionCount,_characterAnimationStarts;
    BOOL _hasPendingEffect,_characterClockInitialized;
    uint32_t _characterLastTick,_exitSoundWaitMs,_exitSoundStartTick;
    BOOL _exitSoundBusyObserved,_characterReturnedIdle;
    int32_t _mainIconHover,_lastContextSelection;
    uint32_t _stageProgress,_contextOpens,_contextSelections,_contextDismissals,_sceneUIDraws;
    uint32_t _sceneUIIconDraws;
    size_t _sceneUIVisiblePixels,_sceneContextVisiblePixels;
    BOOL _interactionActive;uint32_t _interactionStartTick;
    uint32_t _interactionCount;BOOL _interactionCompleted;
    uint32_t _storyChapter,_storyStage,_storyPhase,_mapSelector;
    uint32_t _sceneKind,_sceneType;
    char _characterPrefix;
    uint32_t _acceptedMenuEvents,_lastAcceptedMenuRow;
    uint32_t _stageOutcomeA,_stageOutcomeB,_chapterEndAction;
    uint32_t _watchElapsedMs,_watchClimaxElapsedMs,_pos2SelectedCount;
    uint32_t _pendingSystemAction,_outfitVariant;
    uint8_t _backgroundColor[4];
    BOOL _editMode;
    BOOL _editPaused,_editPauseStopRequested;
    uint8_t _editSpeedMode;
    BOOL _nightQuestionAsked;
    BOOL _tearVisible;
    BOOL _hairVisible,_cameraTargetVisible;
    float _mapAlpha,_handAlpha,_maleBodyAlpha,_maleGenitalAlpha;
    BOOL _maleUserHidden,_maleGenitalUserHidden,_hudHidden,_f1UsedForCamera;
    BOOL _renderingSecondaryViewport,_pendingUserScreenshot;
    uint32_t _userScreenshotSerial;
    BOOL _primaryCameraTargetActive,_secondaryCameraTargetActive;
    BOOL _faceBlushActive,_voiceBlushActive,_inExternalClimax,_nightHadInternalClimax;
    uint8_t _externalClimaxLevel;
    uint32_t _nightInternalVagCount,_nightInternalAnalCount,_nightExternalClimaxCount;
    uint32_t _watchRedressTimerMs,_watchRedressCount;
    uint32_t _materialCycleSlot,_lastMaterialCycleTick,_lastDynamicTexMask;
    BOOL _gameFinished;
    NSString *_pendingVoiceName;
    float _voiceMouthPhase,_voiceMouthPhaseByHeroine[3],_actorPlaybackSpeed;
    BOOL _watchDragging,_nightDragging;
    BOOL _scene4ObservedOnce,_watchPendingExitAfterClimax,_accessoryHidden,_watchAuxUserHidden;
    BOOL _watchNekoVibeVisible,_watchToriVibeVisible,_watchVibeSwitch;
    BOOL _vibeNekoUsed,_vibeToriUsed,_accessoryToggled;
    uint8_t _watchTopStage,_watchSkirtStage,_watchPantyStage;
    uint8_t _lastWatchTopStage,_lastWatchSkirtStage,_lastWatchPantyStage;
    uint8_t _clothingTopState,_clothingBraState,_clothingSkirtState,_clothingPantyState,_clothingShoeState,_clothingAccState;
    uint8_t _lastClothingTopState,_lastClothingBraState,_lastClothingSkirtState,_lastClothingPantyState,_lastClothingShoeState,_lastClothingAccState;
    int32_t _watchPart,_hoverTargetHit,_cursorIndex;
    int32_t _lastClothingPart;uint32_t _lastClothingClip;
    uint32_t _targetNodes[7],_skirtTargetNodes[2],_watchContactNodes[5],_breastNodes[2],_kosiNode;
    uint32_t _eyeNodes[2],_eyeHighlightNodes[2],_neckNode,_maleEyeTargetNode,_springBreastNodes[2],_hairSpringNodes[6];
    BOOL _eyeNeckValid;
    dc_eyeneck_slot _eyeSlots[5],_neckSlots[3];
    dc_eyeneck_controller _eyeControllers[2],_neckController;
    dc_eyeneck_tremor_state _eyeTremor;
    dc_spring_node_state _breastSprings[2],_hairSprings[6];
    float _cursorX,_cursorY;
    float _watchTouchGauge,_watchFeedbackStep,_watchUndressStep,_watchDragVelocity;
    float _watchSlideTheta,_watchSlidePhi;
    uint8_t _watchScrubState,_watchScrubKind;
    BOOL _watchScrubInvert,_watchPose7Active;
    uint32_t _watchScrubClip,_watchScrubFinishClip,_watchScrubReturnClip;
    float _watchScrubProgress,_watchScrubTremorPhase;
    uint32_t _watchPose7IdleMs,_watchPose7DurationMs;
    uint32_t _scene4IdleMs,_scene4StageDecayMs,_scene4PendingEntryClip;
    uint8_t _nightPosMode;
    float _nightExcitement,_nightFeedbackStep,_nightDragVelocity;
    uint32_t _lastUndressClip;
    uint32_t _strippedCountAtClimax,_oralClimaxCount,_oralSwallowCount;
    uint32_t _voiceSequenceIndex;
    BOOL _naturalGameplayRoute;
    uint32_t _actorSkinMeshCount;
    BOOL _actorSkinAdvanced;
    BOOL _controllerMovementAdvanced,_controllerCameraAdvanced;
    dc_walk_surface *_surfaces;size_t _surfaceCount,_surfaceCapacity;
    BOOL _loaded;
    uint32_t _visibleMapTriangles,_visibleActorTriangles;
}
- (BOOL)loaded { return _loaded; }
- (uint32_t)visibleMapTriangles { return _visibleMapTriangles; }
- (uint32_t)visibleActorTriangles { return _visibleActorTriangles; }
- (uint32_t)interactionCount { return _interactionCount; }
- (BOOL)interactionCompleted { return _interactionCompleted; }
- (BOOL)interactionActive { return _interactionActive; }
- (BOOL)gameFinished { return _gameFinished; }
- (uint32_t)chapter { return _storyChapter; }
- (uint32_t)chapterEndAction { return _chapterEndAction; }
- (uint32_t)stageOutcomeA { return _stageOutcomeA; }
- (uint32_t)stageOutcomeB { return _stageOutcomeB; }
- (uint32_t)watchClimaxElapsedMs { return _watchClimaxElapsedMs; }
- (uint32_t)outfitVariant { return _outfitVariant; }
- (uint32_t)pos2SelectedCount { return _pos2SelectedCount; }
- (uint32_t)strippedCountAtClimax {
    if(_strippedCountAtClimax>0)return _strippedCountAtClimax;
    uint32_t stripped=0;
    if(_clothingTopState>=2)++stripped;
    if(_clothingBraState>=2)++stripped;
    if(_clothingSkirtState>=2)++stripped;
    if(_clothingPantyState>=2)++stripped;
    if(_clothingShoeState>=1)++stripped;
    if(_clothingAccState>=1)++stripped;
    return stripped;
}
- (uint32_t)oralClimaxCount { return _oralClimaxCount; }
- (uint32_t)oralSwallowCount { return _oralSwallowCount; }
- (uint32_t)nightInternalVagCount { return _nightInternalVagCount; }
- (uint32_t)nightInternalAnalCount { return _nightInternalAnalCount; }
- (BOOL)nightAnyClimax { return _nightHadInternalClimax||_nightExternalClimaxCount>0u; }
- (BOOL)vibeNekoUsed { return _vibeNekoUsed; }
- (BOOL)vibeToriUsed { return _vibeToriUsed; }
- (BOOL)vibratorLoopActive {
    if(_sceneType==7)return (_type7State.vibe_mask!=0&&_type7State.vibe_fast!=0)&&!_characterAction.exit_pending&&!_characterAction.transition_pending&&!_type7SwapPending;
    if(_sceneType==12)return (_editPlayer.vibe_mask!=0u)&&!_editPaused&&!_editExitFadeStarted&&!_pendingSystemAction;
    return _watchVibeSwitch && !(_editMode && _editPaused) && !_characterAction.exit_pending && !_characterAction.transition_pending;
}
- (BOOL)accessoryToggled { return _accessoryToggled; }
- (uint32_t)flowLevel { return _sceneType==6?(uint32_t)_clothingPantyState:(_chapterEndAction==2?2:0); }
- (uint32_t)flowFlagB { return _sceneType==6?(_accessoryToggled?1u:0u):(_chapterEndAction==2?1:0); }
- (uint32_t)flowCount {
    if(_motionStateInitialized&&_motionState.sample_count)return _motionState.sample_count;
    return _interactionCount;
}
- (uint32_t)storyStage { return _storyStage; }
- (uint32_t)sceneKind { return _sceneKind; }
- (uint32_t)sceneType { return _sceneType; }
- (uint32_t)mapSelector { return _mapSelector; }
- (uint8_t)type7InitialSubMode { return _type7State.initial_sub_mode; }
- (uint8_t)type7LiveSubMode { return _type7State.sub_mode; }
- (uint8_t)type7Slot0 { return _type7State.slots[0]; }
- (uint8_t)type7Slot1 { return _type7State.heroine_count>=2u?_type7State.slots[1]:255u; }
- (uint8_t)type7Slot2 { return _type7State.heroine_count>=3u?_type7State.slots[2]:255u; }
- (NSString *)bgmTrackName {
    if(_sceneType==7&&_type7Assets.bgm_name[0]!='\0')return [NSString stringWithUTF8String:_type7Assets.bgm_name];
    if(_sceneType==12&&_editAssets.bgm_name[0]!='\0')return [NSString stringWithUTF8String:_editAssets.bgm_name];
    return nil;
}
- (dc_status)commitType7ExitIntoFlow:(dc_flow_state *)flow outcome:(dc_type7_exit_outcome *)outcome {
    return dc_type7_commit_exit(&_type7State,flow,outcome);
}
- (dc_game_model *)bodySlotAtIndex:(uint32_t)idx {
    if(idx==0u)return &_actor;
    if(idx<=3u)return &_extraActors[idx-1u];
    return NULL;
}
- (dc_game_model *)faceSlotAtIndex:(uint32_t)idx {
    if(idx==0u)return &_face;
    if(idx<=2u)return &_extraFaces[idx-1u];
    return NULL;
}
- (BOOL)interactiveScene { return (_sceneType>=4&&_sceneType<=7)||_sceneType==12; }
- (BOOL)secondaryViewVisible { return _secondaryVisible; }
- (void)setSecondaryViewVisible:(BOOL)visible { _secondaryVisible=visible&&((_sceneType>=4&&_sceneType<=7)||_sceneType==12); }
- (float)voiceMouthPhase { return _voiceMouthPhase; }
- (void)setVoiceMouthPhase:(float)phase {
    _voiceMouthPhase=isfinite(phase)&&phase>0.f?phase:0.f;
    if(_voiceMouthPhase<=0.01f&&!_pendingVoiceName)_voiceBlushActive=NO;
}
- (void)setVoiceMouthPhase:(float)phase forPrefix:(char)prefix {
    char lo=(char)tolower((unsigned char)prefix);
    int idx=(lo=='b')?0:((lo=='c')?1:((lo=='a')?2:-1));
    if(idx>=0)_voiceMouthPhaseByHeroine[idx]=(isfinite(phase)&&phase>0.f)?phase:0.f;
}
- (void)applyType7PregnancyCycles:(const uint8_t *)cycles {
    if(!cycles)return;
    for(unsigned i=0;i<3u;++i)_type7PregnancyCycles[i]=cycles[i];
    if(_sceneType!=7)return;
    for(uint32_t hIdx=0;hIdx<_type7Assets.head_count&&hIdx<3u;++hIdx) {
        uint8_t h=_headHeroines[hIdx];
        if(h>=3u)continue;
        uint8_t cyc=_type7PregnancyCycles[h];
        uint8_t belly=(cyc>=5u)?2u:((cyc==4u)?1u:0u);
        if(belly>0u)
            [self applyEditBellyModifiersForBody:[self bodySlotAtIndex:_headBodyIndices[hIdx]] prefix:dc_type7_heroine_prefix(h) level:belly];
    }
}
- (void)applyType7PubicMask:(uint8_t)pubicMask nonVirginMask:(uint8_t)nonVirginMask {
    _type7PubicMask=pubicMask;
    _type7NonVirginMask=nonVirginMask;
    _lastDynamicTexMask=UINT32_MAX;
}
- (void)queueCharacterVoice:(NSString *)stem {
    if(!stem.length||_pendingVoiceName)return;
    _pendingVoiceName=[NSString stringWithFormat:@"%c%@",_characterPrefix,stem];
    NSString *lower=stem.lowercaseString;
    _voiceBlushActive=([lower hasPrefix:@"kx003"]||[lower hasPrefix:@"kx004"]||[lower hasPrefix:@"kx008"]||[lower hasPrefix:@"kx009"]||
                       [lower hasPrefix:@"cd00"]||[lower hasPrefix:@"cg004"]||[lower hasPrefix:@"cg007"]||[lower hasPrefix:@"cg008"]||
                       [lower hasPrefix:@"hd00"]||[lower hasPrefix:@"hd90"]||[lower hasPrefix:@"ht004"]||
                       [lower hasPrefix:@"zg00"]||[lower hasPrefix:@"zd00"]||[lower hasPrefix:@"zd10"]);
}
- (void)queueNightQuestionVoice:(uint32_t)questionIndex inserted:(BOOL)inserted {
    if(questionIndex>3u)return;
    _pendingVoiceName=nil;
    BOOL prog2=(_stageProgress>=2u||_editMode);
    uint32_t alt=(_voiceSequenceIndex++)&1u;
    NSString *stem=nil;
    if(!prog2) {
        if(!inserted) {
            if(questionIndex==0u)stem=(_stageProgress==1u&&_nightPosMode==0u)?@"hg901_01.wav":((_nightPosMode==0u)?@"hg902_01.wav":@"hg903_01.wav");
            else if(questionIndex==1u)stem=@"hg904_01.wav";
            else if(questionIndex==2u)stem=@"hg905_01.wav";
            else stem=@"hg906_01.wav";
        } else {
            if(questionIndex==0u)stem=@"hg907_01.wav";
            else if(questionIndex==1u)stem=@"hg908_01.wav";
            else if(questionIndex==2u)stem=@"hg909_01.wav";
            else stem=(_nightPosMode==0u)?@"hg910_01.wav":@"hg911_01.wav";
        }
    } else {
        if(!inserted) {
            if(questionIndex==0u)stem=alt?@"hd901_02.wav":@"hd901_01.wav";
            else if(questionIndex==1u)stem=alt?@"hd904_02.wav":@"hd904_01.wav";
            else if(questionIndex==2u)stem=@"hd905_01.wav";
            else stem=alt?@"hd906_02.wav":@"hd906_01.wav";
        } else {
            if(questionIndex==0u)stem=@"hd907_01.wav";
            else if(questionIndex==1u)stem=alt?@"hd908_02.wav":@"hd908_01.wav";
            else if(questionIndex==2u)stem=alt?@"hd909_02.wav":@"hd909_01.wav";
            else stem=(_nightPosMode==0u)?@"ht009_01.wav":@"hd911_01.wav";
        }
    }
    if(stem)[self queueCharacterVoice:stem];
}
- (void)queueCyclicReactionVoiceForScene:(uint32_t)sceneType climax:(BOOL)climax {
    if(_pendingVoiceName)return;
    static NSString *const kClimaxStems[]={@"zg001_01.wav",@"zd001_01.wav",@"zg101_01.wav",@"zd101_01.wav",@"zt001_01.wav"};
    static NSString *const kTouchStems[]={@"kx001_01.wav",@"kx002_01.wav",@"kx003_01.wav",@"kx004_01.wav",@"kx005_01.wav",@"cg001_01.wav",@"cd001_01.wav",@"cg002_01.wav"};
    static NSString *const kNightStems[]={@"hd001_01.wav",@"hd001_02.wav",@"hd001_03.wav",@"hg001_01.wav",@"hg001_02.wav",@"hg001_03.wav",@"ht001_01.wav",@"ht002_01.wav"};
    if(climax) {
        NSString *stem=kClimaxStems[(_voiceSequenceIndex++)%5];
        [self queueCharacterVoice:stem];
    } else if(sceneType==6) {
        NSString *stem=kNightStems[(_voiceSequenceIndex++)%8];
        [self queueCharacterVoice:stem];
    } else {
        NSString *stem=kTouchStems[(_voiceSequenceIndex++)%8];
        [self queueCharacterVoice:stem];
    }
}
- (BOOL)actorSkinAdvanced { return _actorSkinAdvanced; }
- (BOOL)controllerMovementAdvanced { return _controllerMovementAdvanced; }
- (BOOL)controllerCameraAdvanced { return _controllerCameraAdvanced; }
- (BOOL)manualSaveCompleted { return _manualSaveCompleted; }
- (NSDictionary *)lastRenderCapture { return _lastRenderCapture; }
- (NSString *)presentationContext {
    if(!_framePresented)return @"";
    dc_animation_state animation={0};dc_model_get_animation(_actor.model,&animation);
    return [NSString stringWithFormat:@"chapter=%u scene=%u type=%u map=%u stage=%u progress=%u actor=%c anchor=%@ camera=%@ resumed=%d menu_events=%u menu_row=%u ui_draws=%u ui_pixels=%zu context_pixels=%zu context_open=%d context_icon=%u context_count=%u context_opens=%u context_selections=%u context_dismissals=%u context_selected=%d camera_actions=%u camera_retargets=%u camera_resets=%u pending_actions=%u character_actions=%u character_starts=%u character_clip=%u character_idle=%d character_exit=%u exit_sound_busy=%d exit_sound_ms=%u exit_transition=%u camera_mode=%u camera_body=%u camera_auto_on=%u camera_auto_off=%u camera_auto_samples=%u secondary_visible=%d secondary_mode=%u secondary_actions=%u secondary_retargets=%u secondary_resets=%u secondary_auto_samples=%u secondary_pointer_updates=%u secondary_pointer_operation=%u secondary_visibility_changes=%u context_callbacks=cameras-initial-character",
        _storyChapter,_sceneKind,_sceneType,_mapSelector,_storyStage,_stageProgress,_characterPrefix,_anchorName,_cameraSource,_resumedPlayer,_acceptedMenuEvents,_lastAcceptedMenuRow,
        _sceneUIDraws,_sceneUIVisiblePixels,_sceneContextVisiblePixels,_contextOpen,_contextMenu.icon,_contextMenu.count,_contextOpens,_contextSelections,_contextDismissals,_lastContextSelection,
        _cameraActionCount,_cameraRetargetCount,_cameraResetCount,_pendingContextActions,
        _characterActionCount,_characterAnimationStarts,animation.current,_characterReturnedIdle,_characterAction.exit_pending,
        _exitSoundBusyObserved,_exitSoundWaitMs,_characterAction.transition_pending,
        _primaryCameraMode,_cameraBodyRetargetCount,_cameraAutoEnterCount,_cameraAutoLeaveCount,MIN(_cameraAutoFrames,8u),
        _secondaryVisible,_secondaryCameraMode,_secondaryActions,_secondaryRetargets,_secondaryResets,MIN(_secondaryAutoFrames,8u),_secondaryPointerUpdates,_secondaryLastPointerOperation,_secondaryVisibilityChanges];
}
- (void)requestRenderCapture:(NSString *)name {
    if([name.lastPathComponent isEqualToString:name]&&[name.pathExtension isEqualToString:@"png"])
        _requestedRenderCapture=[name copy];
}
- (NSString *)takePendingVoiceName { NSString *name=_pendingVoiceName;_pendingVoiceName=nil;return name; }
- (NSString *)takePendingEffectName { NSString *name=_pendingEffectName;_pendingEffectName=nil;return name; }
- (BOOL)takeEditPauseStopRequest {
    if(!_editPauseStopRequested)return NO;
    _editPauseStopRequested=NO;return YES;
}
- (void)toggleEditPauseOrResetSpeed {
    if(_editSpeedMode!=0) {
        _editSpeedMode=0;_editPaused=NO;
    } else {
        _editPaused=!_editPaused;
        if(_editPaused){_pendingVoiceName=nil;_pendingEffectName=nil;_editPauseStopRequested=YES;}
    }
    if(_sceneType==12){_editPlayer.paused=_editPaused?1u:0u;_editPlayer.ff_mode=_editSpeedMode;}
}
- (void)cycleEditSpeedMode {
    if(_editSpeedMode==0) {
        _editSpeedMode=1u;_editPaused=NO;
    } else {
        _editSpeedMode=(uint8_t)((_editSpeedMode%3u)+1u);
    }
    if(_sceneType==12){_editPlayer.paused=0u;_editPlayer.ff_mode=_editSpeedMode;}
}
- (uint32_t)takePendingEffectSlot {
    if(!_hasPendingEffect)return DC_SCENE_NO_REQUEST;
    _hasPendingEffect=NO;return _pendingEffectSlot;
}
- (NSString *)applyCharacterEvent:(dc_scene_character_event)event tick:(uint32_t)tick {
    if(event.configure_animation) {
        int32_t loopCount=(int32_t)MIN(3u,MAX(1u,_characterAction.activation_count));
        if(dc_model_set_chain(_actor.model,6,7)!=DC_OK||dc_model_set_loop(_actor.model,5,loopCount)!=DC_OK)
            return @"Original character animation configuration failed";
    }
    if(event.request_clip!=DC_SCENE_NO_REQUEST) {
        uint32_t targetClip=event.request_clip;
        if(_sceneType==4&&targetClip==2u&&_scene4PendingEntryClip>=2u&&_scene4PendingEntryClip<=4u) {
            targetClip=_scene4PendingEntryClip;
            _scene4PendingEntryClip=0u;
        }
        if(dc_model_request(_actor.model,targetClip,tick)!=DC_OK)return @"Original character animation request failed";
        ++_characterAnimationStarts;
        if(_sceneType==4&&(targetClip>=2u&&targetClip<=4u)) {
            if(_interactionCount==0&&!_pendingVoiceName)[self queueCharacterVoice:@"st001_01.wav"];
            else [self queueCyclicReactionVoiceForScene:4 climax:NO];
        }
#if DEBUG
        if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
            [self requestRenderCapture:@"gameplay-character-active-native.png"];
#endif
    }
    if(event.play_slot!=DC_SCENE_NO_REQUEST){_pendingEffectSlot=event.play_slot;_hasPendingEffect=YES;}
    if(event.request_transition) {
        if(!self.transitionScene||[self.transitionScene requestTransition:event.request_transition tick:tick]!=DC_OK)
            return @"Original character exit transition failed";
    }
    return nil;
}
- (NSString *)applyMotionEvent:(dc_scene_motion_event)event tick:(uint32_t)tick {
    if(_sceneType==5&&event.request_clip!=DC_SCENE_MOTION_NO_REQUEST) {
        uint32_t hidden=(event.request_clip<0xf5u)?1:0;
        for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
            if(dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,hidden)!=DC_OK)
                return @"Original watch auxiliary visibility update failed";
    }
    if(event.request_chain_from!=DC_SCENE_MOTION_NO_REQUEST &&
       event.request_chain_to!=DC_SCENE_MOTION_NO_REQUEST) {
        if(dc_model_set_chain(_actor.model,event.request_chain_from,(int32_t)event.request_chain_to)!=DC_OK)
            return @"Original scene motion chain installation failed";
    }
    if(event.request_clip!=DC_SCENE_MOTION_NO_REQUEST) {
        if(dc_model_request(_actor.model,event.request_clip,tick)!=DC_OK)
            return @"Original scene motion animation request failed";
        ++_characterAnimationStarts;
#if DEBUG
        if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
            [self requestRenderCapture:@"gameplay-character-active-native.png"];
#endif
    }
    if(event.transition_action) {
        if(!self.transitionScene||[self.transitionScene requestTransition:event.transition_action tick:tick]!=DC_OK)
            return @"Original scene motion exit transition failed";
        _exitSoundStartTick=tick;
    }
    return nil;
}
- (NSString *)updateCharacterWithExitSoundBusy:(BOOL)busy tick:(uint32_t)tick {
    if(_needsResumeAtNextTick){_needsResumeAtNextTick=NO;if(_tickInitialized)[self resumeAtTick:tick];}
    /* Called after the preceding frame's effect request has been started.
     * Busy is the actual slot28 player, never a guessed duration. */
    uint32_t delta=_characterClockInitialized?tick-_characterLastTick:0;
    _characterClockInitialized=YES;_characterLastTick=tick;
    if(_characterAction.exit_pending&&busy)_exitSoundBusyObserved=YES;
    if(_motionStateInitialized)_motionAudioReady=!busy;
    dc_scene_character_event event;
    if(dc_scene_character_step(&_characterAction,delta,busy,&event)!=DC_OK)return @"Character action update failed";
    if(event.request_transition)_exitSoundWaitMs=tick-_exitSoundStartTick;
    dc_animation_state animation={0};dc_model_get_animation(_actor.model,&animation);
    if(_characterAnimationStarts&&animation.current==1&&!_characterReturnedIdle) {
        _characterReturnedIdle=YES;
        if(!_interactionCompleted){++_interactionCount;_interactionCompleted=YES;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
#if DEBUG
        if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
            [self requestRenderCapture:@"gameplay-character-idle-native.png"];
#endif
    }
    return [self applyCharacterEvent:event tick:tick];
}
- (NSString *)updateSystemWithSelectionSoundBusy:(BOOL)busy tick:(uint32_t)tick {
    if(!_pendingSystemAction)return nil;
    uint32_t ready=0;
    if(!self.transitionScene||[self.transitionScene queryTransitionReady:&ready]!=DC_OK)return @"System-page transition query failed";
    if(ready&&!busy){_chapterEndAction=_pendingSystemAction;_pendingSystemAction=0;}
    return nil;
}
- (void)pause {
    [self savePlayerState];
    _needsResumeAtNextTick=YES;
    _pointerCameraOwner=0;_inputInitialized=NO;_previousGameMenuTouch=NO;
    _watchDragging=NO;_nightDragging=NO;
}
- (void)resumeAtTick:(uint32_t)tick {
    uint32_t elapsed=_tickInitialized?tick-_lastTick:0;
    dc_model_shift_clock(_map.model,elapsed);dc_model_shift_clock(_actor.model,elapsed);
    if(_face.model)dc_model_shift_clock(_face.model,elapsed);
    for(unsigned b=0;b<3;++b)if(_extraActors[b].model)dc_model_shift_clock(_extraActors[b].model,elapsed);
    for(unsigned f=0;f<2;++f)if(_extraFaces[f].model)dc_model_shift_clock(_extraFaces[f].model,elapsed);
    if(_autoCamera.model)dc_model_shift_clock(_autoCamera.model,elapsed);
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
        dc_model_shift_clock(_watchAuxiliary[auxiliary].model,elapsed);
    _lastTick=_characterLastTick=tick;_characterClockInitialized=YES;
    _exitSoundStartTick+=elapsed;_interactionStartTick+=elapsed;_interactionState.start_tick+=elapsed;
    _eyeBlinkEndTick[0]+=elapsed;_eyeBlinkEndTick[1]+=elapsed;
    for(unsigned f=0;f<2;++f){_extraEyeBlinkEndTick[f][0]+=elapsed;_extraEyeBlinkEndTick[f][1]+=elapsed;}
    _lastMaterialCycleTick+=elapsed;
    _pointerCameraOwner=0;_inputInitialized=NO;_previousGameMenuTouch=NO;
    _primaryCameraTargetActive=NO;_secondaryCameraTargetActive=NO;
}
- (NSString *)applyMapLayerVisibility {
    if(!_map.model)return nil;
    for(unsigned i=0;i<3;++i){
        uint32_t node=[self findNode:&_map name:[NSString stringWithFormat:@"m_Nn_level%u",i+1]];
        if(node!=UINT32_MAX&&dc_model_hide_node(_map.model,node,!_mapLayerVisible[i])!=DC_OK)return @"Configured map visibility failed";
    }
    uint32_t fourth=[self findNode:&_map name:@"m_Nn_level4"];
    if(fourth!=UINT32_MAX){
        BOOL visible=((_mapSelector==0&&_sceneType==4)||(_mapSelector==1&&_sceneType==5))?_mapLayerVisible[2]:NO;
        dc_model_hide_node(_map.model,fourth,!visible);
    }
    uint32_t jokyaku4=[self findNode:&_map name:@"mf_On_jokyaku_4"];
    if(jokyaku4!=UINT32_MAX) {
        BOOL hideJokyaku=((_storyChapter==24&&(_sceneType==6||_sceneType==7))||_editMode);
        if(hideJokyaku)dc_model_hide_node(_map.model,jokyaku4,1);
    }
    return nil;
}
- (NSString *)applyConfiguration:(const dc_config *)configuration {
    if(!configuration)return @"Missing scene configuration";
    uint32_t secondary=0,hair=1,cameraTarget=1;float wheel=4;
    float handAlpha=1.f,maleBodyAlpha=1.f,maleGenitalAlpha=1.f;
    dc_config_switch_value(configuration,3,&hair);
    dc_config_switch_value(configuration,4,&secondary);
    dc_config_switch_value(configuration,5,&cameraTarget);
    dc_config_slider_value(configuration,3,&handAlpha);
    dc_config_slider_value(configuration,4,&maleBodyAlpha);
    dc_config_slider_value(configuration,5,&maleGenitalAlpha);
    dc_config_slider_value(configuration,6,&wheel);
    _hairVisible=hair!=0;_cameraTargetVisible=cameraTarget!=0;
    _mapAlpha=1.f;
    _handAlpha=fmaxf(0.f,fminf(1.f,handAlpha));
    _maleBodyAlpha=fmaxf(0.f,fminf(1.f,maleBodyAlpha));
    _maleGenitalAlpha=fmaxf(0.f,fminf(1.f,maleGenitalAlpha));
    _secondaryVisible=((_sceneType>=4&&_sceneType<=7)||_sceneType==12)&&secondary!=0;_secondaryLimits.wheel_step=wheel;
    for(unsigned i=0;i<3;++i){
        uint32_t visible;dc_config_switch_value(configuration,i,&visible);
        _mapLayerVisible[i]=visible!=0;
        float channel;dc_config_slider_value(configuration,7+i,&channel);_backgroundColor[i]=(uint8_t)channel;
    }
    _backgroundColor[3]=255;
    return [self applyMapLayerVisibility];
}
- (void)syncConfiguration:(dc_config *)configuration {
    if(!configuration)return;
    for(unsigned i=0;i<3;++i) {
        uint32_t cur=0;
        if(dc_config_switch_value(configuration,i,&cur)==DC_OK&&(cur!=0)!=_mapLayerVisible[i])
            dc_config_switch_toggle(configuration,i);
    }
    if((_sceneType>=4&&_sceneType<=7)||_sceneType==12) {
        uint32_t cur=0;
        if(dc_config_switch_value(configuration,4,&cur)==DC_OK&&(cur!=0)!=_secondaryVisible)
            dc_config_switch_toggle(configuration,4);
    }
}
- (dc_camera_orbit)activeCameraOrbit {
    float height=fmaxf(_secondaryLimits.low,fminf(_secondaryLimits.high,_cameraHeight+_padCameraHeight));
    dc_camera_orbit orbit={.base=_cameraBase,.stored_distance=_cameraDistance*expf(_padCameraZoom),
        .height=height,.pitch=_cameraPitch+_padCameraPitch,.yaw=_cameraYaw+_padCameraYaw};
    float offsetX=(_player.x!=0.f||_player.z!=0.f)?(_player.x-_actorOriginX):(_actor.world.values[12]-_actorOriginX);
    float offsetZ=(_player.x!=0.f||_player.z!=0.f)?(_player.z-_actorOriginZ):(_actor.world.values[14]-_actorOriginZ);
    orbit.base.values[12]=_cameraOriginX+offsetX+_padCameraPanX;
    orbit.base.values[13]=_cameraBase.values[13]+_actor.world.values[13]-_actorOriginY;
    orbit.base.values[14]=_cameraOriginZ+offsetZ+_padCameraPanZ;
    return orbit;
}
- (void)adoptCameraOrbit:(dc_camera_orbit)orbit {
    _cameraBase=orbit.base;
    float offsetX=(_player.x!=0.f||_player.z!=0.f)?(_player.x-_actorOriginX):(_actor.world.values[12]-_actorOriginX);
    float offsetZ=(_player.x!=0.f||_player.z!=0.f)?(_player.z-_actorOriginZ):(_actor.world.values[14]-_actorOriginZ);
    _cameraBase.values[12]-=offsetX;
    _cameraBase.values[13]-=_actor.world.values[13]-_actorOriginY;
    _cameraBase.values[14]-=offsetZ;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _cameraDistance=orbit.stored_distance;_cameraHeight=orbit.height;_cameraPitch=orbit.pitch;_cameraYaw=orbit.yaw;
    _padCameraYaw=_padCameraPitch=_padCameraZoom=_padCameraHeight=_padCameraPanX=_padCameraPanZ=0;
    _cameraAutoSelected=YES;
}
- (NSString *)applyContextSelection:(uint32_t)selection {
    BOOL touchExercise=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"];
    if(_contextMenu.icon==2) {
        if(!touchExercise) {
            [self applyClothingContextSelection:selection];
            return nil;
        }
        if(selection<4) {
            _outfitVariant=selection&3u;
            [self applyOutfitVariant:_outfitVariant];
            _pendingEffectSlot=2;_hasPendingEffect=YES;
            ++_characterActionCount;
            return nil;
        }
        ++_pendingContextActions;
        return nil;
    }
    if(_contextMenu.icon==1) {
        int32_t resourceId=(selection<_contextMenu.count)?_contextMenu.items[selection].resource_id:-1;
        if(_sceneType==4&&(_stageProgress>0||_editMode)&&!touchExercise) {
            if(_characterAction.exit_pending||_characterAction.transition_pending)return nil;
            dc_animation_state anim={0};dc_model_get_animation(_actor.model,&anim);
            ++_characterActionCount;
            if(resourceId==1) {
                _actorPlaybackSpeed=1.0f;
                _scene4IdleMs=0u;_scene4StageDecayMs=0u;
                if(_characterAction.activation_count<10000u)++_characterAction.activation_count;
                int32_t loopCount=(int32_t)MIN(3u,MAX(1u,_characterAction.activation_count));
                dc_model_set_loop(_actor.model,5,loopCount);
                uint32_t entryClip=2u;
                if(anim.current==11) {
                    dc_model_set_chain(_actor.model,6,17);
                    dc_model_set_chain(_actor.model,17,11);
                    entryClip=3u;
                } else if(anim.current==13) {
                    dc_model_set_chain(_actor.model,6,18);
                    dc_model_set_chain(_actor.model,18,13);
                    entryClip=4u;
                } else {
                    dc_model_set_chain(_actor.model,6,7);
                    dc_model_set_chain(_actor.model,7,1);
                    entryClip=2u;
                }
                if(_naturalGameplayRoute) {
                    _scene4PendingEntryClip=entryClip;
                    _characterAction.delay_pending=1;
                    _characterAction.delay_ms=0u;
                    _scene4ObservedOnce=YES;
                    if(!_interactionCompleted){++_interactionCount;_interactionCompleted=YES;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
                    return nil;
                }
                if(dc_model_request(_actor.model,entryClip,_lastTick)!=DC_OK)return @"Original character animation request failed";
                ++_characterAnimationStarts;
                _pendingEffectSlot=22;_hasPendingEffect=YES;
                [self queueCyclicReactionVoiceForScene:4 climax:NO];
                if(!_interactionCompleted){++_interactionCount;_interactionCompleted=YES;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
                return nil;
            } else if(resourceId==2||resourceId==3) {
                _actorPlaybackSpeed=1.0f;
                _watchVibeSwitch=NO;
                _characterAction.exit_pending=1;
                _exitSoundStartTick=_lastTick;
                _pendingEffectSlot=28;_hasPendingEffect=YES;
                if(!_interactionCompleted){++_interactionCount;_interactionCompleted=YES;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
                return nil;
            } else if(resourceId==4||resourceId==5) {
                _scene4IdleMs=0u;_scene4StageDecayMs=0u;
                if(_storyStage==2) {
                    if(_clothingTopState<6u)_clothingTopState=(uint8_t)(6u+(_clothingTopState%2u));
                } else {
                    if(_clothingSkirtState<3u)_clothingSkirtState=3u;
                }
                if(_naturalGameplayRoute) {
                    if(_clothingPantyState==0u)_clothingPantyState=1u;
                } else {
                    if(_clothingPantyState<2u)_clothingPantyState=2u;
                }
                if(_naturalGameplayRoute) {
                    if(resourceId==4){_watchNekoVibeVisible=YES;_vibeNekoUsed=YES;if(_storyStage!=1&&_stageProgress<=1)_tearVisible=YES;}
                    else {_watchToriVibeVisible=YES;_vibeToriUsed=YES;if(_storyStage!=0||_stageProgress<=1)_tearVisible=YES;}
                    if(_actorPlaybackSpeed<1.25f)_actorPlaybackSpeed=1.25f;
                } else {
                    _actorPlaybackSpeed=1.0f;
                    _watchNekoVibeVisible=(resourceId==4);
                    _watchToriVibeVisible=(resourceId==5);
                    if(resourceId==4){_vibeNekoUsed=YES;if(_storyStage!=1&&_stageProgress<=1)_tearVisible=YES;}
                    else {_vibeToriUsed=YES;if(_storyStage!=0||_stageProgress<=1)_tearVisible=YES;}
                }
                [self syncLegacyClothingSummary];
                [self applyClothingVisibility];
                _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                dc_model_set_chain(_actor.model,10,(!_naturalGameplayRoute&&resourceId==5)?12:11);
                dc_model_set_chain(_actor.model,12,13);
                dc_model_set_chain(_actor.model,14,11);
                if(!_naturalGameplayRoute||anim.current==1) {
                    uint32_t entryClip=(!_naturalGameplayRoute&&anim.current==13)?14u:10u;
                    if(dc_model_request(_actor.model,entryClip,_lastTick)!=DC_OK)return @"Original character animation request failed";
                    ++_characterAnimationStarts;
                }
                _pendingEffectSlot=2;_hasPendingEffect=YES;
                [self queueCyclicReactionVoiceForScene:4 climax:NO];
                return nil;
            } else if(resourceId==6) {
                _actorPlaybackSpeed=1.0f;
                _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
                if(_clothingPantyState==1u)_clothingPantyState=0u;
                for(NSString *v in @[@"a_On_neko_vive",@"a_On_tori_vive"]) {
                    uint32_t vn=[self findNode:&_actor name:[self characterNode:v]];
                    if(vn!=UINT32_MAX)dc_model_hide_node(_actor.model,vn,1);
                }
                [self syncLegacyClothingSummary];
                [self applyClothingVisibility];
                _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                dc_model_set_chain(_actor.model,6,7);
                dc_model_set_chain(_actor.model,15,1);
                dc_model_set_chain(_actor.model,16,1);
                uint32_t entryClip=(anim.current==13)?16u:((anim.current==11)?15u:1u);
                if(dc_model_request(_actor.model,entryClip,_lastTick)!=DC_OK)return @"Original character animation request failed";
                ++_characterAnimationStarts;
                _pendingEffectSlot=2;_hasPendingEffect=YES;
                return nil;
            } else if(resourceId==7||resourceId==8) {
                dc_model_set_chain(_actor.model,12,13);
                dc_model_set_chain(_actor.model,14,11);
                uint32_t entryClip=(resourceId==8||anim.current==13)?14u:12u;
                _watchVibeSwitch=(entryClip==12u);
                _actorPlaybackSpeed=(_naturalGameplayRoute)?((entryClip==12u)?1.65f:1.25f):1.0f;
                if(dc_model_request(_actor.model,entryClip,_lastTick)!=DC_OK)return @"Original character animation request failed";
                ++_characterAnimationStarts;
                _pendingEffectSlot=3;_hasPendingEffect=YES;
                if(entryClip==12u)[self queueCyclicReactionVoiceForScene:4 climax:NO];
                return nil;
            }
        }
        if((_sceneType==5&&resourceId==7)||(_sceneType==6&&(resourceId==3||resourceId==13))) {
            if(_characterAction.exit_pending||_characterAction.transition_pending)return nil;
            ++_characterActionCount;
            _watchPart=-1;_watchDragging=NO;_nightDragging=NO;_watchVibeSwitch=NO;_actorPlaybackSpeed=1.0f;
            if(_sceneType==5) {
                for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                    dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
            }
            _characterAction.exit_pending=1;
            _exitSoundStartTick=_lastTick;
            _pendingEffectSlot=28;_hasPendingEffect=YES;
            if(!_interactionCompleted){++_interactionCount;_interactionCompleted=YES;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
            return nil;
        }
        if(_sceneType==5&&resourceId==6) {
            ++_characterActionCount;
            _watchPart=-1;_watchDragging=NO;_actorPlaybackSpeed=1.0f;
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
            _motionState.clip=249u;_motionState.phase=1;
            if(dc_model_request(_actor.model,249u,_lastTick)!=DC_OK)return @"Original watch return animation request failed";
            ++_characterAnimationStarts;
            _pendingEffectSlot=2;_hasPendingEffect=YES;
            return nil;
        }
        if(_sceneType==5&&resourceId>=1&&resourceId<=4&&!_motionStateInitialized) {
            ++_characterActionCount;
            static const uint32_t kWatchMenuClips[4]={4,5,2,7};
            static const int32_t kWatchMenuParts[4]={2,3,0,5};
            uint32_t idx=(uint32_t)(resourceId-1);
            _watchPart=kWatchMenuParts[idx];_watchDragging=NO;_actorPlaybackSpeed=1.0f;
            unsigned activeAux=(_watchPart==1||_watchPart==5)?0u:1u;
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,auxiliary==activeAux?0:1);
            if(dc_model_request(_actor.model,kWatchMenuClips[idx],_lastTick)!=DC_OK)return @"Original watch menu animation request failed";
            ++_characterAnimationStarts;
            _pendingEffectSlot=3;_hasPendingEffect=YES;
            [self queueCyclicReactionVoiceForScene:5 climax:NO];
            return nil;
        }
        if((_sceneType==5||_sceneType==6)&&_motionStateInitialized) {
            if(_sceneType==6) {
                dc_animation_state animation={0};
                if(dc_model_get_animation(_actor.model,&animation)==DC_OK&&animation.current<=0xffu)
                    _motionState.clip=animation.current;
                if(resourceId>=19&&resourceId<=22) {
                    ++_characterActionCount;
                    BOOL inserted=(_motionState.clip>=10u&&_motionState.clip<=54u);
                    if(inserted)_nightQuestionAsked=YES;
                    _pendingEffectSlot=1u;_hasPendingEffect=YES;
                    [self queueNightQuestionVoice:(uint32_t)(resourceId-19) inserted:inserted];
                    return nil;
                }
                if(resourceId==9||resourceId==10||((_motionState.clip>=10&&_motionState.clip<=26)&&selection<2)) {
                    ++_characterActionCount;
                    BOOL separate=(resourceId==10||selection==1);
                    if(!separate) {
                        if(_nightPosMode==0u) {
                            if(_nightInternalVagCount<10000u)++_nightInternalVagCount;
                        } else {
                            if(_nightInternalAnalCount<10000u)++_nightInternalAnalCount;
                        }
                        _nightHadInternalClimax=YES;
                    } else {
                        if(_nightExternalClimaxCount<10000u)++_nightExternalClimaxCount;
                    }
                    if(_naturalGameplayRoute&&!touchExercise) {
                        if(!separate) {
                            if(_nightPosMode==0u) {
                                if(_stageOutcomeA==0u)_stageOutcomeA=1u;
                            } else {
                                if(_stageOutcomeB==0u)_stageOutcomeB=1u;
                            }
                        }
                        _motionState.outcome_a=_stageOutcomeA;
                        _motionState.outcome_b=_stageOutcomeB;
                    } else {
                        if(separate) {
                            if(_motionState.outcome_a>0)--_motionState.outcome_a;
                            if(_motionState.outcome_b<10000)++_motionState.outcome_b;
                        } else {
                            if(_motionState.outcome_a==0)_motionState.outcome_a=1;
                        }
                        _stageOutcomeA=(uint32_t)_motionState.outcome_a;
                        _stageOutcomeB=(uint32_t)_motionState.outcome_b;
                    }
                    uint32_t targetClip=separate?30u:27u;
                    _motionState.clip=targetClip;_motionState.phase=2;_motionState.pointer_mode=0;
                    _nightExcitement=0.f;_nightDragging=NO;_actorPlaybackSpeed=1.0f;
                    _pendingEffectSlot=separate?2u:15u;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:!separate];
                    ++_interactionCount;_interactionCompleted=YES;
                    _player.interaction_count=_interactionCount;_playerSaveDirty=YES;
                    dc_scene_motion_event ev={
                        .request_clip=targetClip,
                        .request_chain_from=separate?32u:29u,
                        .request_chain_to=separate?55u:39u
                    };
                    return [self applyMotionEvent:ev tick:_lastTick];
                }
                if(resourceId==11||resourceId==12||((_motionState.clip>=27&&_motionState.clip<=54)&&selection<2)) {
                    ++_characterActionCount;
                    BOOL finishPos2=(resourceId==12||selection==1);
                    if(!_naturalGameplayRoute||touchExercise) {
                        if(finishPos2) {
                            if(_motionState.outcome_b==0)_motionState.outcome_b=1;
                        } else {
                            if(_motionState.outcome_a<10000)++_motionState.outcome_a;
                        }
                        _stageOutcomeA=(uint32_t)_motionState.outcome_a;
                        _stageOutcomeB=(uint32_t)_motionState.outcome_b;
                    }
                    uint32_t targetClip=finishPos2?54u:53u;
                    _motionState.clip=targetClip;_motionState.phase=finishPos2?3u:1u;_motionState.pointer_mode=0;
                    _nightExcitement=0.f;_nightDragging=NO;_actorPlaybackSpeed=1.0f;
                    _pendingEffectSlot=2;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:NO];
                    if(finishPos2) {
                        ++_interactionCount;_interactionCompleted=YES;
                        _player.interaction_count=_interactionCount;_playerSaveDirty=YES;
                    }
                    dc_scene_motion_event ev={.request_clip=targetClip,
                        .request_chain_from=finishPos2?54u:53u,
                        .request_chain_to=finishPos2?55u:10u};
                    return [self applyMotionEvent:ev tick:_lastTick];
                }
                if(_motionState.clip>=55&&(resourceId==1||resourceId==2)) {
                    ++_characterActionCount;
                    _nightPosMode=(resourceId==1)?0u:1u;
                    _nightQuestionAsked=NO;
                    if(resourceId==2&&_pos2SelectedCount<10000)++_pos2SelectedCount;
                    if(_naturalGameplayRoute&&!touchExercise) {
                        if(_nightPosMode==0u){if(_stageOutcomeA==0u)_stageOutcomeA=1u;}
                        else {if(_stageOutcomeB==0u)_stageOutcomeB=1u;}
                        _motionState.outcome_a=_stageOutcomeA;
                        _motionState.outcome_b=_stageOutcomeB;
                    } else {
                        if(resourceId==1){if(_motionState.outcome_a<10000)++_motionState.outcome_a;}
                        else {if(_motionState.outcome_b<10000)++_motionState.outcome_b;}
                        _stageOutcomeA=(uint32_t)_motionState.outcome_a;
                        _stageOutcomeB=(uint32_t)_motionState.outcome_b;
                    }
                    uint32_t chainTarget=(resourceId==1)?2u:6u;
                    _motionState.clip=58u;_motionState.phase=1;_motionState.pointer_mode=0;
                    _nightExcitement=0.f;_nightDragging=NO;_actorPlaybackSpeed=1.0f;
                    _pendingEffectSlot=2;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:NO];
                    dc_scene_motion_event ev={.request_clip=58u,.request_chain_from=58u,.request_chain_to=chainTarget};
                    return [self applyMotionEvent:ev tick:_lastTick];
                }
            }
            if(_sceneType==5&&_naturalGameplayRoute&&!touchExercise&&(resourceId>=1&&resourceId<=5)) {
                ++_characterActionCount;
                _watchPart=-1;_watchDragging=NO;_watchScrubState=0;
                for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                    dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
                dc_animation_state anim={0};
                uint32_t curClip=(_actor.model&&dc_model_get_animation(_actor.model,&anim)==DC_OK)?anim.current:_motionState.clip;
                uint32_t stanceIdx=(curClip==15u)?0u:((curClip==21u)?1u:((curClip==27u)?2u:3u));
                uint32_t targetClip=200u+((uint32_t)(resourceId-1)*4u)+stanceIdx;
                if(resourceId==1||resourceId==2) {
                    if(resourceId==1){_watchNekoVibeVisible=YES;_vibeNekoUsed=YES;if(_storyStage!=1&&_stageProgress<=1)_tearVisible=YES;}
                    else {_watchToriVibeVisible=YES;_vibeToriUsed=YES;if(_storyStage!=0||_stageProgress<=1)_tearVisible=YES;}
                    if(_storyStage==2) {
                        if(_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u)
                            _clothingTopState+=2u;
                    } else {
                        if(_clothingSkirtState==0u||_clothingSkirtState==2u)
                            ++_clothingSkirtState;
                    }
                    if(_clothingPantyState==0u)_clothingPantyState=1u;
                    [self syncLegacyClothingSummary];
                    [self applyClothingVisibility];
                    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                    _pendingEffectSlot=2;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:5 climax:NO];
                } else if(resourceId==3) {
                    _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
                    if(_clothingPantyState==1u)_clothingPantyState=0u;
                    [self syncLegacyClothingSummary];
                    [self applyClothingVisibility];
                    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                    _pendingEffectSlot=2;_hasPendingEffect=YES;
                } else {
                    _watchVibeSwitch=(resourceId==4);
                    _pendingEffectSlot=3;_hasPendingEffect=YES;
                    if(_watchVibeSwitch)[self queueCyclicReactionVoiceForScene:5 climax:NO];
                }
                _actorPlaybackSpeed=_watchVibeSwitch?1.65f:((_watchNekoVibeVisible||_watchToriVibeVisible)?1.25f:1.0f);
                _motionState.clip=targetClip;_motionState.phase=1;
                if(dc_model_request(_actor.model,targetClip,_lastTick)!=DC_OK)return @"Original watch vibrator animation request failed";
                ++_characterAnimationStarts;
                return nil;
            }
            if(_sceneType==5&&resourceId==4) {
                ++_characterActionCount;
                _watchPart=5;_watchDragging=NO;_actorPlaybackSpeed=1.0f;
                for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                    dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,auxiliary==0?0:1);
                _motionState.clip=7u;_motionState.phase=2;
                if(dc_model_request(_actor.model,7u,_lastTick)!=DC_OK)return @"Original watch menu animation request failed";
                ++_characterAnimationStarts;
                _pendingEffectSlot=3;_hasPendingEffect=YES;
                [self queueCyclicReactionVoiceForScene:5 climax:NO];
                return nil;
            }
            dc_scene_motion_event motionEvent;
            dc_status motionStatus=dc_scene_motion_context(&_motionState,selection,&motionEvent);
            if(motionStatus==DC_OK) {
                ++_characterActionCount;
                if(_sceneType==5) {
                    _watchPart=(selection==0)?2:((selection==1)?3:0);
                    _watchDragging=NO;
                    unsigned activeAux=(_watchPart==1||_watchPart==5)?0u:1u;
                    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                        dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,auxiliary==activeAux?0:1);
                    _pendingEffectSlot=3;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:5 climax:NO];
                } else if(_sceneType==6) {
                    _nightPosMode=(selection==1)?1u:0u;
                    if(!motionEvent.transition_action)_nightQuestionAsked=NO;
                    if(selection==1&&_pos2SelectedCount<10000)++_pos2SelectedCount;
                    if(_naturalGameplayRoute&&!touchExercise&&!motionEvent.transition_action) {
                        if(_nightPosMode==0u){if(_stageOutcomeA==0u)_stageOutcomeA=1u;}
                        else {if(_stageOutcomeB==0u)_stageOutcomeB=1u;}
                        _motionState.outcome_a=_stageOutcomeA;
                        _motionState.outcome_b=_stageOutcomeB;
                    } else {
                        _stageOutcomeA=_motionState.outcome_a;
                        _stageOutcomeB=_motionState.outcome_b;
                    }
                    _nightExcitement=0.f;_nightDragging=NO;
                    if(!motionEvent.transition_action) {
                        _pendingEffectSlot=2;_hasPendingEffect=YES;
                        [self queueCyclicReactionVoiceForScene:6 climax:NO];
                    }
                }
                return [self applyMotionEvent:motionEvent tick:_lastTick];
            }
            if(motionStatus!=DC_NOT_FOUND&&!(_sceneType==6&&selection==2))return @"Original scene motion context action rejected";
        }
        uint32_t effectiveSelection=(_sceneType==4&&resourceId==2)?1u:selection;
        dc_scene_character_event event;
        dc_status result=dc_scene_character_select(&_characterAction,_sceneType,0,effectiveSelection,&event);
        if(result==DC_NOT_FOUND){++_pendingContextActions;return nil;}
        if(result!=DC_OK)return @"Original character menu action rejected";
        if(effectiveSelection==1||(_sceneType==6&&effectiveSelection==2))_exitSoundStartTick=_lastTick;
        if(_sceneType==4&&effectiveSelection==0) {
            _scene4ObservedOnce=YES;
            if(_interactionCount==0&&!_pendingVoiceName)[self queueCharacterVoice:@"st001_01.wav"];
            else [self queueCyclicReactionVoiceForScene:4 climax:NO];
        }
        ++_characterActionCount;
        return [self applyCharacterEvent:event tick:_lastTick];
    }
    if(_contextMenu.icon==4&&_editMode&&!touchExercise) {
        if(selection==0) {
            _watchDragging=NO;_nightDragging=NO;_pendingSystemAction=3;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:_lastTick]!=DC_OK)return @"System transition request failed";
            _pendingEffectSlot=0u;_hasPendingEffect=YES;
            return nil;
        }
        if(selection==1) {
            [self toggleEditPauseOrResetSpeed];
            _pendingEffectSlot=1u;_hasPendingEffect=YES;
            return nil;
        }
        if(selection==2) {
            [self cycleEditSpeedMode];
            _pendingEffectSlot=1u;_hasPendingEffect=YES;
            return nil;
        }
        if(selection==3) {
            _watchDragging=NO;_nightDragging=NO;_pendingSystemAction=6;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:_lastTick]!=DC_OK)return @"System transition request failed";
            _pendingEffectSlot=1u;_hasPendingEffect=YES;
            return nil;
        }
    }
    dc_scene_action_plan plan;
    uint32_t actionSceneType=(_contextMenu.icon>=3&&((_sceneType>=4&&_sceneType<=6)||_sceneType==12))?4:_sceneType;
    dc_status status=dc_scene_action_build(actionSceneType,_contextMenu.icon,selection,_primaryCameraMode,_secondaryCameraMode,&plan);
    if(status==DC_NOT_FOUND){++_pendingContextActions;return nil;}
    if(status!=DC_OK)return @"Scene context action rejected";
    if(_contextMenu.icon==3&&selection<2) {
        dc_matrix target;
        if([self cameraBinding:selection matrix:&target]!=DC_OK)return @"Original primary camera target unavailable";
        dc_camera_orbit current=[self activeCameraOrbit],next;
        if(dc_camera_retarget(&current,&target,1,&next)!=DC_OK)return @"Primary camera retarget failed";
        _lastCameraTarget=target;_lastCameraTargetBinding=selection;
        [self adoptCameraOrbit:next];_primaryCameraMode=plan.camera_mode;++_cameraRetargetCount;++_cameraActionCount;
        if(selection==1)++_cameraBodyRetargetCount;
#if DEBUG
        if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
            [self requestRenderCapture:selection==0?@"gameplay-camera-retarget-native.png":@"gameplay-camera-body-native.png"];
#endif
    } else if(_contextMenu.icon==3&&(selection==2||selection==6)) {
        dc_camera_orbit preset;
        if(dc_camera_read_preset(_cameraPresetData.bytes,_cameraPresetData.length,_cameraPreset*3,&preset)!=DC_OK)return @"Original camera reset preset unavailable";
        [self adoptCameraOrbit:preset];
        if(selection==6){_secondaryCamera=preset;_secondaryCameraMode=plan.secondary_camera_mode;++_secondaryResets;++_secondaryActions;}
        uint32_t previousMode=_primaryCameraMode;_primaryCameraMode=plan.camera_mode;
        if(selection==2) {
            if(plan.camera_mode==2)++_cameraAutoEnterCount;
            else if(previousMode==2)++_cameraAutoLeaveCount;
        }
        ++_cameraResetCount;++_cameraActionCount;
#if DEBUG
        if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"]&&
           (selection==6||(plan.camera_mode==2?_cameraAutoEnterCount==1:_cameraAutoLeaveCount==1)))
            [self requestRenderCapture:selection==6?@"gameplay-camera-reset-native.png":
                (plan.camera_mode==2?@"gameplay-camera-auto-first-native.png":@"gameplay-camera-auto-off-native.png")];
#endif
    } else if(_contextMenu.icon==3&&selection>=3&&selection<=5) {
        uint32_t previousSecondaryMode=_secondaryCameraMode;
        if(selection<5) {
            dc_matrix target;dc_camera_orbit next;
            if([self cameraBinding:selection-3 matrix:&target]!=DC_OK)return @"Original secondary camera target unavailable";
            if(dc_camera_retarget(&_secondaryCamera,&target,0,&next)!=DC_OK)return @"Original secondary camera retarget failed";
            _secondaryCamera=next;_secondaryTarget=target;_secondaryTargetBinding=selection-3;++_secondaryRetargets;
        } else {
            if(dc_camera_read_preset(_cameraPresetData.bytes,_cameraPresetData.length,_cameraPreset*3,&_secondaryCamera)!=DC_OK)
                return @"Original secondary camera preset unavailable";
            ++_secondaryResets;
        }
        _secondaryCameraMode=plan.secondary_camera_mode;++_secondaryActions;
        if(selection==5) {
            if(_secondaryCameraMode==2)++_secondaryAutoEnters;
            else if(previousSecondaryMode==2)++_secondaryAutoLeaves;
        }
#if DEBUG
        if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"]&&
           (selection<5||(_secondaryCameraMode==2?_secondaryAutoEnters==1:_secondaryAutoLeaves==1)))
            [self requestRenderCapture:selection==3?@"gameplay-secondary-face-native.png":selection==4?@"gameplay-secondary-body-native.png":
                (_secondaryCameraMode==2?@"gameplay-secondary-auto-first-native.png":@"gameplay-secondary-auto-off-native.png")];
        if(selection==5&&_secondaryCameraMode==2&&_primaryCameraMode==2&&[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
            [self requestRenderCapture:@"gameplay-cameras-both-auto-native.png"];
#endif
    } else if(_contextMenu.icon==4) {
        for(unsigned i=0;i<plan.count;++i){
            if(plan.commands[i].kind==DC_SCENE_ENTER_CONFIG_MENU)_pendingSystemAction=3;
            else if(plan.commands[i].kind==DC_SCENE_ENTER_SAVE_MENU)_pendingSystemAction=4;
        }
        if(_pendingSystemAction){
            _watchDragging=NO;_nightDragging=NO;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:_lastTick]!=DC_OK)return @"Original system-page transition failed";
            _pendingEffectSlot=0;_hasPendingEffect=YES;
        }
    } else {
        ++_pendingContextActions;
    }
    return nil;
}
- (dc_status)cameraBinding:(uint32_t)binding matrix:(dc_matrix *)out {
    if(_sceneType==7||_sceneType==12) {
        uint8_t fallbackHeroine=(_sceneType==12)?(uint8_t)_storyStage:_type7State.primary_heroine;
        uint8_t rawTarget=(_sceneType==12)?_editCamTargetHeroine:_type7State.cam_target_heroine;
        uint8_t targetHeroine=rawTarget<3u?rawTarget:fallbackHeroine;
        char name[32];dc_status status=dc_camera_scene_node(targetHeroine,binding,name,sizeof(name));
        if(status!=DC_OK)return status;
        if(binding==DC_CAMERA_ANIMATION_EYE) {
            if(!_autoCamera.model)return DC_NOT_FOUND;
            uint32_t node=[self findNode:&_autoCamera name:[NSString stringWithUTF8String:name]];
            return node==UINT32_MAX?DC_NOT_FOUND:dc_model_global(_autoCamera.model,node,out);
        }
        uint32_t headCount=(_sceneType==12)?_editAssets.head_count:_type7Assets.head_count;
        uint32_t hIdx=0u;
        for(uint32_t i=0;i<headCount;++i) {
            if(_headHeroines[i]==targetHeroine){hIdx=i;break;}
        }
        dc_game_model *slot=(binding==DC_CAMERA_FACE_TARGET)?[self faceSlotAtIndex:hIdx]:[self bodySlotAtIndex:_headBodyIndices[hIdx]];
        if(!slot||!slot->model)slot=&_actor;
        if(!slot->model)return DC_NOT_FOUND;
        uint32_t node=[self findNode:slot name:[NSString stringWithUTF8String:name]];
        return node==UINT32_MAX?DC_NOT_FOUND:dc_model_global(slot->model,node,out);
    }
    char name[32];dc_status status=dc_camera_scene_node(_storyStage,binding,name,sizeof(name));
    if(status!=DC_OK)return status;
    dc_game_model *slot=binding==DC_CAMERA_FACE_TARGET?&_face:
        (binding==DC_CAMERA_ANIMATION_EYE?&_autoCamera:&_actor);
    if(!slot->model)return DC_NOT_FOUND;
    uint32_t node=[self findNode:slot name:[NSString stringWithUTF8String:name]];
    return node==UINT32_MAX?DC_NOT_FOUND:dc_model_global(slot->model,node,out);
}
- (NSString *)nodeNameForPrefix:(char)pfx template:(NSString *)name {
    if([name hasPrefix:@"a_"])return [NSString stringWithFormat:@"%c%@",pfx,[name substringFromIndex:1]];
    if([name hasPrefix:@"AA_"]){char upper=(char)toupper((unsigned char)pfx);return [NSString stringWithFormat:@"%c%c%@",upper,upper,[name substringFromIndex:2]];}
    return name;
}
- (void)rebuildType7ContextMenuForHub:(uint8_t)hub atX:(float)px y:(float)py right:(BOOL)right {
    memset(&_type7Menu,0,sizeof(_type7Menu));
    dc_type7_build_menu(&_type7State,hub,&_type7Menu);
    _type7HubOriginX=px;_type7HubOriginY=py;
    _contextMenu=(dc_scene_context){.icon=hub,.opening_right=right?1u:0u,.hover=-1,.count=MIN(_type7Menu.count,7u)};
    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
    float unit=105.f*.3333333432674408f;
    const float dx[7]={0,unit,unit+unit,105,unit+unit,unit,0};
    const float dy[7]={-105,-(unit+unit),-unit,0,unit,unit+unit,105};
    for(unsigned i=0;i<_contextMenu.count;++i) {
        uint32_t a=_type7Menu.items[i].radial_pos%7u;
        _contextMenu.items[i]=(dc_scene_context_item){(int32_t)i,a,px-dx[a],py+dy[a]};
    }
}
- (void)applyType7ClothingAndVibeVisibility {
    if(_sceneType!=7)return;
    /* Hide alternate male erection meshes on all active bodies; leave *_siru_* and *_tare_*
     * unhidden so their baseline alpha=0.0 is animated directly by .xa material tracks. */
    NSArray<NSString *> *maleAltHidden=@[@"s_Kn_asokoX",@"s_On_omozaX1",@"s_On_omozaX2",@"s_On_omozaX3",
        @"s_On_omozaX4",@"s_On_omozaX5",@"s_On_omozaX6",@"b_On_houtyou",
        @"b_On_himoUL",@"b_On_himoUR",@"b_On_himoAL",@"b_On_himoAR",
        @"a_On_tejou_L",@"a_On_tejou_R",@"c_On_tejou_L",@"c_On_tejou_R"];
    uint32_t totalBodies=1u+_extraActorCount;
    for(uint32_t b=0;b<totalBodies;++b) {
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(!bs||!bs->model)continue;
        for(NSString *mn in maleAltHidden) {
            uint32_t n=[self findNode:bs name:mn];
            if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1);
        }
    }
    BOOL isSexSub=(_type7State.sub_mode==DC_TYPE7_SUB_2P_SEX||_type7State.sub_mode==DC_TYPE7_SUB_3P_SEX||
                   _type7State.sub_mode==DC_TYPE7_SUB_4P_SEX||_type7State.sub_mode==DC_TYPE7_SUB_5P);
    for(uint32_t hIdx=0;hIdx<_type7Assets.head_count;++hIdx) {
        uint8_t h=_headHeroines[hIdx];
        if(h>=3u)continue;
        char pfx=dc_type7_heroine_prefix(h);
        dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[hIdx]];
        dc_game_model *fs=[self faceSlotAtIndex:hIdx];
        int slotIdx=-1;
        for(uint8_t s=0;s<_type7State.heroine_count;++s)if(_type7State.slots[s]==h){slotIdx=(int)s;break;}
        BOOL vibeOn=(slotIdx>=0&&((_type7State.vibe_mask&(1u<<(uint32_t)slotIdx))!=0));
        BOOL heroineInserted=isSexSub&&(_type7State.phase!=DC_TYPE7_PHASE_IDLE)&&
            (_type7State.heroine_count==1u||(_type7State.active_slot>=0&&(uint8_t)_type7State.slots[_type7State.active_slot]==h));
        const uint8_t *fk=_type7State.fuku_state[h];
        if(bs&&bs->model) {
            /* Vibrators */
            uint32_t nv=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_neko_vive"]];
            if(nv!=UINT32_MAX)dc_model_hide_node(bs->model,nv,vibeOn?0u:1u);
            uint32_t tv=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_tori_vive"]];
            if(tv!=UINT32_MAX)dc_model_hide_node(bs->model,tv,1u);
            /* Arousal / ejaculation wetness overlays */
            const dc_type7_heroine_metrics *m=&_type7State.metrics[h];
            BOOL wet=(_type7State.arousal[h]>0.01f||m->heroine_climaxes>0u||vibeOn||heroineInserted);
            BOOL kokanWet=(m->vaginal_in_ejac>0u||m->anal_in_ejac>0u||m->out_ejac>0u);
            uint32_t mata=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_mata_siru"]];
            if(mata!=UINT32_MAX)dc_model_hide_node(bs->model,mata,wet?0u:1u);
            uint32_t kokan=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_kokan_siru"]];
            if(kokan!=UINT32_MAX)dc_model_hide_node(bs->model,kokan,kokanWet?0u:1u);
            /* Top & Skirt (present in 2P & 5P bodies) */
            if(h==2u) {
                static NSString *const kAoiHide[]={@"a_On_wanpi",@"a_On_wanpi_U",@"a_On_wanpiHEC",@"a_On_wanpiHEC_U",
                    @"a_On_wanpiEHM",@"a_On_wanpiEHM_U",@"a_On_wanpiHHM",@"a_On_wanpiHHM_U",
                    @"a_On_wanpiEHU",@"a_On_wanpiEHU_U",@"a_On_wanpiHHU",@"a_On_wanpiHHU_U",
                    @"a_On_skartHA",@"a_On_skartHA_U",@"a_On_skartHF",@"a_On_skartHF_U",@"a_On_skartHB",@"a_On_skartHB_U"};
                for(size_t k=0;k<sizeof(kAoiHide)/sizeof(kAoiHide[0]);++k) {
                    uint32_t n=[self findNode:bs name:kAoiHide[k]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
                }
                BOOL off=(fk[0]>=2u||fk[2]>=2u);
                BOOL disp=(!off&&(fk[0]==1u||fk[2]==1u));
                for(NSString *nm in @[@"a_On_wanpiEHC",@"a_On_wanpiEHC_U",@"a_On_ribon",@"a_On_belt"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(!off&&!disp)?0u:1u);
                }
                for(NSString *nm in @[@"a_On_wanpiHHC",@"a_On_wanpiHHC_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,disp?0u:1u);
                }
            } else if(h==0u) {
                for(NSString *nm in @[@"b_Nn_sera_OBJ",@"b_On_sera_O",@"b_On_sera_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[0]==0u)?0u:1u);
                }
                for(NSString *nm in @[@"b_Nn_seraH_OBJ",@"b_On_seraH_O",@"b_On_seraH_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[0]==1u)?0u:1u);
                }
                for(NSString *nm in @[@"b_On_eriH_O",@"b_On_eriH_U",@"b_On_shatuH",@"b_On_shatuH_U",@"b_On_nekuH_R"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
                }
            } else if(h==1u) {
                for(NSString *nm in @[@"c_On_uwagi",@"c_On_uwagi_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[0]==0u)?0u:1u);
                }
                for(NSString *nm in @[@"c_On_uwagiH",@"c_On_uwagiH_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[0]==1u)?0u:1u);
                }
            }
            if(h!=2u) {
                /* Bra */
                for(NSString *nm in @[@"a_On_bura",@"a_On_bura_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[1]==0u)?0u:1u);
                }
                for(NSString *nm in @[@"a_On_buraH",@"a_On_buraH_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[1]==1u)?0u:1u);
                }
                /* Skirt */
                for(NSString *nm in @[@"a_On_skart",@"a_On_skart_U",@"a_On_skartHF",@"a_On_skartHF_U",@"a_On_skartHB",@"a_On_skartHB_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
                }
                for(NSString *nm in @[@"a_On_skartHA",@"a_On_skartHA_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(fk[2]<2u)?0u:1u);
                }
            }
            /* Panties */
            uint8_t pState=fk[3];
            if(pState==0u&&(heroineInserted||vibeOn))pState=1u;
            for(NSString *nm in @[@"a_On_pantu",@"a_On_pantu_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(pState==0u)?0u:1u);
            }
            for(NSString *nm in @[@"a_On_pantuH",@"a_On_pantuH1",@"a_On_pantuH1_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(pState==1u)?0u:1u);
            }
            for(NSString *nm in @[@"a_On_pantuH2",@"a_On_pantuH2_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(pState==2u)?0u:1u);
            }
            for(NSString *nm in @[@"a_On_pantuH3",@"a_On_pantuH3_U",@"a_On_pantuH4",@"a_On_pantuH4_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
            }
            /* Shoes & shins */
            uint32_t kutuL=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_kutu_L"]];
            uint32_t kutuR=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_kutu_R"]];
            BOOL hasShoes=(kutuL!=UINT32_MAX||kutuR!=UINT32_MAX);
            BOOL shoesOff=(!hasShoes||fk[4]>=1u);
            if(kutuL!=UINT32_MAX)dc_model_hide_node(bs->model,kutuL,shoesOff?1u:0u);
            if(kutuR!=UINT32_MAX)dc_model_hide_node(bs->model,kutuR,shoesOff?1u:0u);
            for(NSString *nm in @[@"a_On_sune_L",@"a_On_sune_R"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,shoesOff?0u:1u);
            }
        }
        if(fs&&fs->model) {
            /* Oral semen overlays on face: show during mouth-hold / oral climax if present */
            BOOL showKuchi=((_type7State.sub_mode==DC_TYPE7_SUB_2P_ORAL||_type7State.sub_mode==DC_TYPE7_SUB_3P_ORAL||
                             _type7State.sub_mode==DC_TYPE7_SUB_4P_ORAL)&&
                            (_type7State.phase==DC_TYPE7_PHASE_MOUTH_HOLD||_type7State.metrics[h].oral_out_ejac>0u));
            for(NSString *nm in @[@"a_On_kuchsiru_F",@"a_On_kuchsiru_ita",@"a_On_kuchsiru_o",@"a_On_kuchsiru_u"]) {
                uint32_t n=[self findNode:fs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,showKuchi?0u:1u);
            }
            uint32_t tear=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_namida"]];
            if(tear!=UINT32_MAX)dc_model_hide_node(fs->model,tear,((_type7State.conquered_mask&(1u<<h))==0u&&h==2u)?0u:1u);
            /* 6th Accessory slot (fk[5]): Aoi ponytail/long hair, Yuko glasses, Manaka cat-ears */
            if(h==0u) {
                uint32_t longHair=[self findNode:fs name:@"b_On_long"];
                if(longHair!=UINT32_MAX)dc_model_hide_node(fs->model,longHair,(fk[5]!=0u)?0u:1u);
                for(NSString *nm in @[@"b_On_pony",@"b_On_zura"]) {
                    uint32_t n=[self findNode:fs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,(fk[5]==0u)?0u:1u);
                }
                uint32_t tome=[self findNode:fs name:@"b_On_tome"];
                if(tome!=UINT32_MAX)dc_model_hide_node(fs->model,tome,(fk[5]==0u||fk[5]==2u)?0u:1u);
                uint32_t mimiB=[self findNode:fs name:@"b_On_nekomimi"];
                if(mimiB!=UINT32_MAX)dc_model_hide_node(fs->model,mimiB,(fk[5]==2u)?0u:1u);
            } else if(h==1u) {
                for(NSString *nm in @[@"c_Nn_megane_ani",@"c_On_megane"]) {
                    uint32_t n=[self findNode:fs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,(fk[5]==0u)?0u:1u);
                    if(bs&&bs->model) {
                        uint32_t bn=[self findNode:bs name:nm];
                        if(bn!=UINT32_MAX)dc_model_hide_node(bs->model,bn,(fk[5]==0u)?0u:1u);
                    }
                }
                uint32_t mimiC=[self findNode:fs name:@"c_On_nekomimi"];
                if(mimiC!=UINT32_MAX)dc_model_hide_node(fs->model,mimiC,(fk[5]==2u)?0u:1u);
            } else if(h==2u) {
                uint32_t mimi=[self findNode:fs name:@"a_On_nekomimi"];
                if(mimi!=UINT32_MAX)dc_model_hide_node(fs->model,mimi,(fk[5]!=0u)?0u:1u);
                for(NSString *nm in @[@"a_Nn_megane_ani",@"a_On_megane"]) {
                    uint32_t n=[self findNode:fs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,(fk[5]==2u)?0u:1u);
                }
            }
        }
    }
}
- (NSString *)applyType7Plan:(const dc_type7_plan *)plan tick:(uint32_t)tick {
    if(!plan)return nil;
    _actorPlaybackSpeed=_type7State.speed>0.f?_type7State.speed:1.0f;
    if(plan->start_fade) {
        _nightDragging=NO;
        if(plan->fade_kind==DC_TYPE7_FADE_CONFIG) {
            _pendingSystemAction=3u;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:tick]!=DC_OK)
                return @"Type 7 config fade transition failed";
            _pendingEffectSlot=0u;_hasPendingEffect=YES;
        } else if(plan->fade_kind==DC_TYPE7_FADE_SAVE) {
            _pendingSystemAction=4u;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:tick]!=DC_OK)
                return @"Type 7 save fade transition failed";
            _pendingEffectSlot=0u;_hasPendingEffect=YES;
        } else if(plan->fade_kind==DC_TYPE7_FADE_EXIT) {
            _characterAction.exit_pending=1;_exitSoundStartTick=tick;
            _pendingEffectSlot=28u;_hasPendingEffect=YES;
        } else if(plan->fade_kind==DC_TYPE7_FADE_SWAP) {
            _type7SwapPending=YES;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:tick]!=DC_OK)
                return @"Type 7 posture/sub-mode swap fade failed";
            _pendingEffectSlot=2u;_hasPendingEffect=YES;
        }
        return nil;
    }
    for(uint8_t b=0;b<plan->body_count&&b<DC_TYPE7_MAX_BODIES;++b) {
        if(plan->body_clip[b]<0)continue;
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(bs&&bs->model) {
            uint32_t c=(uint32_t)plan->body_clip[b];
            int32_t nc=plan->body_next_clip[b];
            if(nc>=0) {
                dc_model_set_loop(bs->model,c,0);
                dc_model_set_chain(bs->model,c,nc);
            } else {
                dc_model_set_chain(bs->model,c,-1);
            }
        }
    }
    for(uint8_t k=0;k<plan->chain_count&&k<DC_TYPE7_MAX_CHAINS;++k) {
        dc_game_model *bs=[self bodySlotAtIndex:plan->chain_body[k]];
        if(bs&&bs->model)dc_model_set_chain(bs->model,plan->chain_from[k],plan->chain_to[k]);
    }
    for(uint8_t k=0;k<plan->loop_count&&k<DC_TYPE7_MAX_LOOPS;++k) {
        dc_game_model *bs=[self bodySlotAtIndex:plan->loop_body[k]];
        if(bs&&bs->model)dc_model_set_loop(bs->model,plan->loop_clip[k],plan->loop_limit[k]);
    }
    for(uint8_t b=0;b<plan->body_count&&b<DC_TYPE7_MAX_BODIES;++b) {
        if(plan->body_clip[b]<0)continue;
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(bs&&bs->model) {
            uint32_t c=(uint32_t)plan->body_clip[b];
            dc_animation_state curState={0};
            if(dc_model_get_animation(bs->model,&curState)==DC_OK&&curState.current==c)
                dc_model_request(bs->model,(c==1u)?0u:1u,tick);
            dc_model_request(bs->model,c,tick);
            ++_characterAnimationStarts;
        }
    }
    [self applyType7ClothingAndVibeVisibility];
    if(plan->reset_cam_preset&&_cameraPresetData.length>0) {
        dc_camera_orbit preset;
        if(dc_camera_read_preset(_cameraPresetData.bytes,_cameraPresetData.length,_cameraPreset*3,&preset)==DC_OK) {
            [self adoptCameraOrbit:preset];
            _secondaryCamera=preset;
            _primaryCameraMode=0u;_secondaryCameraMode=0u;
            ++_cameraResetCount;++_cameraActionCount;
        }
    }
    if(plan->update_cam_pivot) {
        if(_type7State.cam_pivot_mode==2u) {
            if(_primaryCameraMode!=2u)++_cameraAutoEnterCount;
            _primaryCameraMode=2u;++_cameraActionCount;
        } else {
            if(_primaryCameraMode==2u&&_cameraPresetData.length>0) {
                dc_camera_orbit preset;
                if(dc_camera_read_preset(_cameraPresetData.bytes,_cameraPresetData.length,_cameraPreset*3,&preset)==DC_OK)
                    [self adoptCameraOrbit:preset];
                ++_cameraAutoLeaveCount;
            }
            dc_matrix target;
            uint32_t binding=_type7State.cam_pivot_mode;
            if([self cameraBinding:binding matrix:&target]==DC_OK) {
                dc_camera_orbit current=[self activeCameraOrbit],next;
                if(dc_camera_retarget(&current,&target,1,&next)==DC_OK) {
                    _lastCameraTarget=target;_lastCameraTargetBinding=binding;
                    [self adoptCameraOrbit:next];
                    _primaryCameraMode=binding;++_cameraRetargetCount;++_cameraActionCount;
                }
            }
        }
    }
    if(plan->voice_stem[0]!='\0') {
        _pendingVoiceName=[NSString stringWithUTF8String:plan->voice_stem];
        _voiceBlushActive=YES;
    }
    if(plan->se_name[0]!='\0') {
        _pendingEffectName=[NSString stringWithUTF8String:plan->se_name];
    }
    _lastDynamicTexMask=UINT32_MAX;
    return nil;
}
- (void)applyEditBellyModifiersForBody:(dc_game_model *)bs prefix:(char)pfx level:(uint8_t)bellyLevel {
    if(!bs||!bs->model||!bs->xx||bellyLevel==0u)return;
    float t=(bellyLevel>=2u)?1.0f:0.45f;
    NSString *boneNames[2]={@"a_Kp_onaka0",@"a_Kn_skart_A_1"};
    NSString *restNames[2]={@"a_Nz_onaka0",@"a_Nz_skart0"};
    NSString *fullNames[2]={@"a_Nz_onakaD",@"a_Nz_skartD"};
    for(unsigned k=0;k<2;++k) {
        uint32_t bone=[self findNode:bs name:[self nodeNameForPrefix:pfx template:boneNames[k]]];
        uint32_t ref0=[self findNode:bs name:[self nodeNameForPrefix:pfx template:restNames[k]]];
        uint32_t refD=[self findNode:bs name:[self nodeNameForPrefix:pfx template:fullNames[k]]];
        if(ref0==UINT32_MAX)ref0=bone;
        if(bone==UINT32_MAX||ref0==UINT32_MAX||refD==UINT32_MAX)continue;
        dc_matrix m0,mD,inv0,fullDelta;
        if(dc_xx_node_matrix(bs->xx,ref0,&m0)!=DC_OK||
           dc_xx_node_matrix(bs->xx,refD,&mD)!=DC_OK||
           dc_matrix_inverse_affine(&m0,&inv0)!=DC_OK||
           dc_matrix_multiply(&mD,&inv0,&fullDelta)!=DC_OK)continue;
        dc_matrix ident=gameIdentity(),deltaM=fullDelta;
        if(t<0.999f) {
            for(unsigned i=0;i<16;++i)deltaM.values[i]=ident.values[i]+(fullDelta.values[i]-ident.values[i])*t;
            deltaM.values[3]=deltaM.values[7]=deltaM.values[11]=0.f;
            deltaM.values[15]=1.f;
        }
        dc_model_set_node_extra(bs->model,bone,2,&deltaM);
    }
}
- (void)applyEditClothingAndVibeVisibility {
    if(_sceneType!=12)return;
    NSArray<NSString *> *maleAltHidden=@[@"s_Kn_asokoX",@"s_On_omozaX1",@"s_On_omozaX2",@"s_On_omozaX3",
        @"s_On_omozaX4",@"s_On_omozaX5",@"s_On_omozaX6",@"b_On_houtyou",
        @"b_On_himoUL",@"b_On_himoUR",@"b_On_himoAL",@"b_On_himoAR",
        @"a_On_tejou_L",@"a_On_tejou_R",@"c_On_tejou_L",@"c_On_tejou_R"];
    uint32_t totalBodies=1u+_extraActorCount;
    for(uint32_t b=0;b<totalBodies;++b) {
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(!bs||!bs->model)continue;
        for(NSString *mn in maleAltHidden) {
            uint32_t n=[self findNode:bs name:mn];
            if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1);
        }
    }
    int32_t curMid=(_editPlayer.cur_step>=0&&_editPlayer.cur_step<_editStateCopy.step_count)?_editStateCopy.steps[_editPlayer.cur_step].motion_id:6;
    BOOL isPenetratedMotion=(curMid==7||curMid==8||(curMid>=12&&curMid<=62));
    for(uint32_t hIdx=0;hIdx<_editAssets.head_count&&hIdx<3u;++hIdx) {
        uint8_t h=_headHeroines[hIdx];
        if(h>=3u)continue;
        char pfx=dc_edit_heroine_prefix(h);
        dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[hIdx]];
        dc_game_model *fs=[self faceSlotAtIndex:hIdx];
        BOOL vibeOn=(_editPlayer.vibe_mask&(1u<<hIdx))!=0;
        BOOL heroinePenetrated=isPenetratedMotion&&(_editAssets.head_count==1u||_editPlayer.active_heroine==h);
        const int32_t *cl=_editPlayer.cur_cloth[h];
        const uint8_t *ac=_editPlayer.cur_acc[h];
        if(bs&&bs->model) {
            uint32_t nv=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_neko_vive"]];
            if(nv!=UINT32_MAX)dc_model_hide_node(bs->model,nv,vibeOn?0u:1u);
            uint32_t tv=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_tori_vive"]];
            if(tv!=UINT32_MAX)dc_model_hide_node(bs->model,tv,1u);
            BOOL wet=(vibeOn||heroinePenetrated||_editClimaxCount>0u);
            BOOL kokanWet=(_editClimaxCount>0u&&(_editAssets.head_count==1u||_editPlayer.active_heroine==h));
            uint32_t mata=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_mata_siru"]];
            if(mata!=UINT32_MAX)dc_model_hide_node(bs->model,mata,wet?0u:1u);
            uint32_t kokan=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_kokan_siru"]];
            if(kokan!=UINT32_MAX)dc_model_hide_node(bs->model,kokan,kokanWet?0u:1u);
            if(h==2u) {
                static NSString *const kManakaHide[]={@"a_On_wanpi",@"a_On_wanpi_U",@"a_On_wanpiHEC",@"a_On_wanpiHEC_U",
                    @"a_On_wanpiEHM",@"a_On_wanpiEHM_U",@"a_On_wanpiHHM",@"a_On_wanpiHHM_U",
                    @"a_On_wanpiEHU",@"a_On_wanpiEHU_U",@"a_On_wanpiHHU",@"a_On_wanpiHHU_U",
                    @"a_On_skartHA",@"a_On_skartHA_U",@"a_On_skartHF",@"a_On_skartHF_U",@"a_On_skartHB",@"a_On_skartHB_U"};
                for(size_t k=0;k<sizeof(kManakaHide)/sizeof(kManakaHide[0]);++k) {
                    uint32_t n=[self findNode:bs name:kManakaHide[k]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
                }
                BOOL off=(cl[0]<=0);
                BOOL disp=(cl[0]==1);
                for(NSString *nm in @[@"a_On_wanpiEHC",@"a_On_wanpiEHC_U",@"a_On_ribon",@"a_On_belt"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(!off&&!disp)?0u:1u);
                }
                for(NSString *nm in @[@"a_On_wanpiHHC",@"a_On_wanpiHHC_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,disp?0u:1u);
                }
            } else if(h==0u) {
                for(NSString *nm in @[@"b_Nn_sera_OBJ",@"b_On_sera_O",@"b_On_sera_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[0]>=2)?0u:1u);
                }
                for(NSString *nm in @[@"b_Nn_seraH_OBJ",@"b_On_seraH_O",@"b_On_seraH_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[0]==1)?0u:1u);
                }
                for(NSString *nm in @[@"b_On_eriH_O",@"b_On_eriH_U",@"b_On_shatuH",@"b_On_shatuH_U",@"b_On_nekuH_R"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
                }
            } else if(h==1u) {
                for(NSString *nm in @[@"c_On_uwagi",@"c_On_uwagi_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[0]>=2)?0u:1u);
                }
                for(NSString *nm in @[@"c_On_uwagiH",@"c_On_uwagiH_U"]) {
                    uint32_t n=[self findNode:bs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[0]==1)?0u:1u);
                }
            }
            if(h!=2u) {
                for(NSString *nm in @[@"a_On_bura",@"a_On_bura_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[1]>=2)?0u:1u);
                }
                for(NSString *nm in @[@"a_On_buraH",@"a_On_buraH_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[1]==1)?0u:1u);
                }
                for(NSString *nm in @[@"a_On_skart",@"a_On_skart_U",@"a_On_skartHF",@"a_On_skartHF_U",@"a_On_skartHB",@"a_On_skartHB_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
                }
                for(NSString *nm in @[@"a_On_skartHA",@"a_On_skartHA_U"]) {
                    uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(cl[2]>=1)?0u:1u);
                }
            }
            int32_t pVal=cl[3];
            if(pVal>=3&&(heroinePenetrated||vibeOn))pVal=2;
            for(NSString *nm in @[@"a_On_pantu",@"a_On_pantu_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(pVal>=3)?0u:1u);
            }
            for(NSString *nm in @[@"a_On_pantuH",@"a_On_pantuH1",@"a_On_pantuH1_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(pVal==2)?0u:1u);
            }
            for(NSString *nm in @[@"a_On_pantuH2",@"a_On_pantuH2_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,(pVal==1)?0u:1u);
            }
            for(NSString *nm in @[@"a_On_pantuH3",@"a_On_pantuH3_U",@"a_On_pantuH4",@"a_On_pantuH4_U"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,1u);
            }
            uint32_t kutuL=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_kutu_L"]];
            uint32_t kutuR=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_On_kutu_R"]];
            BOOL hasShoes=(kutuL!=UINT32_MAX||kutuR!=UINT32_MAX);
            BOOL shoesOff=(!hasShoes||cl[4]<=0);
            if(kutuL!=UINT32_MAX)dc_model_hide_node(bs->model,kutuL,shoesOff?1u:0u);
            if(kutuR!=UINT32_MAX)dc_model_hide_node(bs->model,kutuR,shoesOff?1u:0u);
            for(NSString *nm in @[@"a_On_sune_L",@"a_On_sune_R"]) {
                uint32_t n=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(bs->model,n,shoesOff?0u:1u);
            }
        }
        if(fs&&fs->model) {
            BOOL showKuchi=((curMid==70||curMid==71||curMid==72)&&(_editAssets.head_count==1u||_editPlayer.active_heroine==h));
            for(NSString *nm in @[@"a_On_kuchsiru_F",@"a_On_kuchsiru_ita",@"a_On_kuchsiru_o",@"a_On_kuchsiru_u"]) {
                uint32_t n=[self findNode:fs name:[self nodeNameForPrefix:pfx template:nm]];
                if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,showKuchi?0u:1u);
            }
            uint32_t tear=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_namida"]];
            if(tear!=UINT32_MAX)dc_model_hide_node(fs->model,tear,(_editStateCopy.edit_mode==DC_EDIT_MODE_1P_RESIST)?0u:1u);
            if(h<3u&&_editStateCopy.personality[h]==2) {
                for(NSString *nm in @[@"a_On_mehi_L",@"a_On_mehi_R"]) {
                    uint32_t n=[self findNode:fs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,1u);
                }
            }
            if(h==0u) {
                uint32_t longHair=[self findNode:fs name:@"b_On_long"];
                if(longHair!=UINT32_MAX)dc_model_hide_node(fs->model,longHair,(cl[5]<=0)?0u:1u);
                for(NSString *nm in @[@"b_On_pony",@"b_On_zura",@"b_On_tome"]) {
                    uint32_t n=[self findNode:fs name:nm];
                    if(n!=UINT32_MAX)dc_model_hide_node(fs->model,n,(cl[5]>0)?0u:1u);
                }
            }
            for(NSString *nm in @[@"c_Nn_megane_ani",@"c_On_megane"]) {
                uint32_t fn=[self findNode:fs name:[self nodeNameForPrefix:pfx template:nm]];
                if(fn!=UINT32_MAX)dc_model_hide_node(fs->model,fn,(ac[0]!=0u)?0u:1u);
                if(bs&&bs->model) {
                    uint32_t bn=[self findNode:bs name:[self nodeNameForPrefix:pfx template:nm]];
                    if(bn!=UINT32_MAX)dc_model_hide_node(bs->model,bn,(ac[0]!=0u)?0u:1u);
                }
            }
            uint32_t mimi=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_nekomimi"]];
            if(mimi!=UINT32_MAX)dc_model_hide_node(fs->model,mimi,(ac[1]!=0u)?0u:1u);
        }
    }
}
- (BOOL)switchEditOralRig:(BOOL)useOral error:(NSString **)error {
    if(_editUsingOralRig==useOral||(!_editOralBodyXA&&!_editOralBodyXAMulti[0]))return YES;
    const char *primAnc=(useOral&&_editAssets.oral_anchor_primary[0])?_editAssets.oral_anchor_primary:_editAssets.anchor_primary;
    const char *fallAnc=(useOral&&_editAssets.oral_anchor_fallback[0])?_editAssets.oral_anchor_fallback:_editAssets.anchor_fallback;
    uint32_t anchor=primAnc[0]?[self findNode:&_map name:[NSString stringWithUTF8String:primAnc]]:UINT32_MAX;
    if(anchor!=UINT32_MAX)_anchorName=[NSString stringWithUTF8String:primAnc];
    if(anchor==UINT32_MAX&&fallAnc[0]) {
        anchor=[self findNode:&_map name:[NSString stringWithUTF8String:fallAnc]];
        if(anchor!=UINT32_MAX)_anchorName=[NSString stringWithUTF8String:fallAnc];
    }
    if(anchor==UINT32_MAX)anchor=[self findAnchor:&_map];
    dc_matrix mapWorld=gameIdentity();
    if(anchor!=UINT32_MAX&&dc_model_tick(_map.model,0,0,&mapWorld)==DC_OK) {
        dc_model_global(_map.model,anchor,&_actorWorld);
    }
    for(uint32_t b=0;b<_editAssets.body_count&&b<4u;++b) {
        NSData *targetXA=useOral?_editOralBodyXAMulti[b]:_editNormalBodyXAMulti[b];
        if(!targetXA&&b==0u)targetXA=useOral?_editOralBodyXA:_editNormalBodyXA;
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(!bs)continue;
        if(targetXA&&targetXA!=bs->xaData) {
            [self detachModel:bs];
            bs->xaData=targetXA;
            if(![self openModel:bs staticOnly:NO error:error])return NO;
            NSString *morphErr=nil;
            if(bs->xaInfo.morph_tracks&&![self buildMorphCaches:bs error:&morphErr]) {
                if(error)*error=morphErr?:@"Edit oral rig morph cache failed";
                return NO;
            }
            [self enableEmbeddedXAChainsForSlot:bs];
        }
        bs->world=_actorWorld;
    }
    _face.world=_actorWorld;
    for(uint32_t ef=0;ef<_extraFaceCount&&ef<2u;++ef)_extraFaces[ef].world=_actorWorld;
    _actorOriginX=_actorWorld.values[12];_actorOriginY=_actorWorld.values[13];_actorOriginZ=_actorWorld.values[14];
    memset(_editClips,0,sizeof(_editClips));
    dc_animation_timing *timings=calloc(512u,sizeof(*timings));
    if(timings&&_actor.xaData.length>0) {
        dc_xa_load_clips(_actor.xaData.bytes,_actor.xaData.length,_editClips,timings,512u);
        free(timings);
    } else {
        free(timings);
    }
    for(uint32_t hIdx=0;hIdx<_editAssets.head_count&&hIdx<3u;++hIdx) {
        dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[hIdx]];
        [self applyEditBellyModifiersForBody:bs prefix:dc_edit_heroine_prefix(_headHeroines[hIdx]) level:_editAssets.head_preg_belly[hIdx]];
    }
    NSData *camData=(useOral&&_editOralCamData)?_editOralCamData:_editNormalCamData;
    if(camData.length>0) {
        dc_camera_orbit orbit;
        if(dc_camera_read_preset(camData.bytes,camData.length,0,&orbit)==DC_OK) {
            _cameraPresetData=camData;
            [self adoptCameraOrbit:orbit];
            _secondaryCamera=orbit;
            _primaryCameraMode=0u;_secondaryCameraMode=0u;
        }
    }
    _editUsingOralRig=useOral;
    _lastDynamicTexMask=UINT32_MAX;
    return YES;
}
- (NSString *)applyEditStepPlan:(const dc_edit_step_plan *)plan tick:(uint32_t)tick {
    if(!plan)return nil;
    _editStepPlan=*plan;
    if(plan->finished) {
        if(!_editExitFadeStarted) {
            _editExitFadeStarted=YES;
            if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:tick]!=DC_OK)
                return @"Edit playback exit fade failed";
            _pendingEffectSlot=28u;_hasPendingEffect=YES;
        }
        return nil;
    }
    if(_editPlayer.cur_step>=0&&_editPlayer.cur_step<_editStateCopy.step_count) {
        int32_t stepMid=_editStateCopy.steps[_editPlayer.cur_step].motion_id;
        if((stepMid>=30&&stepMid<=33)||(stepMid>=60&&stepMid<=62)||(stepMid>=70&&stepMid<=72))
            ++_editClimaxCount;
        if((stepMid==7||stepMid==8||(stepMid>=12&&stepMid<=62))&&_editPlayer.active_heroine<3u) {
            if(_editPlayer.hole==0u)_editVagPenMask|=(uint8_t)(1u<<_editPlayer.active_heroine);
            else _editAnalPenMask|=(uint8_t)(1u<<_editPlayer.active_heroine);
        }
    }
    BOOL wantOral=(plan->use_oral_rig!=0u)&&(_editOralBodyXA!=nil||_editOralBodyXAMulti[0]!=nil);
    if(wantOral!=_editUsingOralRig) {
        NSString *swapErr=nil;
        if(![self switchEditOralRig:wantOral error:&swapErr])
            return swapErr?:@"Edit oral rig switch failed";
    }
    _actorPlaybackSpeed=(plan->base_speed>0.f)?plan->base_speed:1.0f;
    for(uint8_t b=0;b<plan->body_count&&b<4u;++b) {
        if(plan->body_clip[b]<0)continue;
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(!bs||!bs->model)continue;
        uint32_t c=(uint32_t)plan->body_clip[b];
        int32_t nc=plan->body_next_clip[b];
        if(nc>=0) {
            dc_model_set_loop(bs->model,c,0);
            dc_model_set_chain(bs->model,c,nc);
        } else {
            dc_model_set_chain(bs->model,c,-1);
        }
    }
    for(uint8_t k=0;k<plan->chain_count&&k<DC_EDIT_MAX_CHAINS;++k) {
        dc_game_model *bs=[self bodySlotAtIndex:plan->chain_body[k]];
        if(bs&&bs->model)dc_model_set_chain(bs->model,plan->chain_from[k],plan->chain_to[k]);
    }
    for(uint8_t k=0;k<plan->loop_count&&k<DC_EDIT_MAX_LOOPS;++k) {
        dc_game_model *bs=[self bodySlotAtIndex:plan->loop_body[k]];
        if(bs&&bs->model)dc_model_set_loop(bs->model,plan->loop_clip[k],plan->loop_limit[k]);
    }
    for(uint8_t b=0;b<plan->body_count&&b<4u;++b) {
        if(plan->body_clip[b]<0)continue;
        dc_game_model *bs=[self bodySlotAtIndex:b];
        if(!bs||!bs->model)continue;
        uint32_t c=(uint32_t)plan->body_clip[b];
        dc_animation_state curState={0};
        if(dc_model_get_animation(bs->model,&curState)==DC_OK&&curState.current==c) {
            dc_model_request(bs->model,(c==1u)?0u:1u,tick);
        }
        dc_model_request(bs->model,c,tick);
        ++_characterAnimationStarts;
    }
    _editExpectedClip=(plan->body_clip[0]>=0)?(uint32_t)plan->body_clip[0]:1u;
    _editCamTargetHeroine=plan->cam_target_heroine;
    if(plan->update_cam_pivot&&_primaryCameraMode!=2u) {
        dc_matrix target;
        if([self cameraBinding:DC_CAMERA_BODY_TARGET matrix:&target]==DC_OK) {
            dc_camera_orbit current=[self activeCameraOrbit],next;
            if(dc_camera_retarget(&current,&target,1,&next)==DC_OK) {
                _lastCameraTarget=target;_lastCameraTargetBinding=DC_CAMERA_BODY_TARGET;
                [self adoptCameraOrbit:next];
                ++_cameraRetargetCount;++_cameraActionCount;
            }
        }
    }
    [self applyEditClothingAndVibeVisibility];
    if(plan->voice_stem[0]!='\0') {
        _pendingVoiceName=[NSString stringWithUTF8String:plan->voice_stem];
        _voiceBlushActive=YES;
    }
    if(plan->se_name[0]!='\0') {
        _pendingEffectName=[NSString stringWithUTF8String:plan->se_name];
    }
    _lastDynamicTexMask=UINT32_MAX;
    return nil;
}
- (NSString *)stepContextAtX:(float)x y:(float)y left:(uint32_t)left right:(uint32_t)right {
    if(_sceneType==7&&right==3&&!_contextMenu.opening_right&&left!=3) {
        uint8_t consumed=0u;
        if(dc_type7_right_click_menu(&_type7State,(uint8_t)_contextMenu.icon,&consumed)==DC_OK&&consumed) {
            [self rebuildType7ContextMenuForHub:(uint8_t)_contextMenu.icon atX:_type7HubOriginX y:_type7HubOriginY right:YES];
            _pendingEffectSlot=24u;_hasPendingEffect=YES;
            return nil;
        }
    }
    if(_sceneType==12&&_editAssets.head_count>1u&&_contextMenu.icon==3&&right==3&&!_contextMenu.opening_right&&left!=3) {
        uint32_t curIdx=0u;
        for(uint32_t i=0;i<_editAssets.head_count;++i) {
            if(_headHeroines[i]==_editCamTargetHeroine){curIdx=i;break;}
        }
        _editCamTargetHeroine=_headHeroines[(curIdx+1u)%_editAssets.head_count];
        _pendingEffectSlot=24u;_hasPendingEffect=YES;
        return nil;
    }
    dc_scene_context_event event;
    if(dc_scene_context_step(&_contextMenu,x,y,left,right,&event)!=DC_OK)return @"Scene context input failed";
    if(event.close_code) {
        _contextOpen=NO;
        if(event.selected>=0) {
            ++_contextSelections;_lastContextSelection=event.selected;
            if(_sceneType==7) {
                dc_type7_plan plan;
                if(dc_type7_select_menu_item(&_type7State,(uint8_t)_contextMenu.icon,(uint8_t)event.selected,&plan)!=DC_OK)
                    return @"Type 7 radial menu selection failed";
                ++_characterActionCount;
                NSString *err=[self applyType7Plan:&plan tick:_lastTick];
                if(!err&&!_hasPendingEffect) {
                    _pendingEffectSlot=(_contextMenu.icon==4)?25u:26u;
                    _hasPendingEffect=YES;
                }
                return err;
            }
            NSString *error=[self applyContextSelection:(uint32_t)event.selected];
            if(!error&&!_hasPendingEffect) {
                _pendingEffectSlot=(_contextMenu.icon==4)?25u:26u;
                _hasPendingEffect=YES;
            }
            return error;
        }
        ++_contextDismissals;
    }
    return nil;
}
- (void)consumeChapterEndAction { _chapterEndAction=0; }
- (NSString *)characterNode:(NSString *)name {
    if([name hasPrefix:@"a_"])return [NSString stringWithFormat:@"%c%@",_characterPrefix,[name substringFromIndex:1]];
    if([name hasPrefix:@"AA_"]){char upper=(char)toupper((unsigned char)_characterPrefix);return [NSString stringWithFormat:@"%c%c%@",upper,upper,[name substringFromIndex:2]];}
    return name;
}
- (void)resetClothingStatesForDefault {
    _clothingTopState=(_sceneType==6&&_storyStage==2)?6u:0u;
    _clothingBraState=0u;
    _clothingSkirtState=(_sceneType==6)?3u:0u;
    _clothingPantyState=0u;
    if((_sceneType==4||_sceneType==5)&&_stageProgress==2u&&!_editMode&&_naturalGameplayRoute&&
       ![NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"]&&
       arc4random_uniform(10u)<3u) {
        _clothingBraState=2u;
        _clothingPantyState=4u;
    }
    _clothingShoeState=(_sceneType==6&&_storyStage==0)?1u:0u;
    _clothingAccState=(_storyStage==1)?1u:((_sceneType==6&&_storyStage==0&&(_mapSelector==0||_mapSelector==4||_mapSelector==8))?1u:0u);
    _accessoryHidden=NO;
    [self syncLegacyClothingSummary];
}
- (void)syncLegacyClothingSummary {
    if(_storyStage==2) {
        _watchTopStage=(_clothingTopState>=8u)?2u:((_clothingTopState%2u)?1u:0u);
        _watchSkirtStage=(_clothingTopState>=4u)?2u:((_clothingTopState>=2u)?1u:0u);
    } else {
        _watchTopStage=(_clothingTopState>=2u||_clothingBraState>=1u)?2u:((_clothingTopState==1u)?1u:0u);
        _watchSkirtStage=(_clothingSkirtState>=2u)?2u:((_clothingSkirtState==1u)?1u:0u);
    }
    uint8_t pantyOffState=(_sceneType==6)?3u:4u;
    _watchPantyStage=(_clothingPantyState>=1u||_watchNekoVibeVisible||_watchToriVibeVisible)?1u:0u;
    BOOL topOff=(_storyStage==2)?(_clothingTopState>=8u):(_clothingTopState>=2u);
    BOOL braOff=(_storyStage==2)||(_clothingBraState>=2u);
    BOOL skirtOff=(_storyStage==2)?(_clothingTopState>=8u):(_clothingSkirtState>=4u);
    BOOL pantyOff=(_clothingPantyState>=pantyOffState);
    BOOL bottomExposed=((_storyStage==2)?(_clothingTopState>=2u):(_clothingSkirtState>=1u))&&
                       (_clothingPantyState>=((_sceneType==6)?1u:2u));
    if(topOff&&braOff&&skirtOff&&pantyOff) {
        _outfitVariant=3u;
    } else if(bottomExposed||pantyOff||skirtOff) {
        _outfitVariant=2u;
    } else if(_watchTopStage>=1u) {
        _outfitVariant=1u;
    } else {
        _outfitVariant=0u;
    }
    _accessoryHidden=(_storyStage==1)?(_clothingAccState==0u):(_clothingAccState!=0u);
}
- (BOOL)isOuterClothingUndisplacedForWatchPart:(int32_t)part {
    if(part==1||part==2) {
        return (_storyStage==2)?(_clothingTopState<8u&&(_clothingTopState%2u)==0u):(_clothingTopState==0u);
    }
    if(part==3||part==5||part==6) {
        return (_storyStage==2)?(_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u):
            (_clothingSkirtState==0u||_clothingSkirtState==2u);
    }
    if(part==4) {
        return (_storyStage==2)?(_clothingTopState<4u):(_clothingSkirtState==0u||_clothingSkirtState==1u);
    }
    return NO;
}
- (BOOL)advanceWatchClothingForPart:(int32_t)part {
    BOOL advanced=NO;
    _lastUndressClip=0u;
    if(part==1||part==2) {
        if(_storyStage==2) {
            if(_clothingTopState<8u&&(_clothingTopState%2u)==0u) {
                ++_clothingTopState;
                _lastUndressClip=(part==1)?251u:253u;
                advanced=YES;
            }
        } else {
            if(_clothingTopState==0u) {
                _clothingTopState=1u;
                _lastUndressClip=(part==1)?251u:253u;
                advanced=YES;
            } else if(_clothingBraState==0u) {
                _clothingBraState=1u;
                _lastUndressClip=(part==1)?255u:257u;
                advanced=YES;
            }
        }
    } else if(part==3) {
        if(_storyStage==2) {
            if(_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u) {
                _clothingTopState+=2u;
                _lastUndressClip=259u;
                advanced=YES;
            } else if(_clothingPantyState<2u) {
                _clothingPantyState=2u;
                _lastUndressClip=261u;
                advanced=YES;
            }
        } else {
            if(_clothingSkirtState==0u||_clothingSkirtState==2u) {
                ++_clothingSkirtState;
                _lastUndressClip=259u;
                advanced=YES;
            } else if(_clothingPantyState<2u) {
                _clothingPantyState=2u;
                _lastUndressClip=261u;
                advanced=YES;
            }
        }
    } else if(part==4) {
        if(_storyStage==2) {
            if(_clothingTopState<4u) {
                _clothingTopState+=4u;
                _lastUndressClip=263u;
                advanced=YES;
            } else if(_clothingPantyState<2u) {
                _clothingPantyState=2u;
                _lastUndressClip=265u;
                advanced=YES;
            }
        } else {
            if(_clothingSkirtState==0u||_clothingSkirtState==1u) {
                _clothingSkirtState+=2u;
                _lastUndressClip=263u;
                advanced=YES;
            } else if(_clothingPantyState<2u) {
                _clothingPantyState=2u;
                _lastUndressClip=265u;
                advanced=YES;
            }
        }
    } else if(part==5||part==6) {
        if(_storyStage==2) {
            if(_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u) {
                _clothingTopState+=2u;
                _lastUndressClip=259u;
                advanced=YES;
            }
        } else {
            if(_clothingSkirtState==0u||_clothingSkirtState==2u) {
                ++_clothingSkirtState;
                _lastUndressClip=259u;
                advanced=YES;
            }
        }
    }
    if(advanced) {
        [self syncLegacyClothingSummary];
        [self applyClothingVisibility];
        _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
    }
    return advanced;
}
- (void)applyClothingVisibility {
    [self applyInitialVisibility];
    if(!_actor.model)return;
    if(_storyStage==2) {
        static NSString *const kWanpiMain[8]={
            @"a_On_wanpi",@"a_On_wanpiHEC",@"a_On_wanpiEHM",@"a_On_wanpiHHM",
            @"a_On_wanpiEHU",@"a_On_wanpiHHU",@"a_On_wanpiEHC",@"a_On_wanpiHHC"
        };
        static NSString *const kWanpiUnder[8]={
            @"a_On_wanpi_U",@"a_On_wanpiHEC_U",@"a_On_wanpiEHM_U",@"a_On_wanpiHHM_U",
            @"a_On_wanpiEHU_U",@"a_On_wanpiHHU_U",@"a_On_wanpiEHC_U",@"a_On_wanpiHHC_U"
        };
        for(unsigned i=0;i<8;++i) {
            uint32_t hidden=(_clothingTopState==i)?0u:1u;
            uint32_t n0=[self findNode:&_actor name:kWanpiMain[i]];
            if(n0!=UINT32_MAX)dc_model_hide_node(_actor.model,n0,hidden);
            uint32_t n1=[self findNode:&_actor name:kWanpiUnder[i]];
            if(n1!=UINT32_MAX)dc_model_hide_node(_actor.model,n1,hidden);
        }
        uint32_t ribon=[self findNode:&_actor name:@"a_On_ribon"];
        if(ribon!=UINT32_MAX)dc_model_hide_node(_actor.model,ribon,(_clothingTopState<8u&&(_clothingTopState%2u)==0u)?0u:1u);
        uint32_t belt=[self findNode:&_actor name:@"a_On_belt"];
        if(belt!=UINT32_MAX)dc_model_hide_node(_actor.model,belt,(_clothingTopState<4u)?0u:1u);
    } else if(_storyStage==0) {
        uint32_t sera=[self findNode:&_actor name:@"b_Nn_sera_OBJ"];
        if(sera!=UINT32_MAX)dc_model_hide_node(_actor.model,sera,(_clothingTopState==0u)?0u:1u);
        uint32_t seraH=[self findNode:&_actor name:@"b_Nn_seraH_OBJ"];
        if(seraH!=UINT32_MAX)dc_model_hide_node(_actor.model,seraH,(_clothingTopState==1u)?0u:1u);
    } else {
        uint32_t uwagi=[self findNode:&_actor name:@"c_On_uwagi"];
        if(uwagi!=UINT32_MAX)dc_model_hide_node(_actor.model,uwagi,(_clothingTopState==0u)?0u:1u);
        for(NSString *name in @[@"c_On_uwagiH",@"c_On_uwagiH_U"]) {
            uint32_t n=[self findNode:&_actor name:name];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,(_clothingTopState==1u)?0u:1u);
        }
    }
    if(_storyStage!=2) {
        uint32_t bura=[self findNode:&_actor name:[self characterNode:@"a_On_bura"]];
        if(bura!=UINT32_MAX)dc_model_hide_node(_actor.model,bura,(_clothingBraState==0u)?0u:1u);
        for(NSString *name in @[@"a_On_buraH",@"a_On_buraH_U"]) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,(_clothingBraState==1u)?0u:1u);
        }
        static NSString *const kSkirtMain[4]={@"a_On_skart",@"a_On_skartHF",@"a_On_skartHB",@"a_On_skartHA"};
        static NSString *const kSkirtUnder[4]={@"a_On_skart_U",@"a_On_skartHF_U",@"a_On_skartHB_U",@"a_On_skartHA_U"};
        for(unsigned i=0;i<4;++i) {
            uint32_t hidden=(_clothingSkirtState==i)?0u:1u;
            uint32_t n0=[self findNode:&_actor name:[self characterNode:kSkirtMain[i]]];
            if(n0!=UINT32_MAX)dc_model_hide_node(_actor.model,n0,hidden);
            uint32_t n1=[self findNode:&_actor name:[self characterNode:kSkirtUnder[i]]];
            if(n1!=UINT32_MAX)dc_model_hide_node(_actor.model,n1,hidden);
        }
    }
    for(NSString *name in @[@"a_On_pantu",@"a_On_pantuH",@"a_On_pantuH1",@"a_On_pantuH2",@"a_On_pantuH2_U",@"a_On_pantuH3",@"a_On_pantuH3_U",@"a_On_pantuH4",@"a_On_pantuH4_U"]) {
        uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
        if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,1u);
    }
    if(_sceneType==6) {
        dc_animation_state anim={0};
        if(_actor.model)dc_model_get_animation(_actor.model,&anim);
        uint8_t effPanty=(_clothingPantyState==0u&&anim.current>=10u&&anim.current<=54u)?1u:_clothingPantyState;
        if(effPanty==0u) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_pantu"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
        } else if(effPanty==1u) {
            for(NSString *name in @[@"a_On_pantuH",@"a_On_pantuH1"]) {
                uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
                if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
            }
        } else if(effPanty==2u) {
            for(NSString *name in @[@"a_On_pantuH2",@"a_On_pantuH2_U"]) {
                uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
                if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
            }
        }
    } else if(_sceneType==5&&_watchScrubState!=0u&&(_watchScrubClip==260u||_watchScrubClip==264u||_watchScrubClip==270u)) {
        for(NSString *name in @[@"a_On_pantuH4",@"a_On_pantuH4_U"]) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
        }
    } else {
        if(_clothingPantyState==0u) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_pantu"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
        } else if(_clothingPantyState==1u) {
            BOOL foundH1=NO;
            for(NSString *name in @[@"a_On_pantuH",@"a_On_pantuH1"]) {
                uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
                if(n!=UINT32_MAX){dc_model_hide_node(_actor.model,n,0u);foundH1=YES;}
            }
            if(!foundH1) {
                for(NSString *name in @[@"a_On_pantuH3",@"a_On_pantuH3_U"]) {
                    uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
                    if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
                }
            }
        } else if(_clothingPantyState==2u) {
            for(NSString *name in @[@"a_On_pantuH3",@"a_On_pantuH3_U"]) {
                uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
                if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
            }
        } else if(_clothingPantyState==3u) {
            for(NSString *name in @[@"a_On_pantuH2",@"a_On_pantuH2_U"]) {
                uint32_t n=[self findNode:&_actor name:[self characterNode:name]];
                if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0u);
            }
        }
    }
    for(NSString *kutu in @[@"a_On_kutu_L",@"a_On_kutu_R"]) {
        uint32_t n=[self findNode:&_actor name:[self characterNode:kutu]];
        if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,(_clothingShoeState==0u)?0u:1u);
    }
    for(NSString *sune in @[@"a_On_sune_L",@"a_On_sune_R"]) {
        uint32_t n=[self findNode:&_actor name:[self characterNode:sune]];
        if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,(_clothingShoeState==0u)?1u:0u);
    }
    uint32_t nekoNode=[self findNode:&_actor name:[self characterNode:@"a_On_neko_vive"]];
    if(nekoNode!=UINT32_MAX)dc_model_hide_node(_actor.model,nekoNode,_watchNekoVibeVisible?0u:1u);
    uint32_t toriNode=[self findNode:&_actor name:[self characterNode:@"a_On_tori_vive"]];
    if(toriNode!=UINT32_MAX)dc_model_hide_node(_actor.model,toriNode,_watchToriVibeVisible?0u:1u);
    if(_storyStage==0&&_face.model) {
        uint32_t longHair=[self findNode:&_face name:@"b_On_long"];
        if(longHair!=UINT32_MAX)dc_model_hide_node(_face.model,longHair,(_clothingAccState==1u)?0u:1u);
        for(NSString *twin in @[@"b_On_pony",@"b_On_zura"]) {
            uint32_t n=[self findNode:&_face name:twin];
            if(n!=UINT32_MAX)dc_model_hide_node(_face.model,n,(_clothingAccState==0u)?0u:1u);
        }
    } else if(_storyStage==1) {
        for(NSString *glass in @[@"c_Nn_megane_ani",@"c_On_megane"]) {
            uint32_t fn=_face.model?[self findNode:&_face name:glass]:UINT32_MAX;
            if(fn!=UINT32_MAX)dc_model_hide_node(_face.model,fn,(_clothingAccState==1u)?0u:1u);
            uint32_t an=_actor.model?[self findNode:&_actor name:glass]:UINT32_MAX;
            if(an!=UINT32_MAX)dc_model_hide_node(_actor.model,an,(_clothingAccState==1u)?0u:1u);
        }
    } else if(_storyStage==2&&_face.model) {
        uint32_t ears=[self findNode:&_face name:@"a_On_nekomimi"];
        if(ears!=UINT32_MAX)dc_model_hide_node(_face.model,ears,(_clothingAccState==1u)?0u:1u);
    }
}
- (void)applyBaseOutfitVisibility:(uint32_t)variant {
    (void)variant;
    [self applyClothingVisibility];
}
- (void)buildClothingContextMenuAtX:(float)px y:(float)py right:(BOOL)right animation:(uint32_t)animClip {
    float unit=105.f*.3333333432674408f;
    const float dx[7]={0,unit,unit+unit,105,unit+unit,unit,0};
    const float dy[7]={-105,-(unit+unit),-unit,0,unit,unit+unit,105};
    static const int32_t kAccessoryResourceIds[6]={18,21,20,17,19,16};
    int32_t accId=kAccessoryResourceIds[(_storyStage%3u)*2u+(_clothingAccState&1u)];
    int32_t shoeId=_clothingShoeState?15:14;
    uint32_t flag=_editMode?2u:MIN(_stageProgress,2u);
    _contextMenu=(dc_scene_context){.icon=2,.opening_right=right?1u:0u,.hover=-1};
    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
    if(_sceneType==5&&flag==1u) {
        _contextMenu.count=1u;
        _contextMenu.items[0]=(dc_scene_context_item){accId,6u,px-dx[6],py+dy[6]};
        return;
    }
    int32_t topId=-1,braId=-1,skirtId=-1,pantyId=-1;
    BOOL topBlocked=(_storyStage!=2&&_clothingBraState==1u&&
        ((_sceneType==4&&flag==1u)?(_clothingTopState==1u):(_clothingTopState>=2u)));
    if(!topBlocked) {
        if(_sceneType==4) {
            if(_storyStage!=2) {
                topId=(flag==2u)?(1+(int32_t)(_clothingTopState%3u)):((_clothingTopState==1u)?3:1);
            } else {
                topId=(flag==2u)?((_clothingTopState>=8u)?3:((_clothingTopState%2u)?2:1)):((_clothingTopState%2u)?3:1);
            }
        } else if(_sceneType==5) {
            topId=(_storyStage!=2)?((_clothingTopState>=2u)?3:2):((_clothingTopState>=8u)?3:2);
        } else {
            topId=(_storyStage!=2)?(1+(int32_t)(_clothingTopState%3u)):((_clothingTopState>=8u)?3:((_clothingTopState%2u)?2:1));
        }
    }
    if(_storyStage!=2&&_clothingTopState>0u) {
        if(_sceneType==4) {
            braId=(flag==2u)?(4+(int32_t)(_clothingBraState%3u)):((_clothingBraState==1u)?6:4);
        } else if(_sceneType==5) {
            braId=(_clothingBraState>=2u)?6:5;
        } else {
            braId=4+(int32_t)(_clothingBraState%3u);
        }
    }
    if(_sceneType==4) {
        if(_storyStage!=2) {
            skirtId=(flag==2u)?((_clothingSkirtState>=4u)?9:((_clothingSkirtState==3u)?8:7)):((_clothingSkirtState==3u)?9:7);
        } else {
            skirtId=(flag==2u)?((_clothingTopState>=8u)?9:(((_clothingTopState/2u)==3u)?8:7)):(((_clothingTopState/2u)==3u)?9:7);
        }
    } else if(_sceneType==5) {
        skirtId=(_storyStage!=2)?((_clothingSkirtState>=4u)?9:8):((_clothingTopState>=8u)?9:8);
    } else {
        if(_storyStage!=2) {
            skirtId=(_clothingSkirtState>=4u)?9:8;
        } else {
            skirtId=(_clothingTopState>=8u)?9:(((_clothingTopState/2u)==3u)?8:7);
        }
    }
    if(_sceneType==4) {
        pantyId=(flag==2u)?((_clothingPantyState==0u)?11:((_clothingPantyState>=4u)?13:12)):((_clothingPantyState>=2u)?13:11);
    } else if(_sceneType==5) {
        pantyId=(_clothingPantyState>=4u)?13:12;
    } else {
        uint32_t effPanty=(_clothingPantyState==0u&&animClip>=10u&&animClip<=54u)?1u:MIN((uint32_t)_clothingPantyState,3u);
        pantyId=10+(int32_t)effPanty;
    }
    _contextMenu.count=(_sceneType==6)?5u:6u;
    const int32_t itemIds[6]={topId,braId,skirtId,pantyId,shoeId,accId};
    for(unsigned i=0;i<_contextMenu.count;++i) {
        uint32_t a=i+1u;
        _contextMenu.items[i]=(dc_scene_context_item){itemIds[i],a,px-dx[a],py+dy[a]};
    }
}
- (void)applyClothingContextSelection:(uint32_t)selection {
    uint32_t category=(selection<_contextMenu.count)?_contextMenu.items[selection].arrangement:0u;
    uint32_t flag=_editMode?2u:MIN(_stageProgress,2u);
    dc_animation_state anim={0};
    if(_actor.model)dc_model_get_animation(_actor.model,&anim);
    if(category==1u) {
        if(_sceneType==4) {
            if(_storyStage!=2) {
                _clothingTopState=(flag==2u)?(uint8_t)((_clothingTopState+1u)%3u):((_clothingTopState==0u)?1u:0u);
            } else {
                if(flag==2u) {
                    if(_clothingTopState>=8u)_clothingTopState=0u;
                    else if((_clothingTopState%2u)==0u)++_clothingTopState;
                    else _clothingTopState=8u;
                } else {
                    if((_clothingTopState%2u)==0u)++_clothingTopState;
                    else --_clothingTopState;
                }
            }
        } else if(_sceneType==5) {
            if(_storyStage!=2)_clothingTopState=(_clothingTopState>=2u)?0u:2u;
            else _clothingTopState=(_clothingTopState>=8u)?0u:8u;
        } else {
            if(_storyStage!=2) {
                _clothingTopState=(uint8_t)((_clothingTopState+1u)%3u);
            } else {
                if(_clothingTopState>=8u||_clothingTopState<6u)_clothingTopState=6u;
                else ++_clothingTopState;
            }
        }
    } else if(category==2u&&_storyStage!=2) {
        if(_sceneType==4) {
            _clothingBraState=(flag==2u)?(uint8_t)((_clothingBraState+1u)%3u):((_clothingBraState==0u)?1u:0u);
        } else if(_sceneType==5) {
            _clothingBraState=(_clothingBraState>=2u)?0u:2u;
        } else {
            _clothingBraState=(uint8_t)((_clothingBraState+1u)%3u);
        }
    } else if(category==3u) {
        if(_sceneType==4) {
            if(_storyStage!=2) {
                if(flag==2u) {
                    if(_clothingSkirtState<3u)_clothingSkirtState=3u;
                    else if(_clothingSkirtState==3u)_clothingSkirtState=4u;
                    else _clothingSkirtState=0u;
                } else {
                    _clothingSkirtState=(_clothingSkirtState<3u)?3u:0u;
                }
            } else {
                if(flag==2u) {
                    if(_clothingTopState>=8u)_clothingTopState=0u;
                    else if((_clothingTopState/2u)<3u)_clothingTopState=(uint8_t)(6u+(_clothingTopState%2u));
                    else _clothingTopState=8u;
                } else {
                    if((_clothingTopState/2u)<3u)_clothingTopState=(uint8_t)(6u+(_clothingTopState%2u));
                    else _clothingTopState=(uint8_t)(_clothingTopState%2u);
                }
            }
        } else if(_sceneType==5) {
            if(_storyStage!=2)_clothingSkirtState=(_clothingSkirtState>=4u)?0u:4u;
            else _clothingTopState=(_clothingTopState>=8u)?0u:8u;
        } else {
            if(_storyStage!=2)_clothingSkirtState=(_clothingSkirtState>=4u)?3u:4u;
            else _clothingTopState=(_clothingTopState>=8u)?6u:8u;
        }
    } else if(category==4u) {
        if(_sceneType==4) {
            BOOL vibeActive=(anim.current==11u||anim.current==13u||_watchNekoVibeVisible||_watchToriVibeVisible);
            if(flag==2u) {
                if(_clothingPantyState<=1u)_clothingPantyState=2u;
                else if(_clothingPantyState==2u)_clothingPantyState=4u;
                else _clothingPantyState=(!_naturalGameplayRoute&&vibeActive)?2u:0u;
            } else {
                if(_clothingPantyState<=1u)_clothingPantyState=2u;
                else _clothingPantyState=(!_naturalGameplayRoute&&vibeActive)?2u:0u;
            }
            if(_clothingPantyState==0u&&vibeActive&&_naturalGameplayRoute) {
                _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
                _actorPlaybackSpeed=1.0f;
                dc_model_set_chain(_actor.model,15,1);
                dc_model_set_chain(_actor.model,16,1);
                uint32_t exitClip=(anim.current==13u)?16u:((anim.current==11u)?15u:1u);
                if(_actor.model&&exitClip!=anim.current) {
                    dc_model_request(_actor.model,exitClip,_lastTick);
                    ++_characterAnimationStarts;
                }
            }
        } else if(_sceneType==5) {
            if(_clothingPantyState>=4u) {
                _clothingPantyState=0u;
                if(_watchNekoVibeVisible||_watchToriVibeVisible||_watchVibeSwitch) {
                    _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
                    _actorPlaybackSpeed=1.0f;
                    if(anim.current==201u&&_actor.model) {
                        _motionState.clip=21u;
                        dc_model_request(_actor.model,21u,_lastTick);
                    }
                }
            } else {
                _clothingPantyState=4u;
                if(anim.current==33u&&_actor.model) {
                    uint32_t nextClip=34u+(_voiceSequenceIndex%5u);
                    _motionState.clip=nextClip;
                    dc_model_request(_actor.model,nextClip,_lastTick);
                }
            }
        } else {
            uint32_t effPanty=(_clothingPantyState==0u&&anim.current>=10u&&anim.current<=54u)?1u:MIN((uint32_t)_clothingPantyState,3u);
            if(anim.current>=10u&&anim.current<=54u)
                _clothingPantyState=(uint8_t)((effPanty%3u)+1u);
            else
                _clothingPantyState=(uint8_t)((effPanty+1u)%4u);
        }
    } else if(category==5u) {
        _clothingShoeState=(uint8_t)((_clothingShoeState+1u)%2u);
    } else if(category==6u) {
        _clothingAccState=(uint8_t)((_clothingAccState+1u)%2u);
        _accessoryToggled=YES;
    }
    [self syncLegacyClothingSummary];
    [self applyClothingVisibility];
    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
    _pendingEffectSlot=2u;_hasPendingEffect=YES;
    ++_characterActionCount;
}
- (void)syncDynamicClothingForPart:(int32_t)part clip:(uint32_t)clip {
    if(_sceneType==6&&clip>=10u&&clip<=54u&&_clothingPantyState==0u) {
        _clothingPantyState=1u;
        [self syncLegacyClothingSummary];
    }
    if(!_actor.model||(part==_lastClothingPart&&clip==_lastClothingClip&&
       _clothingTopState==_lastClothingTopState&&_clothingBraState==_lastClothingBraState&&
       _clothingSkirtState==_lastClothingSkirtState&&_clothingPantyState==_lastClothingPantyState&&
       _clothingShoeState==_lastClothingShoeState&&_clothingAccState==_lastClothingAccState&&
       _watchTopStage==_lastWatchTopStage&&_watchSkirtStage==_lastWatchSkirtStage&&_watchPantyStage==_lastWatchPantyStage))return;
    _lastClothingPart=part;_lastClothingClip=clip;
    _lastClothingTopState=_clothingTopState;_lastClothingBraState=_clothingBraState;
    _lastClothingSkirtState=_clothingSkirtState;_lastClothingPantyState=_clothingPantyState;
    _lastClothingShoeState=_clothingShoeState;_lastClothingAccState=_clothingAccState;
    _lastWatchTopStage=_watchTopStage;_lastWatchSkirtStage=_watchSkirtStage;_lastWatchPantyStage=_watchPantyStage;
    [self applyClothingVisibility];
    if(_sceneType==5) {
        if((clip>=160&&clip<=193)||_watchTouchGauge>0.f||_watchClimaxElapsedMs>0u) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_mata_siru"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
        }
        if(clip>=160&&clip<=193) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_kokan_siru"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
        }
    } else if(_sceneType==6) {
        if(clip==4&&_storyStage!=1&&_stageProgress==0&&!_editMode)_tearVisible=YES;
        else if(clip==8&&(_storyStage!=0||(_stageProgress==0&&!_editMode)))_tearVisible=YES;
        if(_tearVisible&&_face.model) {
            uint32_t tearNode=[self findNode:&_face name:[self characterNode:@"a_On_namida"]];
            if(tearNode!=UINT32_MAX)dc_model_hide_node(_face.model,tearNode,0);
        }
        if((clip>=24&&clip<=32)||(clip>=55&&clip<=58)||_nightExcitement>0.f) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_mata_siru"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
        }
        if((clip>=24&&clip<=32)||(clip>=55&&clip<=58)||_externalClimaxLevel>0u) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_kokan_siru"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
        }
        if((clip>=30&&clip<=32)||(clip>=56&&clip<=57)) {
            for(NSString *sn in @[@"z_Nn_siru",@"s_On_siru_1",@"s_On_siru_2",@"s_On_siru_3",@"s_On_siru_4",@"s_On_siru_5",@"s_On_siru_6"]) {
                uint32_t n=[self findNode:&_actor name:sn];
                if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
            }
        }
        if((clip>=26&&clip<=32)||(clip>=55&&clip<=57)) {
            uint32_t intCount=_nightInternalVagCount+_nightInternalAnalCount;
            BOOL big=(intCount>0u)?(intCount>1u):((_stageOutcomeA+_stageOutcomeB)>1u);
            NSString *primary=(clip>=55)?(big?@"b_On_tare2_big":@"b_On_tare2_small"):(big?@"b_On_tare_big":@"b_On_tare_small");
            NSString *fallback=big?@"b_On_tare_big":@"b_On_tare_small";
            uint32_t tn=[self findNode:&_actor name:[self characterNode:primary]];
            if(tn==UINT32_MAX)tn=[self findNode:&_actor name:[self characterNode:fallback]];
            if(tn!=UINT32_MAX)dc_model_hide_node(_actor.model,tn,0);
        }
    }
}
- (void)updateWatchAuxiliaryPlacement {
    if(_actor.model) {
        BOOL breastPoseDirty=NO;
        for(unsigned b=0;b<2;++b) {
            if(_breastNodes[b]!=UINT32_MAX) {
                dc_model_set_node_extra(_actor.model,_breastNodes[b],0,NULL);
                breastPoseDirty=YES;
            }
        }
        if(_sceneType==5&&_watchDragging&&(_watchPart==1||_watchPart==2)) {
            unsigned side=(_watchPart==1)?0u:1u;
            uint32_t bNode=_breastNodes[side];
            if(bNode!=UINT32_MAX) {
                float maxAngle=(_storyStage==2)?(20.f*0.0174532925f):(40.f*0.0174532925f);
                float squashRadius=(_storyStage==2)?0.2f:0.5f;
                float pitch=fmaxf(-maxAngle,fminf(maxAngle,(_watchSlidePhi/squashRadius)*maxAngle*0.35f));
                float yaw=fmaxf(-maxAngle,fminf(maxAngle,(_watchSlideTheta/squashRadius)*maxAngle*0.35f));
                float sx=(_storyStage==2)?1.05f:0.86f;
                float sy=(_storyStage==2)?1.05f:0.70f;
                float sz=(_storyStage==2)?0.92f:0.90f;
                float cp=cosf(pitch),sp=sinf(pitch),cy=cosf(yaw),syaw=sinf(yaw);
                dc_matrix extra={{
                    sx*cy, sx*sp*syaw, -sx*cp*syaw, 0.f,
                    0.f,   sy*cp,       sy*sp,      0.f,
                    sz*syaw,-sz*sp*cy,  sz*cp*cy,   0.f,
                    0.f,   0.f,         0.f,        1.f
                }};
                dc_model_set_node_extra(_actor.model,bNode,2,&extra);
                breastPoseDirty=YES;
            }
        }
        if(breastPoseDirty&&_sceneType==5)dc_model_refresh_pose(_actor.model,&_actor.world);
    }
    if(_sceneType!=5||_watchPart<0||_watchPart>=7)return;
    dc_game_model *slot=(_watchPart==0&&_face.model)?&_face:&_actor;
    uint32_t node=_targetNodes[_watchPart];
    if(_watchPart==0) {
        if(node==UINT32_MAX){slot=&_actor;node=_actorHeadNode;}
    } else if(_watchPart==1&&_watchContactNodes[0]!=UINT32_MAX) {
        node=_watchContactNodes[0];
    } else if(_watchPart==2&&_watchContactNodes[1]!=UINT32_MAX) {
        node=_watchContactNodes[1];
    } else if(_watchPart==3) {
        if([self isOuterClothingUndisplacedForWatchPart:3]&&_skirtTargetNodes[0]!=UINT32_MAX)node=_skirtTargetNodes[0];
        else if(_watchContactNodes[2]!=UINT32_MAX)node=_watchContactNodes[2];
    } else if(_watchPart==4) {
        if([self isOuterClothingUndisplacedForWatchPart:4]&&_skirtTargetNodes[1]!=UINT32_MAX)node=_skirtTargetNodes[1];
        else if(_watchContactNodes[3]!=UINT32_MAX)node=_watchContactNodes[3];
    } else if((_watchPart==5||_watchPart==6)&&_watchContactNodes[4]!=UINT32_MAX) {
        node=_watchContactNodes[4];
    }
    dc_matrix targetWorld;
    if(!slot->model||node==UINT32_MAX||dc_model_global(slot->model,node,&targetWorld)!=DC_OK)return;
    float cp=cosf(_watchSlidePhi),sp=sinf(_watchSlidePhi),ct=cosf(_watchSlideTheta),st=sinf(_watchSlideTheta);
    dc_matrix slide={{
        ct,    0.f,   -st,  0.f,
        sp*st, cp,    sp*ct,0.f,
        cp*st, -sp,   cp*ct,0.f,
        st*0.35f, -sp*0.35f, 0.f, 1.f
    }};
    dc_matrix placed=targetWorld;
    if(dc_matrix_multiply(&slide,&targetWorld,&placed)!=DC_OK)placed=targetWorld;
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)
        _watchAuxiliary[auxiliary].world=placed;
}
- (void)clearProceduralActorExtras {
    if(_actor.model) {
        if(_neckNode!=UINT32_MAX)dc_model_set_node_extra(_actor.model,_neckNode,0,NULL);
        for(unsigned b=0;b<2;++b)
            if(_springBreastNodes[b]!=UINT32_MAX)dc_model_set_node_extra(_actor.model,_springBreastNodes[b],0,NULL);
    }
    for(unsigned ex=0;ex<2;++ex) {
        uint8_t bIdx=_headBodyIndices[ex+1u];
        dc_game_model *bs=[self bodySlotAtIndex:bIdx];
        if(!bs||!bs->model)continue;
        if(_extraNeckNodes[ex]!=UINT32_MAX)dc_model_set_node_extra(bs->model,_extraNeckNodes[ex],0,NULL);
        for(unsigned b=0;b<2;++b)
            if(_extraSpringBreastNodes[ex][b]!=UINT32_MAX)dc_model_set_node_extra(bs->model,_extraSpringBreastNodes[ex][b],0,NULL);
    }
}
- (void)updateProceduralCharacterPoseWithCameraEye:(const float[3])cameraEye delta:(uint32_t)delta clip:(uint32_t)clip bypass:(BOOL)bypass {
    if(bypass||!((_sceneType>=4&&_sceneType<=7)||_sceneType==12)) {
        [self clearProceduralActorExtras];
        if(_face.model) {
            for(unsigned e=0;e<2;++e) {
                if(_eyeNodes[e]!=UINT32_MAX)dc_model_set_node_extra(_face.model,_eyeNodes[e],0,NULL);
                if(_eyeHighlightNodes[e]!=UINT32_MAX)dc_model_set_node_extra(_face.model,_eyeHighlightNodes[e],0,NULL);
            }
            for(unsigned h=0;h<6;++h)
                if(_hairSpringNodes[h]!=UINT32_MAX)dc_model_set_node_extra(_face.model,_hairSpringNodes[h],0,NULL);
        }
        for(unsigned ex=0;ex<2;++ex)if(_extraFaces[ex].model) {
            for(unsigned e=0;e<2;++e) {
                if(_extraEyeNodes[ex][e]!=UINT32_MAX)dc_model_set_node_extra(_extraFaces[ex].model,_extraEyeNodes[ex][e],0,NULL);
                if(_extraEyeHighlightNodes[ex][e]!=UINT32_MAX)dc_model_set_node_extra(_extraFaces[ex].model,_extraEyeHighlightNodes[ex][e],0,NULL);
            }
            for(unsigned h=0;h<6;++h)
                if(_extraHairSpringNodes[ex][h]!=UINT32_MAX)dc_model_set_node_extra(_extraFaces[ex].model,_extraHairSpringNodes[ex][h],0,NULL);
        }
        return;
    }
    float targetWorld[3]={cameraEye[0],cameraEye[1],cameraEye[2]};
    if((_sceneType==6||_sceneType==12||(_sceneType==7&&_type7State.gaze_mode[_headHeroines[0]]==0u))&&!_maleUserHidden&&_maleEyeTargetNode!=UINT32_MAX&&_actor.model) {
        dc_matrix maleTarget;
        if(dc_model_global(_actor.model,_maleEyeTargetNode,&maleTarget)==DC_OK) {
            targetWorld[0]=maleTarget.values[12];
            targetWorld[1]=maleTarget.values[13];
            targetWorld[2]=maleTarget.values[14];
        }
    }
    int32_t editMid=(_sceneType==12&&_editPlayer.cur_step>=0&&_editPlayer.cur_step<_editStateCopy.step_count)?_editStateCopy.steps[_editPlayer.cur_step].motion_id:6;
    BOOL climaxActive=NO;
    if(_sceneType==4)climaxActive=(clip==9u);
    else if(_sceneType==5)climaxActive=(clip>=180u&&clip<=193u)||(_watchScrubState==3u);
    else if(_sceneType==6)climaxActive=(clip==31u||clip==57u);
    else if(_sceneType==7)climaxActive=(_type7State.phase==DC_TYPE7_PHASE_CLIMAX_IN||_type7State.phase==DC_TYPE7_PHASE_CLIMAX_OUT||_type7State.phase==DC_TYPE7_PHASE_EDGE);
    else if(_sceneType==12)climaxActive=(editMid==30||editMid==31||editMid==32||editMid==33||editMid==60||editMid==61||editMid==62||editMid==70||editMid==71||editMid==72);
    uint32_t eyeRec=0u,neckRec=0u;
    if(_eyeNeckValid) {
        if(_sceneType==7) {
            uint8_t gm=_type7State.gaze_mode[_headHeroines[0]];
            if(climaxActive){eyeRec=0u;neckRec=0u;}
            else if(gm==2u){eyeRec=2u;neckRec=2u;}
            else if(gm==1u){eyeRec=1u;neckRec=1u;}
            else {
                BOOL shy=((_type7State.conquered_mask&(1u<<_headHeroines[0]))==0u&&_type7State.phase==DC_TYPE7_PHASE_IDLE);
                eyeRec=shy?2u:1u;neckRec=shy?2u:1u;
            }
        } else if(_sceneType==12) {
            if(climaxActive){eyeRec=0u;neckRec=0u;}
            else {
                uint8_t h0=_headHeroines[0]<3u?_headHeroines[0]:0u;
                BOOL shy=(_editStateCopy.personality[h0]==0&&editMid<=8);
                eyeRec=shy?2u:1u;neckRec=shy?2u:1u;
            }
        } else {
            BOOL neutralGaze=climaxActive||(_sceneType==6&&(clip==55u||clip==26u||clip==39u)&&_nightDragging);
            if(!neutralGaze) {
                BOOL shy=(_stageProgress==0u&&!_editMode&&!(_sceneType==6&&clip>=10u&&clip<=54u));
                eyeRec=shy?2u:1u;
                neckRec=shy?2u:1u;
            }
        }
        dc_eyeneck_controller_set_slot(&_neckController,&_neckSlots[neckRec]);
        for(unsigned e=0;e<2;++e)dc_eyeneck_controller_set_slot(&_eyeControllers[e],&_eyeSlots[eyeRec]);
    }
    dc_game_model *head0Body=(_sceneType==7||_sceneType==12)?[self bodySlotAtIndex:_headBodyIndices[0]]:&_actor;
    BOOL actorDirty=NO;
    if(head0Body&&head0Body->model) {
        if(_eyeNeckValid&&_neckNode!=UINT32_MAX) {
            dc_matrix neckWorld,neckExtra;
            if(dc_model_global(head0Body->model,_neckNode,&neckWorld)==DC_OK&&
               dc_eyeneck_controller_step(&_neckController,&neckWorld,targetWorld,0.f,delta,&neckExtra)==DC_OK) {
                dc_model_set_node_extra(head0Body->model,_neckNode,2,&neckExtra);
                actorDirty=YES;
            }
        }
        uint8_t h0=(_sceneType==7||_sceneType==12)?_headHeroines[0]:(uint8_t)_storyStage;
        uint32_t clothed=1u;
        if(_sceneType==7) {
            clothed=(h0==2u)?(_type7State.fuku_state[2][0]<2u?1u:0u):((_type7State.fuku_state[h0][0]<2u||_type7State.fuku_state[h0][1]<2u)?1u:0u);
        } else if(_sceneType==12) {
            clothed=(h0==2u)?(_editPlayer.cur_cloth[2][0]>0?1u:0u):((_editPlayer.cur_cloth[h0][0]>0||_editPlayer.cur_cloth[h0][1]>0)?1u:0u);
        } else {
            clothed=(_storyStage==2u)?(_clothingTopState<6u?1u:0u):((_clothingTopState<2u||_clothingBraState<2u)?1u:0u);
        }
        uint32_t locked=(h0==2u)?1u:0u;
        for(unsigned b=0;b<2;++b) {
            if(_springBreastNodes[b]==UINT32_MAX)continue;
            dc_matrix breastWorld,breastExtra;
            if(dc_model_global(head0Body->model,_springBreastNodes[b],&breastWorld)==DC_OK&&
               dc_spring_breast_step(&_breastSprings[b],&breastWorld,delta,clothed,locked,&breastExtra)==DC_OK) {
                dc_model_set_node_extra(head0Body->model,_springBreastNodes[b],2,&breastExtra);
                actorDirty=YES;
            }
        }
        if(actorDirty) {
            dc_model_refresh_pose(head0Body->model,&head0Body->world);
            if(_face.model)[self updateFaceAttachment];
            [self updateWatchAuxiliaryPlacement];
        }
    }
    if(_face.model) {
        for(unsigned e=0;e<2;++e) {
            if(_eyeNodes[e]!=UINT32_MAX)dc_model_set_node_extra(_face.model,_eyeNodes[e],0,NULL);
            if(_eyeHighlightNodes[e]!=UINT32_MAX)dc_model_set_node_extra(_face.model,_eyeHighlightNodes[e],0,NULL);
        }
        for(unsigned h=0;h<6;++h)
            if(_hairSpringNodes[h]!=UINT32_MAX)dc_model_set_node_extra(_face.model,_hairSpringNodes[h],0,NULL);
        dc_model_refresh_pose(_face.model,&_face.world);
        BOOL faceDirty=NO;
        if(_eyeNeckValid) {
            static const float kEyeConv[2]={-0.5f,0.5f};
            for(unsigned e=0;e<2;++e) {
                if(_eyeNodes[e]==UINT32_MAX)continue;
                dc_matrix eyeWorld,eyeExtra;
                if(dc_model_global(_face.model,_eyeNodes[e],&eyeWorld)==DC_OK&&
                   dc_eyeneck_controller_step(&_eyeControllers[e],&eyeWorld,targetWorld,kEyeConv[e],delta,&eyeExtra)==DC_OK) {
                    dc_model_set_node_extra(_face.model,_eyeNodes[e],2,&eyeExtra);
                    faceDirty=YES;
                }
            }
        }
        float arousal=0.f;
        if(_sceneType==5)arousal=_watchTouchGauge;
        else if(_sceneType==6)arousal=_nightExcitement;
        else if(_sceneType==7)arousal=_type7State.arousal[_headHeroines[0]]*100.f;
        else if(_sceneType==12)arousal=(editMid>=10)?75.f:((_editPlayer.vibe_mask!=0u)?65.f:20.f);
        else if(_sceneType==4&&_watchVibeSwitch)arousal=65.f;
        dc_matrix tremorExtra;
        if(dc_eyeneck_tremor_step(&_eyeTremor,delta,arousal,climaxActive?1u:0u,&tremorExtra)==DC_OK) {
            for(unsigned e=0;e<2;++e) {
                if(_eyeHighlightNodes[e]!=UINT32_MAX) {
                    dc_model_set_node_extra(_face.model,_eyeHighlightNodes[e],2,&tremorExtra);
                    faceDirty=YES;
                }
            }
        }
        for(unsigned h=0;h<6;++h) {
            if(_hairSpringNodes[h]==UINT32_MAX)continue;
            dc_matrix hairWorld,hairExtra;
            if(dc_model_global(_face.model,_hairSpringNodes[h],&hairWorld)==DC_OK&&
               dc_spring_hair_step(&_hairSprings[h],&hairWorld,delta,&hairExtra)==DC_OK) {
                dc_model_set_node_extra(_face.model,_hairSpringNodes[h],2,&hairExtra);
                faceDirty=YES;
            }
        }
        if(faceDirty)dc_model_refresh_pose(_face.model,&_face.world);
    }
    if(_sceneType==7||_sceneType==12) {
        static const float kEyeConv[2]={-0.5f,0.5f};
        for(unsigned ex=0;ex<_extraFaceCount&&ex<2u;++ex) {
            dc_game_model *fs=&_extraFaces[ex];
            dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[ex+1u]];
            uint8_t h=_headHeroines[ex+1u];
            if(!fs->model||!bs||!bs->model||h>=3u)continue;
            float exTarget[3]={cameraEye[0],cameraEye[1],cameraEye[2]};
            if((_sceneType==12||_type7State.gaze_mode[h]==0u)&&!_maleUserHidden&&_maleEyeTargetNode!=UINT32_MAX&&_actor.model) {
                dc_matrix maleTarget;
                if(dc_model_global(_actor.model,_maleEyeTargetNode,&maleTarget)==DC_OK) {
                    exTarget[0]=maleTarget.values[12];exTarget[1]=maleTarget.values[13];exTarget[2]=maleTarget.values[14];
                }
            }
            if(_extraEyeNeckValid[ex]) {
                uint8_t gm=(_sceneType==12)?1u:_type7State.gaze_mode[h];
                uint32_t er=climaxActive?0u:(gm==2u?2u:1u);
                dc_eyeneck_controller_set_slot(&_extraNeckController[ex],&_extraNeckSlots[ex][er]);
                for(unsigned e=0;e<2;++e)dc_eyeneck_controller_set_slot(&_extraEyeControllers[ex][e],&_extraEyeSlots[ex][er]);
            }
            BOOL bDirty=NO;
            if(_extraEyeNeckValid[ex]&&_extraNeckNodes[ex]!=UINT32_MAX) {
                dc_matrix nw,ne;
                if(dc_model_global(bs->model,_extraNeckNodes[ex],&nw)==DC_OK&&
                   dc_eyeneck_controller_step(&_extraNeckController[ex],&nw,exTarget,0.f,delta,&ne)==DC_OK) {
                    dc_model_set_node_extra(bs->model,_extraNeckNodes[ex],2,&ne);
                    bDirty=YES;
                }
            }
            uint32_t clothed=(_sceneType==12)?((h==2u)?(_editPlayer.cur_cloth[2][0]>0?1u:0u):((_editPlayer.cur_cloth[h][0]>0||_editPlayer.cur_cloth[h][1]>0)?1u:0u)):
                ((h==2u)?(_type7State.fuku_state[2][0]<2u?1u:0u):((_type7State.fuku_state[h][0]<2u||_type7State.fuku_state[h][1]<2u)?1u:0u));
            uint32_t locked=(h==2u)?1u:0u;
            for(unsigned b=0;b<2;++b) {
                if(_extraSpringBreastNodes[ex][b]==UINT32_MAX)continue;
                dc_matrix bw,be;
                if(dc_model_global(bs->model,_extraSpringBreastNodes[ex][b],&bw)==DC_OK&&
                   dc_spring_breast_step(&_extraBreastSprings[ex][b],&bw,delta,clothed,locked,&be)==DC_OK) {
                    dc_model_set_node_extra(bs->model,_extraSpringBreastNodes[ex][b],2,&be);
                    bDirty=YES;
                }
            }
            if(bDirty) {
                dc_model_refresh_pose(bs->model,&bs->world);
                [self updateExtraFaceAttachmentAtIndex:ex];
            }
            for(unsigned e=0;e<2;++e) {
                if(_extraEyeNodes[ex][e]!=UINT32_MAX)dc_model_set_node_extra(fs->model,_extraEyeNodes[ex][e],0,NULL);
                if(_extraEyeHighlightNodes[ex][e]!=UINT32_MAX)dc_model_set_node_extra(fs->model,_extraEyeHighlightNodes[ex][e],0,NULL);
            }
            for(unsigned hr=0;hr<6;++hr)
                if(_extraHairSpringNodes[ex][hr]!=UINT32_MAX)dc_model_set_node_extra(fs->model,_extraHairSpringNodes[ex][hr],0,NULL);
            dc_model_refresh_pose(fs->model,&fs->world);
            BOOL fDirty=NO;
            if(_extraEyeNeckValid[ex]) {
                for(unsigned e=0;e<2;++e) {
                    if(_extraEyeNodes[ex][e]==UINT32_MAX)continue;
                    dc_matrix ew,ee;
                    if(dc_model_global(fs->model,_extraEyeNodes[ex][e],&ew)==DC_OK&&
                       dc_eyeneck_controller_step(&_extraEyeControllers[ex][e],&ew,exTarget,kEyeConv[e],delta,&ee)==DC_OK) {
                        dc_model_set_node_extra(fs->model,_extraEyeNodes[ex][e],2,&ee);
                        fDirty=YES;
                    }
                }
            }
            float exArousal=(_sceneType==12)?((editMid>=10)?75.f:(((_editPlayer.vibe_mask&(1u<<(ex+1u)))!=0)?65.f:20.f)):(_type7State.arousal[h]*100.f);
            dc_matrix trExtra;
            if(dc_eyeneck_tremor_step(&_extraEyeTremor[ex],delta,exArousal,climaxActive?1u:0u,&trExtra)==DC_OK) {
                for(unsigned e=0;e<2;++e) {
                    if(_extraEyeHighlightNodes[ex][e]!=UINT32_MAX) {
                        dc_model_set_node_extra(fs->model,_extraEyeHighlightNodes[ex][e],2,&trExtra);
                        fDirty=YES;
                    }
                }
            }
            for(unsigned hr=0;hr<6;++hr) {
                if(_extraHairSpringNodes[ex][hr]==UINT32_MAX)continue;
                dc_matrix hw,he;
                if(dc_model_global(fs->model,_extraHairSpringNodes[ex][hr],&hw)==DC_OK&&
                   dc_spring_hair_step(&_extraHairSprings[ex][hr],&hw,delta,&he)==DC_OK) {
                    dc_model_set_node_extra(fs->model,_extraHairSpringNodes[ex][hr],2,&he);
                    fDirty=YES;
                }
            }
            if(fDirty)dc_model_refresh_pose(fs->model,&fs->world);
        }
    }
}
- (void)applyOutfitVariant:(uint32_t)variant {
    /* Original 0x5181f0-style outfit selection through hidden alternate
     * outfit meshes. Variant 1 shows the skirt set instead of the dress,
     * variant 2 removes the bra, variant 3 removes the panties; any other
     * variant restores the default visibility. */
    uint32_t v=variant&3u;
    if(v<2u||!_loaded) {
        _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
    }
    if(v==0u) {
        _clothingTopState=(_sceneType==6&&_storyStage==2)?6u:0u;
        _clothingBraState=0u;
        _clothingSkirtState=(_sceneType==6)?3u:0u;
        _clothingPantyState=0u;
    } else if(v==1u) {
        _clothingTopState=(_storyStage==2)?8u:2u;
        _clothingBraState=0u;
        _clothingSkirtState=(_sceneType==6)?3u:0u;
        _clothingPantyState=0u;
    } else if(v==2u) {
        _clothingTopState=(_storyStage==2)?8u:2u;
        _clothingBraState=2u;
        _clothingSkirtState=4u;
        _clothingPantyState=(_watchNekoVibeVisible||_watchToriVibeVisible)?2u:0u;
    } else {
        _clothingTopState=(_storyStage==2)?8u:2u;
        _clothingBraState=2u;
        _clothingSkirtState=4u;
        _clothingPantyState=(_sceneType==6)?3u:4u;
    }
    [self syncLegacyClothingSummary];
    _outfitVariant=v;
    [self applyClothingVisibility];
    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
    if(!_loaded||!_naturalGameplayRoute) {
        _storyPhase=0;_interactionCompleted=NO;_chapterEndAction=0;
    }
}
- (BOOL)editMode { return _editMode; }
- (void)setEditMode:(BOOL)editMode {
    _editMode=editMode;
    _editPaused=NO;_editPauseStopRequested=NO;_editSpeedMode=0;
    if(editMode){_storyPhase=0;_playerSaveDirty=NO;}
    [self applyMapLayerVisibility];
}

- (NSString *)decodedName:(const uint8_t *)raw length:(size_t)length {
    if (!raw || !length || length > 1024) return nil;
    char decoded[1025];
    size_t count=0;
    while(count<length && raw[count]!=255 && raw[count]!=0) {
        decoded[count]=(char)(raw[count]^255);
        if (!decoded[count]) break;
        ++count;
    }
    if (!count) return @"";
    return [[NSString alloc] initWithBytes:decoded length:count encoding:NSASCIIStringEncoding];
}

- (uint32_t)findNode:(dc_game_model *)slot name:(NSString *)name {
    if (!slot->xx || !name.length) return UINT32_MAX;
    for(uint32_t i=0;i<slot->info.nodes;++i) {
        dc_xx_node node;
        if(dc_xx_node_at(slot->xx,i,&node)!=DC_OK) continue;
        NSString *decoded=[self decodedName:(const uint8_t *)slot->xxData.bytes+node.name.offset length:node.name.length];
        if([decoded isEqualToString:name]) return i;
    }
    return UINT32_MAX;
}

- (BOOL)updateFaceAttachment {
    dc_game_model *bs=(_sceneType==7||_sceneType==12)?[self bodySlotAtIndex:_headBodyIndices[0]]:&_actor;
    dc_matrix target;
    return bs && bs->model && _actorHeadNode!=UINT32_MAX &&
        dc_model_global(bs->model,_actorHeadNode,&target)==DC_OK &&
        dc_matrix_multiply(&_faceBindInverse,&target,&_face.world)==DC_OK;
}
- (BOOL)updateExtraFaceAttachmentAtIndex:(uint32_t)ex {
    if(ex>=2u||!_extraFaces[ex].model)return YES;
    dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[ex+1u]];
    dc_matrix target;
    return bs && bs->model && _extraActorHeadNodes[ex]!=UINT32_MAX &&
        dc_model_global(bs->model,_extraActorHeadNodes[ex],&target)==DC_OK &&
        dc_matrix_multiply(&_extraFaceBindInverses[ex],&target,&_extraFaces[ex].world)==DC_OK;
}

- (void)applyInitialVisibility {
    // Original 0x5181f0 / 0x4b8340 hides alternate outfits and facial effect meshes.
    NSArray<NSString *> *actorNames=@[@"a_On_wanpiHEC",@"a_On_wanpiEHM",@"a_On_wanpiHHM",
        @"a_On_wanpiEHU",@"a_On_wanpiHHU",@"a_On_wanpiHHC",
        @"a_On_wanpiHHC_U",@"a_On_wanpiHEC_U",
        @"a_On_wanpiEHM_U",@"a_On_wanpiHHM_U",@"a_On_wanpiEHU_U",@"a_On_wanpiHHU_U",
        @"a_On_skartHF",@"a_On_skartHB",@"a_On_buraH",@"a_On_buraH_U",
        @"a_On_skartHF_U",@"a_On_skartHB_U",
        @"a_On_pantuH",@"a_On_pantuH1",@"a_On_pantuH2",@"a_On_pantuH2_U",@"a_On_pantuH3",@"a_On_pantuH3_U",@"a_On_pantuH4",@"a_On_pantuH4_U",
        @"a_On_neko_vive",@"a_On_tori_vive",
        @"a_On_mata_siru",@"a_On_kokan_siru",
        @"a_On_tejou_L",@"a_On_tejou_R",
        @"b_Nn_seraH_OBJ",@"b_On_seraH_O",@"b_On_seraH_U",@"b_On_eriH_O",@"b_On_eriH_U",@"b_On_shatuH",@"b_On_shatuH_U",@"b_On_nekuH_R",
        @"b_On_skartHF",@"b_On_skartHF_U",@"b_On_skartHB",@"b_On_skartHB_U",
        @"b_On_buraH",@"b_On_buraH_U",
        @"b_On_pantuH1",@"b_On_pantuH2",@"b_On_pantuH2_U",@"b_On_pantuH3",@"b_On_pantuH3_U",@"b_On_pantuH4",@"b_On_pantuH4_U",
        @"b_On_neko_vive",@"b_On_tori_vive",
        @"b_On_mata_siru",@"b_On_kokan_siru",
        @"b_On_houtyou",@"b_On_himoUL",@"b_On_himoUR",@"b_On_himoAL",@"b_On_himoAR",@"s_On_chi_moto",
        @"c_On_buraH",@"c_On_buraH_U",@"c_On_pantuH1",@"c_On_pantuH2",@"c_On_pantuH2_U",@"c_On_pantuH3",@"c_On_pantuH3_U",@"c_On_pantuH4",@"c_On_pantuH4_U",
        @"c_On_uwagiH",@"c_On_uwagiH_U",
        @"c_On_skartHB",@"c_On_skartHB_U",@"c_On_skartHF",@"c_On_skartHF_U",
        @"c_On_neko_vive",@"c_On_tori_vive",
        @"c_On_mata_siru",@"c_On_kokan_siru",
        @"c_On_tejou_L",@"c_On_tejou_R",
        @"b_On_tare_small",@"b_On_tare_big",@"b_On_tare2_small",@"b_On_tare2_big",
        @"b_On_tare_small2",@"b_On_tare_big2",@"b_On_tare2_small2",@"b_On_tare2_big2",
        @"s_Kn_asokoX",@"s_On_omozaX1",@"s_On_omozaX2",@"s_On_omozaX3",@"s_On_omozaX4",@"s_On_omozaX5",@"s_On_omozaX6",
        @"z_Nn_siru",@"s_On_siru_1",@"s_On_siru_2",@"s_On_siru_3",@"s_On_siru_4",@"s_On_siru_5",@"s_On_siru_6"];
    NSArray<NSString *> *dayOnlyHidden=@[@"a_On_wanpiEHC",@"a_On_wanpiEHC_U",
        @"a_On_skartHA",@"a_On_skartHA_U",@"b_On_skartHA",@"b_On_skartHA_U",@"c_On_skartHA",@"c_On_skartHA_U"];
    NSArray<NSString *> *legHidden=(_sceneType==6 && _storyStage==0)
        ? @[@"b_On_kutu_L",@"b_On_kutu_R"]
        : @[@"a_On_sune_L",@"a_On_sune_R"];
    NSArray<NSString *> *faceNames=@[@"a_On_nekomimi",@"a_On_kuchsiru_F",@"a_On_kuchsiru_ita",
        @"a_On_kuchsiru_o",@"a_On_kuchsiru_u",@"a_On_namida",@"b_On_long"];
    for(NSString *name in actorNames){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    if(_sceneType!=6)for(NSString *name in dayOnlyHidden){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    for(NSString *name in legHidden){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    for(NSString *name in faceNames){uint32_t node=[self findNode:&_face name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_face.model,node,1);}
    if(_tearVisible&&_face.model) {
        uint32_t tearNode=[self findNode:&_face name:[self characterNode:@"a_On_namida"]];
        if(tearNode!=UINT32_MAX)dc_model_hide_node(_face.model,tearNode,0);
    }
    if(_stageProgress>=4u&&!_editMode&&_naturalGameplayRoute&&_face.model) {
        for(NSString *name in @[@"a_On_mehi_L",@"a_On_mehi_R"]) {
            uint32_t node=[self findNode:&_face name:[self characterNode:name]];
            if(node!=UINT32_MAX)dc_model_hide_node(_face.model,node,1);
        }
    }
    [self applyMapLayerVisibility];
}

- (void)computeActorFloorOffset {
    _actorRootFloorOffset=0;
    if(dc_model_tick(_actor.model,0,0,&_actor.world)!=DC_OK)return;
    float lowest=FLT_MAX;
    for(uint32_t i=0;i<_actor.info.submeshes;++i) {
        uint32_t visible=0,space=0;dc_xx_submesh mesh;dc_matrix global;dc_material_value material;
        if(dc_model_mesh_visible(_actor.model,i,&visible)!=DC_OK||!visible||
           dc_model_mesh(_actor.model,i,&mesh)!=DC_OK||dc_model_material(_actor.model,mesh.material,&material)!=DC_OK||material.components[3]<=0||
           dc_model_vertex_space(_actor.model,i,&space)!=DC_OK||dc_model_global(_actor.model,mesh.node,&global)!=DC_OK)continue;
        dc_mesh_vertex *vertices=calloc(mesh.vertex_count?mesh.vertex_count:1,sizeof(*vertices));
        if(!vertices)continue;
        if(dc_model_load_vertices(_actor.model,i,vertices,mesh.vertex_count)==DC_OK) {
            for(uint32_t j=0;j<mesh.vertex_count;++j){float *p=vertices[j].position;
                float y=space==DC_MODEL_SPACE_WORLD?p[1]:p[0]*global.values[1]+p[1]*global.values[5]+p[2]*global.values[9]+global.values[13];
                lowest=fminf(lowest,y);
            }
        }
        free(vertices);
    }
    float floorY;
    if(lowest!=FLT_MAX && [self surfaceYAtX:_actor.world.values[12] z:_actor.world.values[14] nearY:lowest result:&floorY])
        _actorRootFloorOffset=_actor.world.values[13]-floorY;
}

- (BOOL)movePlayerTo:(const dc_game_player *)next {
    float currentFloor=_actorOriginY-_actorRootFloorOffset,floorY;
    if(![self surfaceYAtX:next->x z:next->z nearY:currentFloor result:&floorY] || fabsf(floorY-currentFloor)>2.f)return NO;
    _player=*next;_playerSaveDirty=YES;
#if DEBUG
    if([NSProcessInfo.processInfo.environment[@"PORTLAB_RENDER_PROBE"] isEqualToString:@"1"]) {
        _actor.world.values[12]=next->x;_actor.world.values[14]=next->z;
        _actor.world.values[13]=floorY+_actorRootFloorOffset;
    }
#endif
    return YES;
}

- (uint32_t)placementNodeFromPLST:(NSData *)data model:(dc_game_model *)slot {
    return [self placementNodeFromPLST:data model:slot prefix:0];
}
- (uint32_t)placementNodeFromPLST:(NSData *)data model:(dc_game_model *)slot prefix:(char)prefix {
    if(!data || data.length<9 || !slot || !slot->xx) return UINT32_MAX;
    const uint8_t *bytes=data.bytes;
    uint32_t recCount=0;memcpy(&recCount,bytes,sizeof(recCount));
    if(recCount==0||recCount>16)recCount=1;
    size_t cursor=4;
    for(uint32_t r=0;r<recCount&&cursor<data.length;++r) {
        cursor+=1; /* 1-byte variant */
        NSString *strs[4]={nil,nil,nil,nil};
        BOOL ok=YES;
        for(unsigned s=0;s<4;++s) {
            if(cursor+4>data.length){ok=NO;break;}
            uint32_t length=0;memcpy(&length,bytes+cursor,sizeof(length));cursor+=4;
            if(length>1024||cursor+length>data.length){ok=NO;break;}
            strs[s]=length?[self decodedName:bytes+cursor length:length]:@"";
            cursor+=length;
        }
        if(!ok)break;
        if(cursor+8<=data.length)cursor+=8; /* 8-byte record tail */
        if(prefix!=0&&strs[0].length>0&&(char)[strs[0] characterAtIndex:0]!=prefix)continue;
        for(int s=3;s>=0;--s) {
            if(!strs[s].length)continue;
            uint32_t node=[self findNode:slot name:strs[s]];
            if(node!=UINT32_MAX)return node;
        }
    }
    return UINT32_MAX;
}

- (NSData *)entry:(NSString *)name archive:(DCArchive *)archive error:(NSString **)error {
    for(uint32_t i=0;i<archive.entryCount;++i)
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame)
            return [archive readEntryAtIndex:i limit:128*1024*1024 error:nil];
    if(error)*error=[NSString stringWithFormat:@"Missing game resource %@",name];
    return nil;
}
- (NSData *)lightEntryForSelector:(uint32_t)selector archive:(DCArchive *)archive {
    NSArray<NSString *> *suffixes=(_sceneType==6||_sceneType==7)?@[@"_02.xl",@"_01.xl"]:@[@"_01.xl",@"_02.xl"];
    NSString *prefix=[NSString stringWithFormat:@"pp%02u",selector];
    for(NSString *suffix in suffixes) {
        for(uint32_t i=0;i<archive.entryCount;++i) {
            NSString *name=[archive asciiNameAtIndex:i];
            if(!name || ![name.lowercaseString hasPrefix:prefix.lowercaseString] ||
               ![name.lowercaseString hasSuffix:suffix.lowercaseString]) continue;
            NSData *found=[archive readEntryAtIndex:i limit:128*1024 error:nil];
            if(found)return found;
        }
    }
    return nil;
}
- (BOOL)loadLightForSelector:(uint32_t)selector archive:(DCArchive *)archive error:(NSString **)error {
    NSData *data=[self lightEntryForSelector:selector archive:archive];
    if(!data) { if(error)*error=[NSString stringWithFormat:@"Missing XL light resource for map %u",selector]; return NO; }
    dc_xl_info info;dc_xl_light light;
    if(dc_xl_probe(data.bytes,data.length,&info)!=DC_OK || !info.lights ||
       dc_xl_light_at(data.bytes,data.length,0,&light)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"XL light resource rejected for map %u",selector];
        return NO;
    }
    _lightData=data;_lightInfo=info;_mapLight=light;
    _charD3DLightCount=MIN(info.lights,8u);
    if(dc_xl_ambient(data.bytes,data.length,_charGlobalAmbient)!=DC_OK) {
        _charGlobalAmbient[0]=_charGlobalAmbient[1]=_charGlobalAmbient[2]=0.298f;
    }
    for(uint32_t k=0;k<_charD3DLightCount;++k)
        dc_xl_d3d_light_at(data.bytes,data.length,k,&_charD3DLights[k]);
    return YES;
}
- (BOOL)loadMapVariantLightForSelector:(uint32_t)selector archive:(DCArchive *)archive error:(NSString **)error {
    NSString *name=[NSString stringWithFormat:@"mp00_%02u.xl",selector];
    NSData *data=[self entry:name archive:archive error:error];
    if(!data)return NO;
    dc_xl_info info;dc_xl_light light;
    if(dc_xl_probe(data.bytes,data.length,&info)!=DC_OK || !info.lights ||
       dc_xl_light_at(data.bytes,data.length,0,&light)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Map XL light resource rejected for map %u",selector];
        return NO;
    }
    _mapVariantLightData=data;_mapVariantLightInfo=info;_mapVariantLight=light;
    _mapD3DLightCount=MIN(info.lights,8u);
    if(dc_xl_ambient(data.bytes,data.length,_mapGlobalAmbient)!=DC_OK) {
        _mapGlobalAmbient[0]=_mapGlobalAmbient[1]=_mapGlobalAmbient[2]=0.3f;
    }
    for(uint32_t k=0;k<_mapD3DLightCount;++k)
        dc_xl_d3d_light_at(data.bytes,data.length,k,&_mapD3DLights[k]);
    return YES;
}
- (BOOL)encodedSpan:(dc_eyeneck_span)span matchesName:(NSString *)name data:(NSData *)data {
    NSData *plain=[name dataUsingEncoding:NSASCIIStringEncoding];
    if(!plain || span.length!=plain.length || span.offset>data.length || span.length>data.length-span.offset)return NO;
    const uint8_t *raw=(const uint8_t *)data.bytes+span.offset;const uint8_t *expected=plain.bytes;
    for(NSUInteger i=0;i<span.length;++i)if((uint8_t)(expected[i]^255u)!=raw[i])return NO;
    return YES;
}
- (BOOL)openModel:(dc_game_model *)slot staticOnly:(BOOL)staticOnly error:(NSString **)error {
    dc_status status=staticOnly ? dc_model_open_static(slot->xxData.bytes,slot->xxData.length,&slot->model)
        : dc_model_open(slot->xxData.bytes,slot->xxData.length,slot->xaData.bytes,slot->xaData.length,&slot->model);
    if(status!=DC_OK) { if(error)*error=[NSString stringWithFormat:@"Game model open failed: %d",status]; return NO; }
    status=dc_xx_open(slot->xxData.bytes,slot->xxData.length,&slot->xx);
    if(status==DC_OK)status=dc_model_get_info(slot->model,&slot->info);
    if(status==DC_OK && slot->xaData)
        status=dc_xa_probe(slot->xaData.bytes,slot->xaData.length,&slot->xaInfo);
    if(status!=DC_OK || slot->info.textures>256) { if(error)*error=@"Game model profile rejected"; return NO; }
    slot->textureCount=slot->info.textures;
    slot->textures=calloc(slot->textureCount,sizeof(uintptr_t));
    slot->baseTextures=calloc(slot->textureCount,sizeof(uintptr_t));
    if(slot->textureCount && (!slot->textures || !slot->baseTextures)) { if(error)*error=@"Game texture handle allocation failed"; return NO; }
    for(uint32_t i=0;i<slot->textureCount;++i) {
        dc_image_info info;status=dc_xx_image_probe(slot->xx,i,&info);
        if(status!=DC_OK || info.rgba_bytes>64*1024*1024) { if(error)*error=@"Game texture profile rejected"; return NO; }
        NSMutableData *pixels=[NSMutableData dataWithLength:info.rgba_bytes];
        status=dc_xx_image_decode(slot->xx,i,pixels.mutableBytes,pixels.length,&info);
        if(status!=DC_OK) {
            if(error)*error=[NSString stringWithFormat:@"Game texture %u decode failed: status=%d",i,status];
            return NO;
        }
        status=dc_vk_sprite_upload(_renderer,info.width,info.height,pixels.bytes,pixels.length,&slot->baseTextures[i]);
        if(status!=DC_OK) {
            if(error)*error=[NSString stringWithFormat:@"Game texture %u upload failed (%ux%u, %zu bytes): status=%d, %s",
                i,info.width,info.height,(size_t)pixels.length,status,dc_vk_sprite_error(_renderer)];
            return NO;
        }
        slot->textures[i]=slot->baseTextures[i];
    }
    slot->world=gameIdentity();
    return YES;
}
- (uint32_t)findAnchor:(dc_game_model *)slot {
    NSString *prefix = _sceneType==5 ? @"p" : (_sceneType==6 ? @"r" : @"l");
    BOOL touchExercise=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"];
    BOOL renderProbe=[NSProcessInfo.processInfo.environment[@"PORTLAB_RENDER_PROBE"] isEqualToString:@"1"];
    BOOL naturalAnchor=(!_editMode&&_naturalGameplayRoute&&!touchExercise&&!renderProbe&&!_captureGameplayFrame);
    BOOL shuffleFree=(naturalAnchor&&(_sceneType==4||(_sceneType==5&&(_storyChapter>=24u||_stageProgress>0u))));
    _cameraPreset=0u;
    if(shuffleFree) {
        char choices[3]={'a','b','c'};
        for(unsigned swap=0;swap<6;++swap) {
            unsigned j=arc4random_uniform(3u);
            char tmp=choices[swap%3u];choices[swap%3u]=choices[j];choices[j]=tmp;
        }
        for(unsigned k=0;k<3;++k) {
            NSString *cand=[NSString stringWithFormat:@"m_Nn_yuka_%@_%c",prefix,choices[k]];
            uint32_t cNode=[self findNode:slot name:cand];
            if(cNode!=UINT32_MAX){
                _anchorName=cand;
                _cameraPreset=(uint32_t)(choices[k]-'a');
                return cNode;
            }
        }
    }
    NSString *stage = [NSString stringWithFormat:@"%c", _characterPrefix];
    NSString *name = [NSString stringWithFormat:@"m_Nn_yuka_%@_%@", prefix, stage];
    uint32_t node=[self findNode:slot name:name];
    if(node!=UINT32_MAX){
        _anchorName=name;
        if(naturalAnchor&&(_sceneType==4||_sceneType==5)&&_characterPrefix>='a'&&_characterPrefix<='c')
            _cameraPreset=(uint32_t)(_characterPrefix-'a');
        return node;
    }
    if(_sceneType==6 && (_mapSelector==0 || _mapSelector==1)) {
        uint32_t hNode=[self findNode:slot name:@"m_Nn_yuka_5_a"];
        if(hNode!=UINT32_MAX){_anchorName=@"m_Nn_yuka_5_a";return hNode;}
    }
    dc_game_map_presentation profile;
    if(dc_game_map_presentation_profile(_mapSelector,&profile)!=DC_OK)return UINT32_MAX;
    return [self findNode:slot name:[NSString stringWithUTF8String:profile.anchor]];
}
- (void)computeWalkBounds {
    dc_matrix identity=gameIdentity();
    if(dc_model_tick(_map.model,0,0,&identity)!=DC_OK) {
        _walkMinX=-100;_walkMaxX=100;_walkMinZ=-100;_walkMaxZ=100;return;
    }
    free(_surfaces);_surfaces=NULL;_surfaceCount=0;_surfaceCapacity=0;
    _walkMinX=FLT_MAX;_walkMaxX=-FLT_MAX;_walkMinZ=FLT_MAX;_walkMaxZ=-FLT_MAX;
    for(uint32_t i=0;i<_map.info.submeshes;++i) {
        dc_xx_submesh mesh;uint32_t visible=0;
        if(dc_model_mesh(_map.model,i,&mesh)!=DC_OK || dc_model_mesh_visible(_map.model,i,&visible)!=DC_OK || !visible)continue;
        dc_matrix global;if(dc_model_global(_map.model,mesh.node,&global)!=DC_OK)continue;
        dc_mesh_vertex *vertices=calloc(mesh.vertex_count?mesh.vertex_count:1,sizeof(*vertices));
        if(!vertices || dc_model_load_vertices(_map.model,i,vertices,mesh.vertex_count)!=DC_OK){free(vertices);continue;}
        uint16_t *indices=calloc(mesh.index_count?mesh.index_count:1,sizeof(*indices));
        if(!indices || dc_xx_load_mesh_indices(_map.xx,i,indices,mesh.index_count)!=DC_OK){free(indices);free(vertices);continue;}
        for(uint32_t j=0;j<mesh.vertex_count;++j) {
            float x=vertices[j].position[0]*global.values[0]+vertices[j].position[1]*global.values[4]+vertices[j].position[2]*global.values[8]+global.values[12];
            float z=vertices[j].position[0]*global.values[2]+vertices[j].position[1]*global.values[6]+vertices[j].position[2]*global.values[10]+global.values[14];
            _walkMinX=fminf(_walkMinX,x);_walkMaxX=fmaxf(_walkMaxX,x);_walkMinZ=fminf(_walkMinZ,z);_walkMaxZ=fmaxf(_walkMaxZ,z);
        }
        for(uint32_t j=0;j+2<mesh.index_count;j+=3) {
            uint16_t ia=indices[j],ib=indices[j+1],ic=indices[j+2];if(ia>=mesh.vertex_count||ib>=mesh.vertex_count||ic>=mesh.vertex_count)continue;
            float p[3][3];uint16_t ids[3]={ia,ib,ic};
            for(unsigned k=0;k<3;++k){dc_mesh_vertex *v=&vertices[ids[k]];p[k][0]=v->position[0]*global.values[0]+v->position[1]*global.values[4]+v->position[2]*global.values[8]+global.values[12];p[k][1]=v->position[0]*global.values[1]+v->position[1]*global.values[5]+v->position[2]*global.values[9]+global.values[13];p[k][2]=v->position[0]*global.values[2]+v->position[1]*global.values[6]+v->position[2]*global.values[10]+global.values[14];}
            float ux=p[1][0]-p[0][0],uy=p[1][1]-p[0][1],uz=p[1][2]-p[0][2],vx=p[2][0]-p[0][0],vy=p[2][1]-p[0][1],vz=p[2][2]-p[0][2];
            float normalY=uz*vx-ux*vz;if(fabsf(normalY)<.2f)continue;
            if(_surfaceCount==_surfaceCapacity){size_t next=_surfaceCapacity?_surfaceCapacity*2:1024;dc_walk_surface *grown=realloc(_surfaces,next*sizeof(*grown));if(!grown){free(indices);free(vertices);return;}_surfaces=grown;_surfaceCapacity=next;}
            dc_walk_surface *surface=&_surfaces[_surfaceCount++];for(unsigned k=0;k<3;++k){surface->x[k]=p[k][0];surface->y[k]=p[k][1];surface->z[k]=p[k][2];}
        }
        free(indices);
        free(vertices);
    }
    if(!isfinite(_walkMinX)||!isfinite(_walkMaxX)||_walkMinX>=_walkMaxX){_walkMinX=-100;_walkMaxX=100;}
    if(!isfinite(_walkMinZ)||!isfinite(_walkMaxZ)||_walkMinZ>=_walkMaxZ){_walkMinZ=-100;_walkMaxZ=100;}
    float margin=1.0f;_walkMinX+=margin;_walkMaxX-=margin;_walkMinZ+=margin;_walkMaxZ-=margin;
    uint32_t savedInteractions=_player.interaction_count,savedMap=_player.map_selector;_player=(dc_game_player){.x=_actor.world.values[12],.z=_actor.world.values[14],.min_x=_walkMinX,.max_x=_walkMaxX,.min_z=_walkMinZ,.max_z=_walkMaxZ,.speed=8,.interaction_count=savedInteractions,.map_selector=savedMap};
    _interactionState.interaction_count=savedInteractions;
}
- (NSString *)writableStateDirectory {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *stdDir = _directory.stringByStandardizingPath;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (stdDir.length && (!bundlePath.length || ![stdDir hasPrefix:bundlePath]) && [fm isWritableFileAtPath:stdDir]) {
        return _directory;
    }
    NSString *docsRoot = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docsRoot.length) {
        NSString *writable = [docsRoot stringByAppendingPathComponent:@"game/Data"];
        [fm createDirectoryAtPath:writable withIntermediateDirectories:YES attributes:nil error:nil];
        return writable;
    }
    return _directory ?: @"";
}
- (void)loadPlayerState {
    NSString *writablePath=[[self writableStateDirectory] stringByAppendingPathComponent:@"save/player.state"];
    NSString *path=[NSFileManager.defaultManager fileExistsAtPath:writablePath]?writablePath:[_directory stringByAppendingPathComponent:@"save/player.state"];
    NSData *data=[NSData dataWithContentsOfFile:path];if(data.length<DC_GAME_PLAYER_SAVE_BYTES)return;
    dc_game_player loaded;if(dc_game_player_load(data.bytes,data.length,&loaded)!=DC_OK)return;
    if(loaded.map_selector!=_mapSelector)return;
    float floor;
    if(![self surfaceYAtX:loaded.x z:loaded.z nearY:_actor.world.values[13]-_actorRootFloorOffset result:&floor])return;
    _player.x=fmaxf(_player.min_x,fminf(_player.max_x,loaded.x));_player.z=fmaxf(_player.min_z,fminf(_player.max_z,loaded.z));
    if(loaded.speed>0)_player.speed=loaded.speed;
    _player.interaction_count=loaded.interaction_count;_player.map_selector=_mapSelector;
    _interactionCount=loaded.interaction_count;_interactionCompleted=loaded.interaction_count>0;
    _interactionState=(dc_game_interaction_state){.interaction_count=loaded.interaction_count,.completed=loaded.interaction_count>0};
#if DEBUG
    if([NSProcessInfo.processInfo.environment[@"PORTLAB_RENDER_PROBE"] isEqualToString:@"1"]) {
        _actor.world.values[12]=_player.x;_actor.world.values[14]=_player.z;
        _actor.world.values[13]=floor+_actorRootFloorOffset;
    }
#endif
    _resumedPlayer=YES;
}
- (BOOL)savePlayerState {
    if(!_playerSaveDirty||_editMode)return YES;
    NSMutableData *data=[NSMutableData dataWithLength:DC_GAME_PLAYER_SAVE_BYTES];
    if(dc_game_player_save(&_player,data.mutableBytes,data.length)!=DC_OK)return NO;
    NSString *writableDir=[self writableStateDirectory];
    NSString *path=[writableDir stringByAppendingPathComponent:@"save/player.state"];
    NSData *existing=[NSData dataWithContentsOfFile:path];
    if(!existing)existing=[NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:@"save/player.state"]];
    NSMutableData *combined=[NSMutableData dataWithData:data];
    if(existing.length>DC_GAME_PLAYER_SAVE_BYTES)
        [combined appendBytes:(const uint8_t *)existing.bytes+DC_GAME_PLAYER_SAVE_BYTES length:existing.length-DC_GAME_PLAYER_SAVE_BYTES];
    NSString *directory=[writableDir stringByAppendingPathComponent:@"save"];[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL saved=[combined writeToFile:path options:NSDataWritingAtomic error:nil];
    if(saved)_playerSaveDirty=NO;
    return saved;
}
- (BOOL)surfaceYAtX:(float)x z:(float)z nearY:(float)nearY result:(float *)result {
    BOOL found=NO;float best=0,bestDistance=FLT_MAX;
    for(size_t i=0;i<_surfaceCount;++i){dc_walk_surface *s=&_surfaces[i];float den=(s->z[1]-s->z[2])*(s->x[0]-s->x[2])+(s->x[2]-s->x[1])*(s->z[0]-s->z[2]);if(fabsf(den)<1e-5f)continue;float a=((s->z[1]-s->z[2])*(x-s->x[2])+(s->x[2]-s->x[1])*(z-s->z[2]))/den;float b=((s->z[2]-s->z[0])*(x-s->x[2])+(s->x[0]-s->x[2])*(z-s->z[2]))/den;float c=1-a-b;if(a<-.01f||b<-.01f||c<-.01f)continue;float y=a*s->y[0]+b*s->y[1]+c*s->y[2],distance=fabsf(y-nearY);if(distance<bestDistance){bestDistance=distance;best=y;found=YES;}}
    if(found&&result)*result=best;return found;
}
- (uint32_t)projectedTrianglesForModel:(dc_model *)model camera:(const dc_camera_matrices *)camera viewport:(const dc_viewport *)viewport {
    dc_xx_info info;if(dc_model_get_info(model,&info)!=DC_OK)return 0;
    uint32_t triangles=0;
    for(uint32_t meshIndex=0;meshIndex<info.submeshes;++meshIndex) {
        dc_xx_submesh mesh;uint32_t visible=0;size_t written=0;
        if(dc_model_mesh(model,meshIndex,&mesh)!=DC_OK||dc_model_mesh_visible(model,meshIndex,&visible)!=DC_OK||!visible)continue;
        if(dc_model_project_clipped(model,meshIndex,&camera->view_projection,viewport,0xffffffff,NULL,0,&written)!=DC_OK)continue;
        triangles+=(uint32_t)(written/3);
    }
    return triangles;
}
- (int32_t)motionHitIndexAtX:(float)x y:(float)y width:(uint32_t)width height:(uint32_t)height {
    if(!_actor.model||!isfinite(x)||!isfinite(y)||!width||!height)return -1;
    float scale=fminf((float)width/1024.f,(float)height/768.f);
    float px=((x+1)*.5f*width-(width-1024*scale)*.5f)/scale;
    float py=((1-y)*.5f*height-(height-768*scale)*.5f)/scale;
    if(px<0.f||px>1024.f||py<0.f||py>768.f)return -1;
    dc_camera_orbit orbit=[self activeCameraOrbit];dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices camera;
    if(dc_camera_build(&orbit,&lens,&camera)!=DC_OK)return -1;
    BOOL touchExercise=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"];
    BOOL syntheticProbe=(!_naturalGameplayRoute||touchExercise);
    float eyeX=camera.world.values[12],eyeY=camera.world.values[13],eyeZ=camera.world.values[14];
    static const float kTargetRadius[7]={180.f,150.f,150.f,225.f,225.f,150.f,150.f};
    float targetSX[7],targetSY[7],targetW[7],targetDist3D[7],targetScaledR[7];
    BOOL targetValid[7]={NO};
    BOOL anyValid=NO;
    for(unsigned t=0;t<7;++t) {
        dc_game_model *slot=(t==0&&_face.model)?&_face:&_actor;
        uint32_t node=_targetNodes[t];
        if(t==0&&node==UINT32_MAX){slot=&_actor;node=_actorHeadNode;}
        else if(t==3&&_sceneType==5&&[self isOuterClothingUndisplacedForWatchPart:3]&&_skirtTargetNodes[0]!=UINT32_MAX)node=_skirtTargetNodes[0];
        else if(t==4&&_sceneType==5&&[self isOuterClothingUndisplacedForWatchPart:4]&&_skirtTargetNodes[1]!=UINT32_MAX)node=_skirtTargetNodes[1];
        dc_matrix g;
        if(!slot->model||node==UINT32_MAX||dc_model_global(slot->model,node,&g)!=DC_OK)continue;
        float lz=(t==3)?1.0f:((t==4)?-1.0f:0.f);
        float pos[4]={g.values[12]+lz*g.values[8],g.values[13]+lz*g.values[9],g.values[14]+lz*g.values[10],1.f},clip[4];
        for(unsigned c=0;c<4;++c) {
            float sum=0.f;
            for(unsigned k=0;k<4;++k)sum+=pos[k]*camera.view_projection.values[k*4+c];
            clip[c]=sum;
        }
        if(!isfinite(clip[3])||clip[3]<=1e-4f)continue;
        float rhw=1.f/clip[3];
        float zNdc=clip[2]*rhw;
        if(!isfinite(zNdc)||zNdc<0.f||zNdc>=1.f)continue;
        float dx3=pos[0]-eyeX,dy3=pos[1]-eyeY,dz3=pos[2]-eyeZ;
        float dist3d=sqrtf(dx3*dx3+dy3*dy3+dz3*dz3);
        if(!isfinite(dist3d)||dist3d<=1e-5f)continue;
        targetSX[t]=(clip[0]*rhw+1.f)*512.f;
        targetSY[t]=(1.f-clip[1]*rhw)*384.f;
        targetW[t]=clip[3];
        targetDist3D[t]=dist3d;
        float perspR=(kTargetRadius[t]*6.4f)/dist3d;
        targetScaledR[t]=syntheticProbe?fmaxf(kTargetRadius[t],perspR):perspR;
        targetValid[t]=isfinite(targetSX[t])&&isfinite(targetSY[t]);
        if(targetValid[t])anyValid=YES;
    }
    if(!anyValid)return -1;
    BOOL backView=(targetValid[3]&&targetValid[4]&&targetW[4]<targetW[3]);
    dc_matrix kosiGlobal;
    if(_kosiNode!=UINT32_MAX&&dc_model_global(_actor.model,_kosiNode,&kosiGlobal)==DC_OK) {
        float fx=kosiGlobal.values[12]+2.f*kosiGlobal.values[8]-eyeX;
        float fy=kosiGlobal.values[13]+2.f*kosiGlobal.values[9]-eyeY;
        float fz=kosiGlobal.values[14]+2.f*kosiGlobal.values[10]-eyeZ;
        float bx=kosiGlobal.values[12]-2.f*kosiGlobal.values[8]-eyeX;
        float by=kosiGlobal.values[13]-2.f*kosiGlobal.values[9]-eyeY;
        float bz=kosiGlobal.values[14]-2.f*kosiGlobal.values[10]-eyeZ;
        backView=((bx*bx+by*by+bz*bz)<(fx*fx+fy*fy+fz*fz));
    }
    int32_t bestTarget=-1;
    float bestDist=9999.f;
    for(unsigned t=0;t<7;++t) {
        if(!targetValid[t])continue;
        if(backView&&(t==1||t==2||t==3))continue;
        if(!backView&&t==4)continue;
        float dx=px-targetSX[t],dy=py-targetSY[t];
        float r=targetScaledR[t];
        if(dx*dx+dy*dy<r*r&&targetDist3D[t]<bestDist) {
            bestDist=targetDist3D[t];
            bestTarget=(int32_t)t;
        }
    }
    return bestTarget;
}
- (NSString *)preferredCameraNameForSelector:(uint32_t)selector {
    char resource[32];
    if(dc_camera_scene_resource(_sceneType,selector,_storyStage,resource,sizeof(resource))==DC_OK)
        return [NSString stringWithUTF8String:resource];
    dc_game_map_presentation profile;
    return dc_game_map_presentation_profile(selector,&profile)==DC_OK?
        [NSString stringWithUTF8String:profile.camera]:nil;
}
- (NSString *)autoSelectCameraAtTick:(uint32_t)tick {
    if(_cameraAutoSelected)return nil;
    dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_viewport viewport={0,0,1024,768,0,1};
    dc_matrix mapWorld=_map.world,actorWorld=_actor.world;
    if(dc_model_tick(_map.model,0,tick,&mapWorld)!=DC_OK||dc_model_tick(_actor.model,0,tick,&actorWorld)!=DC_OK)return @"Camera fallback model tick failed";
    if(_face.model && (![self updateFaceAttachment] || dc_model_tick(_face.model,0,tick,&_face.world)!=DC_OK))return @"Camera fallback face tick failed";
    dc_camera_orbit current={.base=_cameraBase,.stored_distance=_cameraDistance,.height=_cameraHeight,.pitch=_cameraPitch,.yaw=_cameraYaw};dc_camera_matrices currentMatrices;
    if(dc_camera_build(&current,&lens,&currentMatrices)!=DC_OK)return @"Camera fallback build failed";
    uint32_t currentMap=[self projectedTrianglesForModel:_map.model camera:&currentMatrices viewport:&viewport];
    uint32_t currentActor=[self projectedTrianglesForModel:_actor.model camera:&currentMatrices viewport:&viewport];
    uint32_t currentFace=_face.model ? [self projectedTrianglesForModel:_face.model camera:&currentMatrices viewport:&viewport] : 0;
    if(currentMap&&currentActor&&(!_face.model || currentFace)){_cameraAutoSelected=YES;return nil;}
    NSValue *cached=_cameraFallbacks[@(_mapSelector)];
    if(cached){dc_camera_orbit candidate;[cached getValue:&candidate];_cameraBase=candidate.base;_cameraDistance=candidate.stored_distance;_cameraHeight=candidate.height;_cameraPitch=candidate.pitch;_cameraYaw=candidate.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];_cameraAutoSelected=YES;return nil;}
    NSError *reason=nil;DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_03.pp"]] error:&reason];
    if(!archive)return reason.localizedDescription ?: @"Camera archive could not be opened";
    uint64_t bestScore=0;dc_camera_orbit best=current;BOOL found=NO;
    NSString *preferred=[self preferredCameraNameForSelector:_mapSelector];
    if(preferred){for(uint32_t i=0;i<archive.entryCount;++i){if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:preferred]!=NSOrderedSame)continue;NSData *data=[archive readEntryAtIndex:i limit:4096 error:nil];dc_camera_orbit candidate;dc_camera_matrices matrices;if(data&&dc_camera_read_preset(data.bytes,data.length,0,&candidate)==DC_OK&&dc_camera_build(&candidate,&lens,&matrices)==DC_OK&&[self projectedTrianglesForModel:_map.model camera:&matrices viewport:&viewport]&&[self projectedTrianglesForModel:_actor.model camera:&matrices viewport:&viewport]&&(!_face.model || [self projectedTrianglesForModel:_face.model camera:&matrices viewport:&viewport])){_cameraBase=candidate.base;_cameraDistance=candidate.stored_distance;_cameraHeight=candidate.height;_cameraPitch=candidate.pitch;_cameraYaw=candidate.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];[_cameraFallbacks setObject:[NSValue valueWithBytes:&candidate objCType:@encode(dc_camera_orbit)] forKey:@(_mapSelector)];_cameraAutoSelected=YES;return nil;}break;}}
    for(uint32_t i=0;i<archive.entryCount;++i) {
        NSString *name=[archive asciiNameAtIndex:i];if(![name.lowercaseString hasSuffix:@".cam"])continue;
        NSData *data=[archive readEntryAtIndex:i limit:4096 error:nil];if(!data)continue;dc_camera_orbit candidate;dc_camera_matrices matrices;
        if(dc_camera_read_preset(data.bytes,data.length,0,&candidate)!=DC_OK||dc_camera_build(&candidate,&lens,&matrices)!=DC_OK)continue;
        uint32_t mapTriangles=[self projectedTrianglesForModel:_map.model camera:&matrices viewport:&viewport];uint32_t actorTriangles=[self projectedTrianglesForModel:_actor.model camera:&matrices viewport:&viewport];uint32_t faceTriangles=_face.model ? [self projectedTrianglesForModel:_face.model camera:&matrices viewport:&viewport] : 0;
        if(!actorTriangles||(_face.model && !faceTriangles))continue;uint64_t score=(uint64_t)mapTriangles*1000u+(uint64_t)actorTriangles*10u+faceTriangles;if(!found||score>bestScore){found=YES;bestScore=score;best=candidate;}
    }
    if(found){_cameraBase=best.base;_cameraDistance=best.stored_distance;_cameraHeight=best.height;_cameraPitch=best.pitch;_cameraYaw=best.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];[_cameraFallbacks setObject:[NSValue valueWithBytes:&best objCType:@encode(dc_camera_orbit)] forKey:@(_mapSelector)];}
    _cameraAutoSelected=YES;return found?nil:@"No camera preset projects the actor";
}
- (void)enableEmbeddedXAChainsForSlot:(dc_game_model *)slot {
    if(!slot||!slot->model||!slot->xaData||!slot->xaData.length)return;
    dc_animation_clip *clips=calloc(512u,sizeof(*clips));
    dc_animation_timing *timings=calloc(512u,sizeof(*timings));
    if(clips&&timings&&dc_xa_load_clips(slot->xaData.bytes,slot->xaData.length,clips,timings,512u)==DC_OK) {
        for(uint32_t c=0;c<512u;++c) {
            uint32_t next=timings[c].next_clip;
            if(clips[c].last_frame>0u&&clips[c].loop==0u&&timings[c].chain==0u&&
               next>0u&&next<512u&&clips[next].last_frame>0u) {
                dc_model_set_chain(slot->model,c,(int32_t)next);
            }
        }
    }
    free(clips);
    free(timings);
}
- (BOOL)loadType7ModelsAndCameraFromDirectory:(NSString *)directory reloadOnly:(BOOL)reloadOnly error:(NSString **)error {
    [self detachModel:&_actor];
    for(unsigned b=0;b<3;++b)[self detachModel:&_extraActors[b]];
    [self detachModel:&_face];
    for(unsigned f=0;f<2;++f)[self detachModel:&_extraFaces[f]];
    _extraActorCount=0;_extraFaceCount=0;_actorSkinMeshCount=0;
    _lastDynamicTexMask=UINT32_MAX;
    _eyeNeckValid=NO;_extraEyeNeckValid[0]=_extraEyeNeckValid[1]=NO;
    if(dc_type7_resolve_assets(&_type7State,&_type7Assets)!=DC_OK) {
        if(error)*error=@"Type 7 asset descriptor rejected";
        return NO;
    }
    _storyStage=_type7State.primary_heroine;
    dc_game_actor_prefix(_storyStage,&_characterPrefix);
    NSString *bodyArchName=_type7Assets.body_archive[0]?[NSString stringWithUTF8String:_type7Assets.body_archive]:@"RPP_06.pp";
    DCArchive *bodyArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:bodyArchName]] error:nil];
    DCArchive *faceArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_09.pp"]] error:nil];
    DCArchive *auxArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_04.pp"]] error:nil];
    DCArchive *camArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_03.pp"]] error:nil];
    DCArchive *lightArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_07.pp"]] error:nil];
    if(!bodyArchive||!faceArchive||!camArchive) {
        if(error)*error=@"Type 7 model archives unavailable";
        return NO;
    }
    if(lightArchive&&_type7Assets.char_light_xl[0]!='\0') {
        NSData *cXl=[self entry:[NSString stringWithUTF8String:_type7Assets.char_light_xl] archive:lightArchive error:nil];
        dc_xl_info cInfo;dc_xl_light cLight;
        if(cXl&&dc_xl_probe(cXl.bytes,cXl.length,&cInfo)==DC_OK&&cInfo.lights&&dc_xl_light_at(cXl.bytes,cXl.length,0,&cLight)==DC_OK) {
            _lightData=cXl;_lightInfo=cInfo;_mapLight=cLight;
            _charD3DLightCount=MIN(cInfo.lights,8u);
            if(dc_xl_ambient(cXl.bytes,cXl.length,_charGlobalAmbient)!=DC_OK)
                _charGlobalAmbient[0]=_charGlobalAmbient[1]=_charGlobalAmbient[2]=0.298f;
            for(uint32_t k=0;k<_charD3DLightCount;++k)dc_xl_d3d_light_at(cXl.bytes,cXl.length,k,&_charD3DLights[k]);
        }
    }
    uint32_t anchor=_type7Assets.anchor_primary[0]?[self findNode:&_map name:[NSString stringWithUTF8String:_type7Assets.anchor_primary]]:UINT32_MAX;
    if(anchor!=UINT32_MAX)_anchorName=[NSString stringWithUTF8String:_type7Assets.anchor_primary];
    if(anchor==UINT32_MAX&&_type7Assets.anchor_fallback[0]) {
        anchor=[self findNode:&_map name:[NSString stringWithUTF8String:_type7Assets.anchor_fallback]];
        if(anchor!=UINT32_MAX)_anchorName=[NSString stringWithUTF8String:_type7Assets.anchor_fallback];
    }
    if(anchor==UINT32_MAX)anchor=[self findAnchor:&_map];
    dc_matrix mapWorld=gameIdentity();
    if(anchor==UINT32_MAX||dc_model_tick(_map.model,0,0,&mapWorld)!=DC_OK||
       dc_model_global(_map.model,anchor,&_actorWorld)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Type 7 map %u anchor unavailable",_mapSelector];
        return NO;
    }
    NSMutableArray<NSData *> *bodyPlacements=[NSMutableArray arrayWithCapacity:4];
    for(uint32_t b=0;b<_type7Assets.body_count&&b<4u;++b) {
        dc_game_model *bs=[self bodySlotAtIndex:b];
        bs->xxData=[self entry:[NSString stringWithUTF8String:_type7Assets.body_xx[b]] archive:bodyArchive error:error];
        bs->xaData=[self entry:[NSString stringWithUTF8String:_type7Assets.body_xa[b]] archive:bodyArchive error:error];
        NSData *plst=_type7Assets.body_plst[b][0]?[self entry:[NSString stringWithUTF8String:_type7Assets.body_plst[b]] archive:bodyArchive error:nil]:nil;
        [bodyPlacements addObject:plst?:[NSData data]];
        if(!bs->xxData||!bs->xaData||![self openModel:bs staticOnly:NO error:error])return NO;
        NSString *morphErr=nil;
        if(bs->xaInfo.morph_tracks&&![self buildMorphCaches:bs error:&morphErr]) {
            if(error)*error=morphErr?:@"Type 7 body morph cache failed";
            return NO;
        }
        [self enableEmbeddedXAChainsForSlot:bs];
        if(dc_model_request(bs->model,1u,0u)!=DC_OK) {
            if(error)*error=@"Type 7 body initial clip failed";
            return NO;
        }
        bs->world=_actorWorld;
    }
    _extraActorCount=(_type7Assets.body_count>1u)?(_type7Assets.body_count-1u):0u;
    for(uint32_t mesh=0;mesh<_actor.info.submeshes;++mesh) {
        uint32_t space=DC_MODEL_SPACE_LOCAL;
        if(dc_model_vertex_space(_actor.model,mesh,&space)==DC_OK&&space==DC_MODEL_SPACE_WORLD)++_actorSkinMeshCount;
    }
    static NSString *const kHairSpringNames[6]={
        @"a_Kn_kami_L2",@"a_Kn_kami_R2",@"a_Kn_kami_B2",
        @"a_Kn_kami_P3",@"a_Kn_kami_BL2",@"a_Kn_kami_BR2"
    };
    for(uint32_t hIdx=0;hIdx<_type7Assets.head_count&&hIdx<3u;++hIdx) {
        uint8_t h=_type7Assets.head_heroine[hIdx];
        uint8_t bIdx=_type7Assets.head_body_index[hIdx];
        char pfx=dc_type7_heroine_prefix(h);
        _headHeroines[hIdx]=h;
        _headBodyIndices[hIdx]=bIdx;
        dc_game_model *fs=[self faceSlotAtIndex:hIdx];
        dc_game_model *bs=[self bodySlotAtIndex:bIdx];
        NSString *hXX=_type7Assets.head_xx[hIdx][0]?[NSString stringWithUTF8String:_type7Assets.head_xx[hIdx]]:[NSString stringWithFormat:@"%ck00_00.xx",pfx];
        NSString *hXA=_type7Assets.head_xa[hIdx][0]?[NSString stringWithUTF8String:_type7Assets.head_xa[hIdx]]:[NSString stringWithFormat:@"%cn00_01.xa",pfx];
        fs->xxData=[self entry:hXX archive:faceArchive error:error];
        fs->xaData=[self entry:hXA archive:faceArchive error:error];
        if(!fs->xxData||!fs->xaData||![self openModel:fs staticOnly:YES error:error])return NO;
        NSString *morphErr=nil;
        if(![self buildMorphCaches:fs error:&morphErr]) {
            if(error)*error=morphErr?:@"Type 7 face morph cache failed";
            return NO;
        }
        fs->world=_actorWorld;
        NSData *plst=(bIdx<bodyPlacements.count&&bodyPlacements[bIdx].length>0)?bodyPlacements[bIdx]:nil;
        uint32_t headNode=[self placementNodeFromPLST:plst model:bs prefix:pfx];
        if(headNode==UINT32_MAX)headNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Nz_kubi2"]];
        if(headNode==UINT32_MAX)headNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_kubi2"]];
        dc_matrix identity=gameIdentity(),sourceBind,sourceInverse=gameIdentity();
        uint32_t faceSourceNode=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Nz_kao"]];
        if(faceSourceNode!=UINT32_MAX&&dc_model_tick(fs->model,0,0,&identity)==DC_OK&&
           dc_model_global(fs->model,faceSourceNode,&sourceBind)==DC_OK) {
            dc_matrix_inverse_affine(&sourceBind,&sourceInverse);
        }
        NSString *hEyes=_type7Assets.head_eyes[hIdx][0]?[NSString stringWithUTF8String:_type7Assets.head_eyes[hIdx]]:[NSString stringWithFormat:@"%ck00_00.eyes",pfx];
        NSString *hNeck=_type7Assets.head_neck[hIdx][0]?[NSString stringWithUTF8String:_type7Assets.head_neck[hIdx]]:[NSString stringWithFormat:@"%cm00_01.neck",pfx];
        NSData *eData=auxArchive?[self entry:hEyes archive:auxArchive error:nil]:nil;
        NSData *nData=auxArchive?[self entry:hNeck archive:auxArchive error:nil]:nil;
        if(hIdx==0u) {
            _actorHeadNode=headNode;
            _faceBindInverse=sourceInverse;
            _eyesData=eData;_neckData=nData;
            _springBreastNodes[0]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Lmune1"]];
            _springBreastNodes[1]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Rmune1"]];
            _breastNodes[0]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Lmune2"]];
            _breastNodes[1]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Rmune2"]];
            _neckNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_kubi2"]];
            _maleEyeTargetNode=[self findNode:bs name:@"s_Nn_kamera_S"];
            _kosiNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kn_kosi"]];
            _eyeNodes[0]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_R"]];
            _eyeNodes[1]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_L"]];
            _eyeHighlightNodes[0]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_R"]];
            _eyeHighlightNodes[1]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_L"]];
            for(unsigned hs=0;hs<6;++hs) {
                _hairSpringNodes[hs]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:kHairSpringNames[hs]]];
                dc_spring_node_init(&_hairSprings[hs]);
            }
            for(unsigned b=0;b<2;++b)dc_spring_node_init(&_breastSprings[b]);
            dc_eyeneck_tremor_init(&_eyeTremor);
            dc_eyeneck_controller_init(&_neckController);
            for(unsigned e=0;e<2;++e)dc_eyeneck_controller_init(&_eyeControllers[e]);
            if(eData&&nData) {
                BOOL slotsOk=YES;
                for(uint32_t r=0;r<5u;++r)if(dc_eyeneck_slot_at(eData.bytes,eData.length,r,&_eyeSlots[r])!=DC_OK)slotsOk=NO;
                for(uint32_t r=0;r<3u;++r)if(dc_eyeneck_slot_at(nData.bytes,nData.length,r,&_neckSlots[r])!=DC_OK)slotsOk=NO;
                _eyeNeckValid=slotsOk;
            }
        } else {
            uint32_t ex=hIdx-1u;
            _extraActorHeadNodes[ex]=headNode;
            _extraFaceBindInverses[ex]=sourceInverse;
            _extraEyesData[ex]=eData;_extraNeckData[ex]=nData;
            _extraSpringBreastNodes[ex][0]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Lmune1"]];
            _extraSpringBreastNodes[ex][1]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Rmune1"]];
            _extraNeckNodes[ex]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_kubi2"]];
            _extraEyeNodes[ex][0]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_R"]];
            _extraEyeNodes[ex][1]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_L"]];
            _extraEyeHighlightNodes[ex][0]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_R"]];
            _extraEyeHighlightNodes[ex][1]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_L"]];
            for(unsigned hs=0;hs<6;++hs) {
                _extraHairSpringNodes[ex][hs]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:kHairSpringNames[hs]]];
                dc_spring_node_init(&_extraHairSprings[ex][hs]);
            }
            for(unsigned b=0;b<2;++b)dc_spring_node_init(&_extraBreastSprings[ex][b]);
            dc_eyeneck_tremor_init(&_extraEyeTremor[ex]);
            dc_eyeneck_controller_init(&_extraNeckController[ex]);
            for(unsigned e=0;e<2;++e)dc_eyeneck_controller_init(&_extraEyeControllers[ex][e]);
            _extraEyeBlinkState[ex][0]=_extraEyeBlinkState[ex][1]=0;
            _extraEyeBlinkWaitTicks[ex][0]=_extraEyeBlinkWaitTicks[ex][1]=12+(int32_t)(ex*7u);
            _extraEyeBlinkHoldTicks[ex][0]=_extraEyeBlinkHoldTicks[ex][1]=1;
            _extraEyeBlinkDuration[ex][0]=_extraEyeBlinkDuration[ex][1]=0;
            _extraEyeBlinkEndTick[ex][0]=_extraEyeBlinkEndTick[ex][1]=0;
            if(eData&&nData) {
                BOOL slotsOk=YES;
                for(uint32_t r=0;r<5u;++r)if(dc_eyeneck_slot_at(eData.bytes,eData.length,r,&_extraEyeSlots[ex][r])!=DC_OK)slotsOk=NO;
                for(uint32_t r=0;r<3u;++r)if(dc_eyeneck_slot_at(nData.bytes,nData.length,r,&_extraNeckSlots[ex][r])!=DC_OK)slotsOk=NO;
                _extraEyeNeckValid[ex]=slotsOk;
            }
        }
    }
    _extraFaceCount=(_type7Assets.head_count>1u)?(_type7Assets.head_count-1u):0u;
    NSString *camName=[NSString stringWithUTF8String:_type7Assets.cam_file];
    NSData *camData=[self entry:camName archive:camArchive error:nil];
    if(camData)_cameraSource=camName;
    if(!camData) {
        dc_game_map_presentation profile;
        if(dc_game_map_presentation_profile(_mapSelector,&profile)==DC_OK&&profile.camera) {
            NSString *fb=[NSString stringWithUTF8String:profile.camera];
            camData=[self entry:fb archive:camArchive error:nil];
            if(camData)_cameraSource=fb;
        }
    }
    dc_camera_orbit orbit;
    if(!camData||dc_camera_read_preset(camData.bytes,camData.length,0,&orbit)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Type 7 camera %@ unavailable",camName];
        return NO;
    }
    _cameraPreset=0;
    _cameraBase=orbit.base;
    _cameraDistance=orbit.stored_distance;_cameraHeight=orbit.height;_cameraPitch=orbit.pitch;_cameraYaw=orbit.yaw;
    _cameraPresetData=camData;_secondaryCamera=orbit;
    _cameraAutoSelected=YES;
    _primaryCameraMode=0u;_secondaryCameraMode=0u;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _actorOriginX=_actorWorld.values[12];_actorOriginY=_actorWorld.values[13];_actorOriginZ=_actorWorld.values[14];
    memset(_type7Clips,0,sizeof(_type7Clips));
    dc_animation_timing *t7Timings=calloc(512u,sizeof(*t7Timings));
    if(t7Timings&&_actor.xaData.length>0) {
        dc_xa_load_clips(_actor.xaData.bytes,_actor.xaData.length,_type7Clips,t7Timings,512u);
    }
    free(t7Timings);
    if(reloadOnly)_needsResumeAtNextTick=YES;
    [self applyType7PregnancyCycles:_type7PregnancyCycles];
    [self applyType7ClothingAndVibeVisibility];
    return YES;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    type7SubMode:(uint8_t)subMode mapSelector:(uint32_t)mapSelector
    slot0:(uint8_t)slot0 slot1:(uint8_t)slot1 slot2:(uint8_t)slot2
    conqueredMask:(uint8_t)conqueredMask error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];_renderer=renderer;
    _storyChapter=24u;_storyPhase=0u;_sceneKind=DC_STORY_SCENE_NIGHT;_sceneType=7u;
    _stageProgress=2u;
    dc_type7_plan initialPlan={0};
    if(dc_type7_init(&_type7State,subMode,(uint8_t)mapSelector,slot0,slot1,slot2,conqueredMask,&initialPlan)!=DC_OK) {
        if(error)*error=@"Type 7 state initialization rejected";
        return nil;
    }
    _mapSelector=_type7State.map_id;
    _storyStage=_type7State.primary_heroine;
    dc_game_actor_prefix(_storyStage,&_characterPrefix);
    _secondaryVisible=YES;_hairVisible=YES;_cameraTargetVisible=YES;_lastDynamicTexMask=UINT32_MAX;
    _mapAlpha=1.f;_handAlpha=1.f;_maleBodyAlpha=1.f;_maleGenitalAlpha=1.f;
    _secondaryLimits=(dc_camera_pointer_limits){100,5,20,-30,4};
    _mapLayerVisible[0]=_mapLayerVisible[1]=_mapLayerVisible[2]=YES;
    _backgroundColor[3]=255;
    _mainIconHover=-1;_lastContextSelection=-1;
    _sceneUITextures=[NSMutableDictionary dictionary];
    _rpp15Textures=[NSMutableDictionary dictionary];
    _cameraFallbacks=[NSMutableDictionary dictionary];
    _gameMenu=(dc_menu_state){.selected=-1,.hover=-1};
    _gameMenuInitialized=YES;
    _naturalGameplayRoute=YES;
    _actorPlaybackSpeed=1.0f;_watchPart=-1;_hoverTargetHit=-1;_cursorIndex=0;_cursorX=512.f;_cursorY=384.f;
    for(unsigned t=0;t<7;++t)_targetNodes[t]=UINT32_MAX;
    _sceneUIArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:nil];
    if(!_sceneUIArchive){if(error)*error=@"Original scene UI archive unavailable";return nil;}
    for(NSString *icon in @[@"chara",@"fuku",@"cam",@"sys"])for(NSString *state in @[@"S",@"N"]) {
        NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icon,state];
        if(![self sceneUITexture:name error:error])return nil;
    }
    for(NSString *extra in @[@"k_defo.ema",@"k_roll.ema",@"k_zoom.ema",@"k_move.ema",
                             @"D_cir.ema",@"kaikan_base.ema",@"kaikan_a.ema",@"kaikan_b.ema",@"kaikan_c.ema"]) {
        [self sceneUITexture:extra error:nil];
    }
    NSError *reason=nil;
    DCArchive *mapArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_10.pp"]] error:&reason];
    DCArchive *lightArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_07.pp"]] error:nil];
    if(!mapArchive){if(error)*error=reason.localizedDescription?:@"Map archive unavailable";return nil;}
    _map.xxData=[self entry:[NSString stringWithFormat:@"mm00_%02u.xx",_mapSelector] archive:mapArchive error:error];
    _map.xaData=[self entry:[NSString stringWithFormat:@"mn00_%02u.xa",_mapSelector] archive:mapArchive error:nil];
    if(!_map.xxData||![self openModel:&_map staticOnly:(_map.xaData==nil) error:error])return nil;
    [self loadMapVariantLightForSelector:_mapSelector archive:mapArchive error:nil];
    {
        NSData *glareData=[self entry:[NSString stringWithFormat:@"mm00_%02u.glare",_mapSelector] archive:mapArchive error:nil];
        if(glareData&&dc_glare_probe(glareData.bytes,glareData.length,&_glareInfo)==DC_OK)_hasGlare=YES;
    }
    if(lightArchive)[self loadLightForSelector:_mapSelector archive:lightArchive error:nil];
    _rpp15Archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_15.pp"]] error:nil];
    DCArchive *cameraArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_17.pp"]] error:&reason];
    if(!cameraArchive){if(error)*error=@"Original automatic camera archive unavailable";return nil;}
    _autoCamera.xxData=[self entry:@"auto_cam.xx" archive:cameraArchive error:error];
    _autoCamera.xaData=[self entry:@"auto_cam.xa" archive:cameraArchive error:error];
    if(!_autoCamera.xxData||!_autoCamera.xaData||![self openModel:&_autoCamera staticOnly:NO error:error])return nil;
    if(dc_model_request(_autoCamera.model,0,0)!=DC_OK){if(error)*error=@"Original automatic camera animation unavailable";return nil;}
    _cameraTarget.xxData=[self entry:@"target.xx" archive:cameraArchive error:nil];
    if(_cameraTarget.xxData)[self openModel:&_cameraTarget staticOnly:YES error:nil];
    if(![self loadType7ModelsAndCameraFromDirectory:directory reloadOnly:NO error:error])return nil;
    [self applyMapLayerVisibility];
    [self computeWalkBounds];
    [self computeActorFloorOffset];
    _player.x=_actor.world.values[12];_player.z=_actor.world.values[14];
    _player.min_x=_walkMinX;_player.max_x=_walkMaxX;_player.min_z=_walkMinZ;_player.max_z=_walkMaxZ;_player.speed=8;
    _player.map_selector=_mapSelector;
    NSString *planErr=[self applyType7Plan:&initialPlan tick:0u];
    if(planErr){if(error)*error=planErr;return nil;}
    _loaded=YES;
    return self;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    editState:(const dc_edit_state *)editState error:(NSString **)error {
    if(!(self=[super init]))return nil;
    if(!editState){if(error)*error=@"Missing Edit state";return nil;}
    _directory=[directory copy];_renderer=renderer;
    _editStateCopy=*editState;
    _editClimaxCount=0u;_editVagPenMask=0u;_editAnalPenMask=0u;
    _storyChapter=24u;_storyPhase=0u;_sceneKind=DC_STORY_SCENE_NIGHT;_sceneType=12u;
    _editMode=YES;_stageProgress=2u;
    if(dc_edit_resolve_assets(&_editStateCopy,&_editAssets)!=DC_OK) {
        if(error)*error=@"Edit asset resolution rejected";
        return nil;
    }
    dc_edit_step_plan initialPlan={0};
    if(dc_edit_player_init(&_editPlayer,&_editStateCopy,&initialPlan)!=DC_OK) {
        if(error)*error=@"Edit player initialization rejected";
        return nil;
    }
    _mapSelector=_editAssets.map_id;
    _storyStage=(_editAssets.head_count>0u&&_editAssets.head_heroine[0]<3u)?_editAssets.head_heroine[0]:2u;
    _editCamTargetHeroine=(initialPlan.cam_target_heroine<3u)?initialPlan.cam_target_heroine:(uint8_t)_storyStage;
    dc_game_actor_prefix(_storyStage,&_characterPrefix);
    _secondaryVisible=YES;_hairVisible=YES;_cameraTargetVisible=YES;_lastDynamicTexMask=UINT32_MAX;
    _mapAlpha=1.f;_handAlpha=1.f;_maleBodyAlpha=1.f;_maleGenitalAlpha=1.f;
    _secondaryLimits=(dc_camera_pointer_limits){100,5,20,-30,4};
    _mapLayerVisible[0]=_mapLayerVisible[1]=_mapLayerVisible[2]=YES;
    _backgroundColor[3]=255;
    _mainIconHover=-1;_lastContextSelection=-1;
    _sceneUITextures=[NSMutableDictionary dictionary];
    _rpp15Textures=[NSMutableDictionary dictionary];
    _cameraFallbacks=[NSMutableDictionary dictionary];
    _gameMenu=(dc_menu_state){.selected=-1,.hover=-1};
    _gameMenuInitialized=YES;
    _naturalGameplayRoute=YES;
    _actorPlaybackSpeed=1.0f;_watchPart=-1;_hoverTargetHit=-1;_cursorIndex=0;_cursorX=512.f;_cursorY=384.f;
    for(unsigned t=0;t<7;++t)_targetNodes[t]=UINT32_MAX;
    _sceneUIArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:nil];
    if(!_sceneUIArchive){if(error)*error=@"Original scene UI archive unavailable";return nil;}
    for(NSString *icon in @[@"chara",@"fuku",@"cam",@"sys"])for(NSString *state in @[@"S",@"N"]) {
        NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icon,state];
        if(![self sceneUITexture:name error:error])return nil;
    }
    for(NSString *extra in @[@"k_defo.ema",@"k_roll.ema",@"k_zoom.ema",@"k_move.ema",@"D_cir.ema"]) {
        [self sceneUITexture:extra error:nil];
    }
    NSError *reason=nil;
    DCArchive *mapArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_10.pp"]] error:&reason];
    DCArchive *lightArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_07.pp"]] error:nil];
    if(!mapArchive){if(error)*error=reason.localizedDescription?:@"Map archive unavailable";return nil;}
    _map.xxData=[self entry:[NSString stringWithUTF8String:_editAssets.map_xx] archive:mapArchive error:error];
    if(_editAssets.map_xa[0]!='\0')
        _map.xaData=[self entry:[NSString stringWithUTF8String:_editAssets.map_xa] archive:mapArchive error:nil];
    if(!_map.xxData||![self openModel:&_map staticOnly:(_map.xaData==nil) error:error])return nil;
    if(_editAssets.map_xl[0]!='\0') {
        NSData *mXl=[self entry:[NSString stringWithUTF8String:_editAssets.map_xl] archive:mapArchive error:nil];
        dc_xl_info mInfo;dc_xl_light mLight;
        if(mXl&&dc_xl_probe(mXl.bytes,mXl.length,&mInfo)==DC_OK&&mInfo.lights&&dc_xl_light_at(mXl.bytes,mXl.length,0,&mLight)==DC_OK) {
            _mapVariantLightData=mXl;_mapVariantLightInfo=mInfo;_mapVariantLight=mLight;
            _mapD3DLightCount=MIN(mInfo.lights,8u);
            if(dc_xl_ambient(mXl.bytes,mXl.length,_mapGlobalAmbient)!=DC_OK)
                _mapGlobalAmbient[0]=_mapGlobalAmbient[1]=_mapGlobalAmbient[2]=0.3f;
            for(uint32_t k=0;k<_mapD3DLightCount;++k)dc_xl_d3d_light_at(mXl.bytes,mXl.length,k,&_mapD3DLights[k]);
        }
    } else {
        [self loadMapVariantLightForSelector:_mapSelector archive:mapArchive error:nil];
    }
    if(_editAssets.map_glare[0]!='\0') {
        NSData *glareData=[self entry:[NSString stringWithUTF8String:_editAssets.map_glare] archive:mapArchive error:nil];
        if(glareData&&dc_glare_probe(glareData.bytes,glareData.length,&_glareInfo)==DC_OK)_hasGlare=YES;
    }
    if(lightArchive) {
        NSData *cXl=_editAssets.char_light_xl[0]?[self entry:[NSString stringWithUTF8String:_editAssets.char_light_xl] archive:lightArchive error:nil]:nil;
        dc_xl_info cInfo;dc_xl_light cLight;
        if(cXl&&dc_xl_probe(cXl.bytes,cXl.length,&cInfo)==DC_OK&&cInfo.lights&&dc_xl_light_at(cXl.bytes,cXl.length,0,&cLight)==DC_OK) {
            _lightData=cXl;_lightInfo=cInfo;_mapLight=cLight;
            _charD3DLightCount=MIN(cInfo.lights,8u);
            if(dc_xl_ambient(cXl.bytes,cXl.length,_charGlobalAmbient)!=DC_OK)
                _charGlobalAmbient[0]=_charGlobalAmbient[1]=_charGlobalAmbient[2]=0.298f;
            for(uint32_t k=0;k<_charD3DLightCount;++k)dc_xl_d3d_light_at(cXl.bytes,cXl.length,k,&_charD3DLights[k]);
        } else {
            [self loadLightForSelector:_mapSelector archive:lightArchive error:nil];
        }
    }
    _rpp15Archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_15.pp"]] error:nil];
    DCArchive *cameraArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_17.pp"]] error:&reason];
    if(!cameraArchive){if(error)*error=@"Original automatic camera archive unavailable";return nil;}
    _autoCamera.xxData=[self entry:@"auto_cam.xx" archive:cameraArchive error:error];
    _autoCamera.xaData=[self entry:@"auto_cam.xa" archive:cameraArchive error:error];
    if(!_autoCamera.xxData||!_autoCamera.xaData||![self openModel:&_autoCamera staticOnly:NO error:error])return nil;
    if(dc_model_request(_autoCamera.model,0,0)!=DC_OK){if(error)*error=@"Original automatic camera animation unavailable";return nil;}
    _cameraTarget.xxData=[self entry:@"target.xx" archive:cameraArchive error:nil];
    if(_cameraTarget.xxData)[self openModel:&_cameraTarget staticOnly:YES error:nil];
    NSString *bodyArchiveName=[NSString stringWithUTF8String:_editAssets.body_archive];
    DCArchive *bodyArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:bodyArchiveName]] error:nil];
    DCArchive *faceArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_09.pp"]] error:nil];
    DCArchive *auxArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_04.pp"]] error:nil];
    DCArchive *camArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_03.pp"]] error:nil];
    if(!bodyArchive||!faceArchive||!camArchive) {
        if(error)*error=@"Edit 3D playback archives unavailable";
        return nil;
    }
    uint32_t anchor=_editAssets.anchor_primary[0]?[self findNode:&_map name:[NSString stringWithUTF8String:_editAssets.anchor_primary]]:UINT32_MAX;
    if(anchor!=UINT32_MAX)_anchorName=[NSString stringWithUTF8String:_editAssets.anchor_primary];
    if(anchor==UINT32_MAX&&_editAssets.anchor_fallback[0]) {
        anchor=[self findNode:&_map name:[NSString stringWithUTF8String:_editAssets.anchor_fallback]];
        if(anchor!=UINT32_MAX)_anchorName=[NSString stringWithUTF8String:_editAssets.anchor_fallback];
    }
    if(anchor==UINT32_MAX)anchor=[self findAnchor:&_map];
    dc_matrix mapWorld=gameIdentity();
    if(anchor==UINT32_MAX||dc_model_tick(_map.model,0,0,&mapWorld)!=DC_OK||
       dc_model_global(_map.model,anchor,&_actorWorld)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Edit map %u anchor unavailable",_mapSelector];
        return nil;
    }
    NSMutableArray<NSData *> *bodyPlacements=[NSMutableArray arrayWithCapacity:4];
    for(uint32_t b=0;b<_editAssets.body_count&&b<4u;++b) {
        dc_game_model *bs=[self bodySlotAtIndex:b];
        bs->xxData=[self entry:[NSString stringWithUTF8String:_editAssets.body_xx[b]] archive:bodyArchive error:error];
        bs->xaData=[self entry:[NSString stringWithUTF8String:_editAssets.body_xa[b]] archive:bodyArchive error:error];
        NSData *plst=_editAssets.body_plst[b][0]?[self entry:[NSString stringWithUTF8String:_editAssets.body_plst[b]] archive:bodyArchive error:nil]:nil;
        [bodyPlacements addObject:plst?:[NSData data]];
        if(!bs->xxData||!bs->xaData||![self openModel:bs staticOnly:NO error:error])return nil;
        NSString *morphErr=nil;
        if(bs->xaInfo.morph_tracks&&![self buildMorphCaches:bs error:&morphErr]) {
            if(error)*error=morphErr?:@"Edit body morph cache failed";
            return nil;
        }
        [self enableEmbeddedXAChainsForSlot:bs];
        dc_model_request(bs->model,1u,0u);
        bs->world=_actorWorld;
        _editNormalBodyXAMulti[b]=bs->xaData;
        if(_editAssets.body_oral_xa_multi[b][0]!='\0')
            _editOralBodyXAMulti[b]=[self entry:[NSString stringWithUTF8String:_editAssets.body_oral_xa_multi[b]] archive:bodyArchive error:nil];
    }
    _editNormalBodyXA=_actor.xaData;
    if(_editOralBodyXAMulti[0])_editOralBodyXA=_editOralBodyXAMulti[0];
    else if(_editAssets.body_oral_xa[0]!='\0')
        _editOralBodyXA=[self entry:[NSString stringWithUTF8String:_editAssets.body_oral_xa] archive:bodyArchive error:nil];
    memset(_editClips,0,sizeof(_editClips));
    dc_animation_timing *timings=calloc(512u,sizeof(*timings));
    if(timings) {
        dc_xa_load_clips(_actor.xaData.bytes,_actor.xaData.length,_editClips,timings,512u);
        free(timings);
    }
    _extraActorCount=(_editAssets.body_count>1u)?(_editAssets.body_count-1u):0u;
    for(uint32_t mesh=0;mesh<_actor.info.submeshes;++mesh) {
        uint32_t space=DC_MODEL_SPACE_LOCAL;
        if(dc_model_vertex_space(_actor.model,mesh,&space)==DC_OK&&space==DC_MODEL_SPACE_WORLD)++_actorSkinMeshCount;
    }
    static NSString *const kHairSpringNames[6]={
        @"a_Kn_kami_L2",@"a_Kn_kami_R2",@"a_Kn_kami_B2",
        @"a_Kn_kami_P3",@"a_Kn_kami_BL2",@"a_Kn_kami_BR2"
    };
    for(uint32_t hIdx=0;hIdx<_editAssets.head_count&&hIdx<3u;++hIdx) {
        uint8_t h=_editAssets.head_heroine[hIdx];
        uint8_t bIdx=_editAssets.head_body_index[hIdx];
        char pfx=dc_edit_heroine_prefix(h);
        _headHeroines[hIdx]=h;
        _headBodyIndices[hIdx]=bIdx;
        dc_game_model *fs=[self faceSlotAtIndex:hIdx];
        dc_game_model *bs=[self bodySlotAtIndex:bIdx];
        fs->xxData=[self entry:[NSString stringWithUTF8String:_editAssets.head_xx[hIdx]] archive:faceArchive error:error];
        fs->xaData=[self entry:[NSString stringWithUTF8String:_editAssets.head_xa[hIdx]] archive:faceArchive error:error];
        if(!fs->xxData||!fs->xaData||![self openModel:fs staticOnly:YES error:error])return nil;
        NSString *morphErr=nil;
        if(![self buildMorphCaches:fs error:&morphErr]) {
            if(error)*error=morphErr?:@"Edit face morph cache failed";
            return nil;
        }
        fs->world=_actorWorld;
        NSData *plst=(bIdx<bodyPlacements.count&&bodyPlacements[bIdx].length>0)?bodyPlacements[bIdx]:nil;
        uint32_t headNode=[self placementNodeFromPLST:plst model:bs prefix:pfx];
        if(headNode==UINT32_MAX)headNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Nz_kubi2"]];
        if(headNode==UINT32_MAX)headNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_kubi2"]];
        dc_matrix identity=gameIdentity(),sourceBind,sourceInverse=gameIdentity();
        uint32_t faceSourceNode=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Nz_kao"]];
        if(faceSourceNode!=UINT32_MAX&&dc_model_tick(fs->model,0,0,&identity)==DC_OK&&
           dc_model_global(fs->model,faceSourceNode,&sourceBind)==DC_OK) {
            dc_matrix_inverse_affine(&sourceBind,&sourceInverse);
        }
        NSData *eData=auxArchive?[self entry:[NSString stringWithUTF8String:_editAssets.head_eyes[hIdx]] archive:auxArchive error:nil]:nil;
        NSData *nData=auxArchive?[self entry:[NSString stringWithUTF8String:_editAssets.head_neck[hIdx]] archive:auxArchive error:nil]:nil;
        BOOL hideMehi=(h<3u&&_editStateCopy.personality[h]==2);
        if(hIdx==0u) {
            _actorHeadNode=headNode;
            _faceBindInverse=sourceInverse;
            _eyesData=eData;_neckData=nData;
            _springBreastNodes[0]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Lmune1"]];
            _springBreastNodes[1]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Rmune1"]];
            _breastNodes[0]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Lmune2"]];
            _breastNodes[1]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Rmune2"]];
            _neckNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_kubi2"]];
            _maleEyeTargetNode=[self findNode:bs name:@"s_Nn_kamera_S"];
            _kosiNode=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kn_kosi"]];
            _eyeNodes[0]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_R"]];
            _eyeNodes[1]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_L"]];
            _eyeHighlightNodes[0]=hideMehi?UINT32_MAX:[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_R"]];
            _eyeHighlightNodes[1]=hideMehi?UINT32_MAX:[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_L"]];
            for(unsigned hs=0;hs<6;++hs) {
                _hairSpringNodes[hs]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:kHairSpringNames[hs]]];
                dc_spring_node_init(&_hairSprings[hs]);
            }
            for(unsigned b=0;b<2;++b)dc_spring_node_init(&_breastSprings[b]);
            dc_eyeneck_tremor_init(&_eyeTremor);
            dc_eyeneck_controller_init(&_neckController);
            for(unsigned e=0;e<2;++e)dc_eyeneck_controller_init(&_eyeControllers[e]);
            if(eData&&nData) {
                BOOL slotsOk=YES;
                for(uint32_t r=0;r<5u;++r)if(dc_eyeneck_slot_at(eData.bytes,eData.length,r,&_eyeSlots[r])!=DC_OK)slotsOk=NO;
                for(uint32_t r=0;r<3u;++r)if(dc_eyeneck_slot_at(nData.bytes,nData.length,r,&_neckSlots[r])!=DC_OK)slotsOk=NO;
                _eyeNeckValid=slotsOk;
            }
        } else {
            uint32_t ex=hIdx-1u;
            _extraActorHeadNodes[ex]=headNode;
            _extraFaceBindInverses[ex]=sourceInverse;
            _extraEyesData[ex]=eData;_extraNeckData[ex]=nData;
            _extraSpringBreastNodes[ex][0]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Lmune1"]];
            _extraSpringBreastNodes[ex][1]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_Rmune1"]];
            _extraNeckNodes[ex]=[self findNode:bs name:[self nodeNameForPrefix:pfx template:@"a_Kp_kubi2"]];
            _extraEyeNodes[ex][0]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_R"]];
            _extraEyeNodes[ex][1]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_Np_me_L"]];
            _extraEyeHighlightNodes[ex][0]=hideMehi?UINT32_MAX:[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_R"]];
            _extraEyeHighlightNodes[ex][1]=hideMehi?UINT32_MAX:[self findNode:fs name:[self nodeNameForPrefix:pfx template:@"a_On_mehi_L"]];
            for(unsigned hs=0;hs<6;++hs) {
                _extraHairSpringNodes[ex][hs]=[self findNode:fs name:[self nodeNameForPrefix:pfx template:kHairSpringNames[hs]]];
                dc_spring_node_init(&_extraHairSprings[ex][hs]);
            }
            for(unsigned b=0;b<2;++b)dc_spring_node_init(&_extraBreastSprings[ex][b]);
            dc_eyeneck_tremor_init(&_extraEyeTremor[ex]);
            dc_eyeneck_controller_init(&_extraNeckController[ex]);
            for(unsigned e=0;e<2;++e)dc_eyeneck_controller_init(&_extraEyeControllers[ex][e]);
            _extraEyeBlinkState[ex][0]=_extraEyeBlinkState[ex][1]=0;
            _extraEyeBlinkWaitTicks[ex][0]=_extraEyeBlinkWaitTicks[ex][1]=12+(int32_t)(ex*7u);
            _extraEyeBlinkHoldTicks[ex][0]=_extraEyeBlinkHoldTicks[ex][1]=1;
            _extraEyeBlinkDuration[ex][0]=_extraEyeBlinkDuration[ex][1]=0;
            _extraEyeBlinkEndTick[ex][0]=_extraEyeBlinkEndTick[ex][1]=0;
            if(eData&&nData) {
                BOOL slotsOk=YES;
                for(uint32_t r=0;r<5u;++r)if(dc_eyeneck_slot_at(eData.bytes,eData.length,r,&_extraEyeSlots[ex][r])!=DC_OK)slotsOk=NO;
                for(uint32_t r=0;r<3u;++r)if(dc_eyeneck_slot_at(nData.bytes,nData.length,r,&_extraNeckSlots[ex][r])!=DC_OK)slotsOk=NO;
                _extraEyeNeckValid[ex]=slotsOk;
            }
        }
        [self applyEditBellyModifiersForBody:bs prefix:pfx level:_editAssets.head_preg_belly[hIdx]];
    }
    _extraFaceCount=(_editAssets.head_count>1u)?(_editAssets.head_count-1u):0u;
    NSString *camName=[NSString stringWithUTF8String:_editAssets.cam_file];
    NSData *camData=[self entry:camName archive:camArchive error:nil];
    if(camData)_cameraSource=camName;
    if(!camData) {
        dc_game_map_presentation profile;
        if(dc_game_map_presentation_profile(_mapSelector,&profile)==DC_OK&&profile.camera) {
            NSString *fb=[NSString stringWithUTF8String:profile.camera];
            camData=[self entry:fb archive:camArchive error:nil];
            if(camData)_cameraSource=fb;
        }
    }
    dc_camera_orbit orbit;
    if(!camData||dc_camera_read_preset(camData.bytes,camData.length,0,&orbit)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Edit camera %@ unavailable",camName];
        return nil;
    }
    _editNormalCamData=camData;
    if(_editAssets.oral_cam_file[0]!='\0')
        _editOralCamData=[self entry:[NSString stringWithUTF8String:_editAssets.oral_cam_file] archive:camArchive error:nil];
    _cameraPreset=0;
    _cameraBase=orbit.base;
    _cameraDistance=orbit.stored_distance;_cameraHeight=orbit.height;_cameraPitch=orbit.pitch;_cameraYaw=orbit.yaw;
    _cameraPresetData=camData;_secondaryCamera=orbit;
    _cameraAutoSelected=YES;
    _primaryCameraMode=0u;_secondaryCameraMode=0u;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _actorOriginX=_actorWorld.values[12];_actorOriginY=_actorWorld.values[13];_actorOriginZ=_actorWorld.values[14];
    [self applyMapLayerVisibility];
    [self computeWalkBounds];
    [self computeActorFloorOffset];
    _player.x=_actor.world.values[12];_player.z=_actor.world.values[14];
    _player.min_x=_walkMinX;_player.max_x=_walkMaxX;_player.min_z=_walkMinZ;_player.max_z=_walkMaxZ;_player.speed=8;
    _player.map_selector=_mapSelector;
    NSString *editPlanErr=[self applyEditStepPlan:&initialPlan tick:0u];
    if(editPlanErr){if(error)*error=editPlanErr;return nil;}
    _loaded=YES;
    return self;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage stageProgress:(uint32_t)progress resumeSavedPlayer:(BOOL)resume error:(NSString **)error {
    return [self initWithDirectory:directory renderer:renderer chapter:chapter mapSelector:mapSelector stage:stage
        stageProgress:progress sceneTypeOverride:0 resumeSavedPlayer:resume error:error];
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer chapter:(uint32_t)chapter
    mapSelector:(uint32_t)mapSelector stage:(uint32_t)stage stageProgress:(uint32_t)progress
    sceneTypeOverride:(uint32_t)sceneTypeOverride resumeSavedPlayer:(BOOL)resume error:(NSString **)error {
    if(!(self=[super init]))return nil;_directory=[directory copy];_renderer=renderer;
    _storyChapter=chapter;_storyPhase=0;
    dc_story_chapter profile;
    if(dc_story_chapter_profile(chapter,&profile)!=DC_OK) { if(error)*error=@"Story chapter profile rejected";return nil; }
    /* Scene chapters carry their own selectors; the ending scene keeps the
     * previous map/stage from the story state. */
    _mapSelector=profile.map>=0 ? (uint32_t)profile.map : (mapSelector<=8 ? mapSelector : 0);
    _sceneKind=profile.scene;_sceneType=sceneTypeOverride?sceneTypeOverride:profile.scene_type;
    if(sceneTypeOverride==4)_sceneKind=DC_STORY_SCENE_GAMEPLAY;
    else if(sceneTypeOverride==5)_sceneKind=DC_STORY_SCENE_WATCH;
    else if(sceneTypeOverride==6)_sceneKind=DC_STORY_SCENE_NIGHT;
    /* Original settings Reset defaults (0050f6f0): secondary view enabled,
     * wheel step4. Camera limits come from 00512cc0/00479490. */
    _secondaryVisible=(_sceneType>=4&&_sceneType<=6);
    _hairVisible=YES;_cameraTargetVisible=YES;_lastDynamicTexMask=UINT32_MAX;
    _mapAlpha=1.f;_maleBodyAlpha=1.f;_maleGenitalAlpha=1.f;
    _secondaryLimits=(dc_camera_pointer_limits){100,5,20,-30,4};
    _mapLayerVisible[0]=_mapLayerVisible[1]=_mapLayerVisible[2]=YES;
    _backgroundColor[3]=255;
    _stageProgress=progress;_mainIconHover=-1;_lastContextSelection=-1;
    _sceneUITextures=[NSMutableDictionary dictionary];
    _rpp15Textures=[NSMutableDictionary dictionary];
    _storyStage=profile.stage>=0 ? (uint32_t)profile.stage : (stage<=2 ? stage : 0);
    if(dc_game_actor_prefix(_storyStage,&_characterPrefix)!=DC_OK){if(error)*error=@"Actor stage profile rejected";return nil;}
#if DEBUG
    _captureGameplayFrame=[NSProcessInfo.processInfo.environment[@"PORTLAB_CAPTURE_GAMEPLAY"] isEqualToString:@"1"];
#endif
    _cameraFallbacks=[NSMutableDictionary dictionary];
    _gameMenu=(dc_menu_state){.selected=-1,.hover=-1};
    _gameMenuInitialized=YES;
    _naturalGameplayRoute=![[[NSProcessInfo processInfo] environment][@"PORTLAB_EXERCISE_REAL_GAMEPLAY"] isEqualToString:@"1"];
    if(_sceneType>=4&&_sceneType<=6) {
        _sceneUIArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:nil];
        if(!_sceneUIArchive){if(error)*error=@"Original scene UI archive unavailable";return nil;}
        for(NSString *icon in @[@"chara",@"fuku",@"cam",@"sys"])for(NSString *state in @[@"S",@"N"]) {
            NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icon,state];
            if(![self sceneUITexture:name error:error])return nil;
        }
        for(NSString *extra in @[@"k_defo.ema",@"k_roll.ema",@"k_zoom.ema",@"k_move.ema",
                                 @"D_cir.ema",@"kaikan_base.ema",@"kaikan_a.ema",@"kaikan_b.ema",@"kaikan_c.ema"]) {
            [self sceneUITexture:extra error:nil];
        }
    }
    NSError *reason=nil;DCArchive *mapArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_10.pp"]] error:&reason];
    NSString *actorArchiveName=_sceneType==6?@"RPP_05.pp":@"RPP_08.pp";
    DCArchive *actorArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:actorArchiveName]] error:&reason];
    DCArchive *faceArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_09.pp"]] error:nil];
     DCArchive *auxiliaryArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_04.pp"]] error:nil];
     DCArchive *lightArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_07.pp"]] error:nil];
     if(!mapArchive || !actorArchive || !faceArchive) { if(error)*error=reason.localizedDescription;return nil; }
    _map.xxData=[self entry:[NSString stringWithFormat:@"mm00_%02u.xx",_mapSelector] archive:mapArchive error:error];
    _map.xaData=[self entry:[NSString stringWithFormat:@"mn00_%02u.xa",_mapSelector] archive:mapArchive error:nil];
    NSString *bodySuffix=_sceneType==6?@"02":@"01";
    NSString *animationSuffix=_sceneType==4?@"02":(_sceneType==5?@"03":@"04");
    _actor.xxData=[self entry:[NSString stringWithFormat:@"%cm00_%@.xx",_characterPrefix,bodySuffix] archive:actorArchive error:error];
    _actor.xaData=[self entry:[NSString stringWithFormat:@"%cn00_%@.xa",_characterPrefix,animationSuffix] archive:actorArchive error:error];
    NSData *actorPlacement=[self entry:[NSString stringWithFormat:@"%cm00_%@.plst",_characterPrefix,bodySuffix] archive:actorArchive error:nil];
    if(faceArchive) {
        _face.xxData=[self entry:[NSString stringWithFormat:@"%ck00_00.xx",_characterPrefix] archive:faceArchive error:nil];
        _face.xaData=[self entry:[NSString stringWithFormat:@"%cn00_01.xa",_characterPrefix] archive:faceArchive error:nil];
    }
     if(auxiliaryArchive) {
         _eyesData=[self entry:[NSString stringWithFormat:@"%ck00_00.eyes",_characterPrefix] archive:auxiliaryArchive error:nil];
         _neckData=[self entry:[NSString stringWithFormat:@"%cm00_01.neck",_characterPrefix] archive:auxiliaryArchive error:nil];
     }
    if(!_map.xxData || !_actor.xxData || !_actor.xaData)return nil;
    if(![self openModel:&_map staticOnly:(_map.xaData==nil) error:error] || ![self openModel:&_actor staticOnly:NO error:error])return nil;
    if(_sceneType==5) {
        for(unsigned auxiliary=0;auxiliary<2;++auxiliary) {
            NSString *xxName=[NSString stringWithFormat:@"sm%02u_%02u.xx",_storyStage,auxiliary];
            NSString *xaName=[NSString stringWithFormat:@"sn%02u_%02u.xa",_storyStage,auxiliary];
            _watchAuxiliary[auxiliary].xxData=[self entry:xxName archive:actorArchive error:error];
            _watchAuxiliary[auxiliary].xaData=[self entry:xaName archive:actorArchive error:error];
            if(!_watchAuxiliary[auxiliary].xxData||!_watchAuxiliary[auxiliary].xaData||
               ![self openModel:&_watchAuxiliary[auxiliary] staticOnly:NO error:error]||
               (_watchAuxiliary[auxiliary].xaInfo.morph_tracks&&![self buildMorphCaches:&_watchAuxiliary[auxiliary] error:error]))return nil;
            if(dc_model_request(_watchAuxiliary[auxiliary].model,1,0)!=DC_OK){if(error)*error=@"Watch auxiliary animation request failed";return nil;}
            static const uint32_t kAuxLoopClips[]={2,4,6,8,10,11,14,16,20,22,26};
            for(size_t lc=0;lc<sizeof(kAuxLoopClips)/sizeof(kAuxLoopClips[0]);++lc)
                dc_model_set_loop(_watchAuxiliary[auxiliary].model,kAuxLoopClips[lc],0);
             /* Original watch setup keeps the sm/sn roots render-hidden until
              * the corresponding controller/action enables them. Drawing
              * them at actor-root space creates the detached translucent
              * clothing seen on the phone. */
             if(dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1)!=DC_OK){if(error)*error=@"Watch auxiliary visibility setup failed";return nil;}
        }
    }
    if(_face.xxData && _face.xaData && ![self openModel:&_face staticOnly:YES error:error])return nil;
    if(_sceneType>=4&&_sceneType<=6) {
        _rpp15Archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_15.pp"]] error:nil];
        DCArchive *cameraArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_17.pp"]] error:&reason];
        if(!cameraArchive){if(error)*error=@"Original automatic camera archive unavailable";return nil;}
        _autoCamera.xxData=[self entry:@"auto_cam.xx" archive:cameraArchive error:error];
        _autoCamera.xaData=[self entry:@"auto_cam.xa" archive:cameraArchive error:error];
        if(!_autoCamera.xxData||!_autoCamera.xaData||![self openModel:&_autoCamera staticOnly:NO error:error])return nil;
        /* 00522ff0 leaves the auto_cam controller on its original clip0.
         * Clip1 is empty in this asset and would freeze the camera. */
        if(dc_model_request(_autoCamera.model,0,0)!=DC_OK){if(error)*error=@"Original automatic camera animation unavailable";return nil;}
        _cameraTarget.xxData=[self entry:@"target.xx" archive:cameraArchive error:nil];
        if(_cameraTarget.xxData)[self openModel:&_cameraTarget staticOnly:YES error:nil];
    }
    NSString *morphError=nil;
    if(_actor.model && _actor.xaInfo.morph_tracks &&
       ![self buildMorphCaches:&_actor error:&morphError]) {
        if(error)*error=morphError ?: @"Game actor morph initialization failed";return nil;
    }
    if(_face.model && ![self buildMorphCaches:&_face error:&morphError]) { if(error)*error=morphError ?: @"Game morph cache initialization failed";return nil; }
    _actorPlaybackSpeed=1.0f;_watchPart=-1;
    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
    _hoverTargetHit=-1;_cursorIndex=0;_cursorX=512.f;_cursorY=384.f;
    static NSString *const kTargetNodeNames[7]={
        @"AA_On_kao_L",@"a_Kp_Lmune2",@"a_Kp_Rmune2",
        @"AA_On_kokan",@"AA_On_ana",@"AA_On_momo_L",@"AA_On_momo_R"
    };
    for(unsigned t=0;t<7;++t) {
        dc_game_model *slot=(t==0&&_face.model)?&_face:&_actor;
        _targetNodes[t]=[self findNode:slot name:[self characterNode:kTargetNodeNames[t]]];
    }
    _skirtTargetNodes[0]=[self findNode:&_actor name:[self characterNode:@"AA_On_skart_MU"]];
    _skirtTargetNodes[1]=[self findNode:&_actor name:[self characterNode:@"AA_On_skart_UU"]];
    static NSString *const kWatchContactNames[5]={
        @"AA_Nn_buraE_L",@"AA_Nn_buraE_R",@"AA_Nn_pantuE",@"AA_Nn_anaE",@"AA_Nn_pantuF"
    };
    for(unsigned c=0;c<5;++c)
        _watchContactNodes[c]=[self findNode:&_actor name:[self characterNode:kWatchContactNames[c]]];
    _breastNodes[0]=[self findNode:&_actor name:[self characterNode:@"a_Kp_Lmune2"]];
    _breastNodes[1]=[self findNode:&_actor name:[self characterNode:@"a_Kp_Rmune2"]];
    _springBreastNodes[0]=[self findNode:&_actor name:[self characterNode:@"a_Kp_Lmune1"]];
    _springBreastNodes[1]=[self findNode:&_actor name:[self characterNode:@"a_Kp_Rmune1"]];
    _neckNode=[self findNode:&_actor name:[self characterNode:@"a_Kp_kubi2"]];
    _maleEyeTargetNode=[self findNode:&_actor name:@"s_Nn_kamera_S"];
    _eyeNodes[0]=_face.model?[self findNode:&_face name:[self characterNode:@"a_Np_me_R"]]:UINT32_MAX;
    _eyeNodes[1]=_face.model?[self findNode:&_face name:[self characterNode:@"a_Np_me_L"]]:UINT32_MAX;
    _eyeHighlightNodes[0]=_face.model?[self findNode:&_face name:[self characterNode:@"a_On_mehi_R"]]:UINT32_MAX;
    _eyeHighlightNodes[1]=_face.model?[self findNode:&_face name:[self characterNode:@"a_On_mehi_L"]]:UINT32_MAX;
    static NSString *const kHairSpringNames[6]={
        @"a_Kn_kami_L2",@"a_Kn_kami_R2",@"a_Kn_kami_B2",
        @"a_Kn_kami_P3",@"a_Kn_kami_BL2",@"a_Kn_kami_BR2"
    };
    for(unsigned h=0;h<6;++h) {
        _hairSpringNodes[h]=_face.model?[self findNode:&_face name:[self characterNode:kHairSpringNames[h]]]:UINT32_MAX;
        dc_spring_node_init(&_hairSprings[h]);
    }
    for(unsigned b=0;b<2;++b)dc_spring_node_init(&_breastSprings[b]);
    dc_eyeneck_tremor_init(&_eyeTremor);
    dc_eyeneck_controller_init(&_neckController);
    for(unsigned e=0;e<2;++e)dc_eyeneck_controller_init(&_eyeControllers[e]);
    _kosiNode=[self findNode:&_actor name:[self characterNode:@"a_Kn_kosi"]];
    if(dc_model_request(_actor.model,1,0)!=DC_OK) { if(error)*error=@"Game actor animation request failed"; return nil; }
    if(_sceneType==4) {
        static const uint32_t kScene4Chains[][2]={
            {6,7},{7,1},{10,11},{12,13},{14,11},{15,1},{16,1},{17,11},{18,13}
        };
        for(size_t c=0;c<sizeof(kScene4Chains)/sizeof(kScene4Chains[0]);++c)
            dc_model_set_chain(_actor.model,kScene4Chains[c][0],(int32_t)kScene4Chains[c][1]);
        dc_model_set_loop(_actor.model,5,1);
    } else if(_sceneType==6) {
        static const uint32_t kNightChains[][2]={
            {11,12},{12,11},{13,14},{14,13},{19,20},{20,21},{21,20},
            {15,10},{22,10},{23,10},{24,26},{25,26},{29,39},{32,55},
            {40,41},{41,40},{42,43},{43,42},{48,49},{49,50},{50,49},
            {44,39},{51,39},{52,39},{53,10},{54,55},{57,55}
        };
        for(size_t c=0;c<sizeof(kNightChains)/sizeof(kNightChains[0]);++c)
            dc_model_set_chain(_actor.model,kNightChains[c][0],(int32_t)kNightChains[c][1]);
    }
    if((_sceneType==5||_sceneType==6) &&
       dc_scene_motion_init(&_motionState,_sceneType,_storyStage,_stageProgress,1)==DC_OK)
        _motionStateInitialized=YES;
    _actorHeadNode=[self placementNodeFromPLST:actorPlacement model:&_actor];
    if(_actorHeadNode==UINT32_MAX)_actorHeadNode=[self findNode:&_actor name:[self characterNode:@"a_Nz_kubi2"]];
    if(_actorHeadNode==UINT32_MAX)_actorHeadNode=[self findNode:&_actor name:[self characterNode:@"a_Kp_kubi2"]];
    // PLST maps the face source anchor to the animated body neck anchor. The
    // face model already contains sourceBind in its node hierarchy, so remove
    // that bind once before applying the animated target. A source/target bind
    // product double-applies the source translation and floats the head.
    dc_matrix identity=gameIdentity(),sourceBind,sourceInverse;
    dc_status bindStatus=DC_OK;
    uint32_t faceSourceNode=[self findNode:&_face name:[self characterNode:@"a_Nz_kao"]];
    if(bindStatus==DC_OK && faceSourceNode==UINT32_MAX)bindStatus=DC_NOT_FOUND;
    if(bindStatus==DC_OK)bindStatus=dc_model_tick(_face.model,0,0,&identity);
    if(bindStatus==DC_OK)bindStatus=dc_model_global(_face.model,faceSourceNode,&sourceBind);
    if(bindStatus==DC_OK)bindStatus=dc_matrix_inverse_affine(&sourceBind,&sourceInverse);
    if(bindStatus==DC_OK)_faceBindInverse=sourceInverse;
    if(bindStatus!=DC_OK){if(error)*error=@"Face bind-pose attachment failed";return nil;}
    _tearVisible=(_sceneType==6&&_storyStage==2&&_naturalGameplayRoute&&!_editMode);
    [self resetClothingStatesForDefault];
    [self applyClothingVisibility];
    dc_eyeneck_info eyesInfo,neckInfo;dc_eyeneck_span eyesRight,eyesLeft,neckHead;
    if(_face.model && _eyesData && _neckData && (dc_eyeneck_probe(_eyesData.bytes,_eyesData.length,&eyesInfo)!=DC_OK ||
       dc_eyeneck_probe(_neckData.bytes,_neckData.length,&neckInfo)!=DC_OK ||
       eyesInfo.kind!=DC_EYENECK_EYES || eyesInfo.targets!=2 || eyesInfo.records!=5 ||
       neckInfo.kind!=DC_EYENECK_NECK || neckInfo.targets!=1 || neckInfo.records!=3 ||
       dc_eyeneck_target_at(_eyesData.bytes,_eyesData.length,0,&eyesRight)!=DC_OK ||
       dc_eyeneck_target_at(_eyesData.bytes,_eyesData.length,1,&eyesLeft)!=DC_OK ||
       dc_eyeneck_target_at(_neckData.bytes,_neckData.length,0,&neckHead)!=DC_OK ||
       ![self encodedSpan:eyesRight matchesName:[self characterNode:@"a_Np_me_R"] data:_eyesData] ||
       ![self encodedSpan:eyesLeft matchesName:[self characterNode:@"a_Np_me_L"] data:_eyesData] ||
       ![self encodedSpan:neckHead matchesName:[self characterNode:@"a_Kp_kubi2"] data:_neckData] ||
        [self findNode:&_face name:[self characterNode:@"a_Np_me_R"]]==UINT32_MAX ||
        [self findNode:&_face name:[self characterNode:@"a_Np_me_L"]]==UINT32_MAX ||
        [self findNode:&_actor name:[self characterNode:@"a_Kp_kubi2"]]==UINT32_MAX)) {
         if(error)*error=@"Eyes/neck auxiliary binding failed";return nil;
     }
    if(_face.model && _eyesData && _neckData) {
        BOOL slotsOk=YES;
        for(uint32_t r=0;r<5u;++r)if(dc_eyeneck_slot_at(_eyesData.bytes,_eyesData.length,r,&_eyeSlots[r])!=DC_OK)slotsOk=NO;
        for(uint32_t r=0;r<3u;++r)if(dc_eyeneck_slot_at(_neckData.bytes,_neckData.length,r,&_neckSlots[r])!=DC_OK)slotsOk=NO;
        _eyeNeckValid=slotsOk;
    }
    [self loadMapVariantLightForSelector:_mapSelector archive:mapArchive error:nil];
    {
        NSData *glareData=[self entry:[NSString stringWithFormat:@"mm00_%02u.glare",_mapSelector] archive:mapArchive error:nil];
        if(glareData&&dc_glare_probe(glareData.bytes,glareData.length,&_glareInfo)==DC_OK)_hasGlare=YES;
    }
    if(lightArchive) [self loadLightForSelector:_mapSelector archive:lightArchive error:nil];
    for(uint32_t mesh=0;mesh<_actor.info.submeshes;++mesh) {
        uint32_t space=DC_MODEL_SPACE_LOCAL;
        if(dc_model_vertex_space(_actor.model,mesh,&space)!=DC_OK) { if(error)*error=@"Actor skin profile query failed";return nil; }
        if(space==DC_MODEL_SPACE_WORLD)++_actorSkinMeshCount;
    }
    uint32_t anchor=[self findAnchor:&_map];
    dc_game_map_presentation presentation;
    if(!_anchorName.length && dc_game_map_presentation_profile(_mapSelector,&presentation)==DC_OK)
        _anchorName=[NSString stringWithUTF8String:presentation.anchor];
    dc_matrix mapWorld=gameIdentity();
    if(anchor==UINT32_MAX||dc_model_tick(_map.model,0,0,&mapWorld)!=DC_OK||
       dc_model_global(_map.model,anchor,&_actorWorld)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Map %u actor placement anchor is unavailable",_mapSelector];
        return nil;
    }
    _cameraBase=gameIdentity();
    NSString *camPath=[directory stringByAppendingPathComponent:@"RPP_03.pp"];
    DCArchive *camArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:camPath] error:nil];
    NSData *camData=nil;
    NSString *preferred=[self preferredCameraNameForSelector:_mapSelector];
    _cameraSource=preferred;
    for(uint32_t i=0;camArchive && i<camArchive.entryCount;++i) {
        NSString *name=[camArchive asciiNameAtIndex:i];
        if([name caseInsensitiveCompare:preferred]==NSOrderedSame) {camData=[camArchive readEntryAtIndex:i limit:4096 error:nil];break;}
    }
    if(!camData && camArchive) {
        dc_game_map_presentation profile;
        if(dc_game_map_presentation_profile(_mapSelector,&profile)==DC_OK && profile.camera) {
            NSString *fallbackName=(_sceneType==6 && _mapSelector==0)?@"home_5p.cam":
                ((_sceneType==6 && _mapSelector==1)?@"trai_5p.cam":[NSString stringWithUTF8String:profile.camera]);
            for(uint32_t i=0;i<camArchive.entryCount;++i) {
                if([[camArchive asciiNameAtIndex:i] caseInsensitiveCompare:fallbackName]==NSOrderedSame) {
                    camData=[camArchive readEntryAtIndex:i limit:4096 error:nil];
                    if(camData){_cameraSource=fallbackName;break;}
                }
            }
        }
        if(!camData) {
            static const char *prefixes[]={"home_","trai_","toil_","toil_","hote_","roji_","park_","park_","mana_"};
            const char *prefix=_mapSelector<9?prefixes[_mapSelector]:"home_";
            for(uint32_t i=0;i<camArchive.entryCount;++i) {
                NSString *name=[camArchive asciiNameAtIndex:i];
                if([name hasPrefix:[NSString stringWithUTF8String:prefix]]&&[name hasSuffix:@".cam"]) {
                    camData=[camArchive readEntryAtIndex:i limit:4096 error:nil];
                    if(camData){_cameraSource=name;break;}
                }
            }
        }
        if(!camData && camArchive.entryCount>0) {
            for(uint32_t i=0;i<camArchive.entryCount;++i) {
                NSString *name=[camArchive asciiNameAtIndex:i];
                if([name hasSuffix:@".cam"]) {
                    camData=[camArchive readEntryAtIndex:i limit:4096 error:nil];
                    if(camData){_cameraSource=name;break;}
                }
            }
        }
    }
    dc_camera_orbit orbit;
    if(!camData) {
        if(error)*error=[NSString stringWithFormat:@"Map %u camera %@ is unavailable",_mapSelector,preferred];
        return nil;
    }
    if(dc_camera_read_preset(camData.bytes,camData.length,_cameraPreset*3u,&orbit)!=DC_OK) {
        _cameraPreset=0u;
        if(dc_camera_read_preset(camData.bytes,camData.length,0,&orbit)!=DC_OK) {
            if(error)*error=[NSString stringWithFormat:@"Map %u camera %@ is unavailable",_mapSelector,preferred];
            return nil;
        }
    }
    _cameraBase=orbit.base;
    _cameraDistance=orbit.stored_distance;_cameraHeight=orbit.height;_cameraPitch=orbit.pitch;_cameraYaw=orbit.yaw;
    _cameraPresetData=camData;_secondaryCamera=orbit;
    /* Original 4/5/6 callbacks select their own CAM file. Never replace
     * that selection by searching for a camera with more visible triangles. */
    _cameraAutoSelected=_sceneType>=4&&_sceneType<=6;
    _actor.world=_actorWorld;
    _face.world=_actorWorld;
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)_watchAuxiliary[auxiliary].world=_actorWorld;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _actorOriginX=_actorWorld.values[12];_actorOriginY=_actorWorld.values[13];_actorOriginZ=_actorWorld.values[14];
    [self computeWalkBounds];
    [self computeActorFloorOffset];
    _player.x=_actor.world.values[12];_player.z=_actor.world.values[14];
    _player.min_x=_walkMinX;_player.max_x=_walkMaxX;_player.min_z=_walkMinZ;_player.max_z=_walkMaxZ;_player.speed=8;
    _player.map_selector=_mapSelector;
    if(resume)[self loadPlayerState];
    _playerSaveDirty=YES;
    _loaded=YES;return self;
}
- (void)detachModel:(dc_game_model *)slot {
    if(_renderer && slot->baseTextures)for(uint32_t i=0;i<slot->textureCount;++i)if(slot->baseTextures[i])dc_vk_sprite_remove_texture(_renderer,slot->baseTextures[i]);
    freeMorphCaches(slot);
    free(slot->textures);slot->textures=NULL;
    free(slot->baseTextures);slot->baseTextures=NULL;
    slot->textureCount=0;
    if(slot->model)dc_model_close(slot->model);if(slot->xx)dc_xx_close(slot->xx);
    slot->model=NULL;slot->xx=NULL;
}
- (NSString *)attachRenderer:(dc_vk_sprite *)renderer {
    if(!renderer)return @"Game scene renderer is unavailable";
    if(_renderer==renderer&&_map.textureCount&&_map.textures&&_map.textures[0])return nil;
    [self detachRenderer];_renderer=renderer;
    dc_game_model *models[]={&_map,&_actor,&_extraActors[0],&_extraActors[1],&_extraActors[2],&_face,&_extraFaces[0],&_extraFaces[1],&_autoCamera,&_cameraTarget,&_watchAuxiliary[0],&_watchAuxiliary[1]};
    for(size_t m=0;m<sizeof(models)/sizeof(models[0]);++m) {
        dc_game_model *slot=models[m];
        if(!slot->xx||!slot->textureCount)continue;
        if(!slot->textures) {
            slot->textures=calloc(slot->textureCount,sizeof(uintptr_t));
            if(!slot->textures)return @"Game texture handle allocation failed";
        }
        if(!slot->baseTextures) {
            slot->baseTextures=calloc(slot->textureCount,sizeof(uintptr_t));
            if(!slot->baseTextures)return @"Game texture handle allocation failed";
        }
        for(uint32_t i=0;i<slot->textureCount;++i) {
            dc_image_info info;
            dc_status status=dc_xx_image_probe(slot->xx,i,&info);
            if(status!=DC_OK||info.rgba_bytes>64*1024*1024)return @"Game texture profile rejected";
            NSMutableData *pixels=[NSMutableData dataWithLength:info.rgba_bytes];
            status=dc_xx_image_decode(slot->xx,i,pixels.mutableBytes,pixels.length,&info);
            if(status!=DC_OK)return [NSString stringWithFormat:@"Game texture %u decode failed: status=%d",i,status];
            status=dc_vk_sprite_upload(_renderer,info.width,info.height,pixels.bytes,pixels.length,&slot->baseTextures[i]);
            if(status!=DC_OK)return [NSString stringWithFormat:@"Game texture %u upload failed (%ux%u, %zu bytes): status=%d, %s",
                i,info.width,info.height,(size_t)pixels.length,status,dc_vk_sprite_error(_renderer)];
            slot->textures[i]=slot->baseTextures[i];
        }
    }
    _lastDynamicTexMask=UINT32_MAX;
    _needsResumeAtNextTick=YES;
    return nil;
}
- (void)detachRenderer {
    /* All draws are blocking and serialized by the view's render queue.
     * Release GPU handles while their renderer is still alive, including
     * partially initialized models; dealloc can then free the CPU data. */
    dc_game_model *models[]={&_map,&_actor,&_extraActors[0],&_extraActors[1],&_extraActors[2],&_face,&_extraFaces[0],&_extraFaces[1],&_autoCamera,&_cameraTarget,&_watchAuxiliary[0],&_watchAuxiliary[1]};
    for(size_t m=0;m<sizeof(models)/sizeof(models[0]);++m) {
        dc_game_model *slot=models[m];
        for(uint32_t i=0;i<slot->textureCount;++i) {
            if(_renderer && slot->baseTextures && slot->baseTextures[i])dc_vk_sprite_remove_texture(_renderer,slot->baseTextures[i]);
            if(slot->baseTextures)slot->baseTextures[i]=0;
            if(slot->textures)slot->textures[i]=0;
        }
    }
    _lastDynamicTexMask=UINT32_MAX;
    [self detachSceneUI];_renderer=NULL;
    _needsResumeAtNextTick=YES;
}
- (void)dealloc {
    [self savePlayerState];free(_surfaces);[self detachSceneUI];
    [self detachModel:&_map];[self detachModel:&_actor];
    for(unsigned b=0;b<3;++b)[self detachModel:&_extraActors[b]];
    [self detachModel:&_face];
    for(unsigned f=0;f<2;++f)[self detachModel:&_extraFaces[f]];
    [self detachModel:&_autoCamera];[self detachModel:&_cameraTarget];
    [self detachModel:&_watchAuxiliary[0]];[self detachModel:&_watchAuxiliary[1]];
}

- (void)detachSceneUI {
    if(_renderer) {
        for(NSNumber *handle in _sceneUITextures.allValues)dc_vk_sprite_remove_texture(_renderer,handle.unsignedLongLongValue);
        for(NSNumber *handle in _rpp15Textures.allValues)dc_vk_sprite_remove_texture(_renderer,handle.unsignedLongLongValue);
        if(_whiteTexture){dc_vk_sprite_remove_texture(_renderer,_whiteTexture);_whiteTexture=0;}
        if(_glareTexture){dc_vk_sprite_remove_texture(_renderer,_glareTexture);_glareTexture=0;}
    }
    [_sceneUITextures removeAllObjects];
    [_rpp15Textures removeAllObjects];
}
- (uintptr_t)whiteTexture {
    if(_whiteTexture||!_renderer)return _whiteTexture;
    static const uint8_t kWhite[4]={255,255,255,255};
    dc_vk_sprite_upload(_renderer,1,1,kWhite,sizeof(kWhite),&_whiteTexture);
    return _whiteTexture;
}
- (uintptr_t)glareTexture {
    if(_glareTexture||!_renderer)return _glareTexture;
    uint8_t pixels[64*64*4];
    for(unsigned y=0;y<64;++y) {
        float dy=((float)y+0.5f-32.f)/32.f;
        for(unsigned x=0;x<64;++x) {
            float dx=((float)x+0.5f-32.f)/32.f;
            float r=hypotf(dx,dy);
            float falloff=(r<1.f)?powf(1.f-r,2.2f):0.f;
            uint8_t a=(uint8_t)(falloff*255.f+0.5f);
            size_t o=((size_t)y*64u+x)*4u;
            pixels[o]=255u;pixels[o+1]=255u;pixels[o+2]=255u;pixels[o+3]=a;
        }
    }
    dc_vk_sprite_upload(_renderer,64,64,pixels,sizeof(pixels),&_glareTexture);
    return _glareTexture;
}
- (uintptr_t)rpp15Texture:(NSString *)name {
    if(!_renderer||!_rpp15Archive||!name.length)return 0;
    NSString *key=name.lowercaseString;
    NSNumber *cached=_rpp15Textures[key];
    if(cached)return cached.unsignedLongLongValue;
    for(uint32_t i=0;i<_rpp15Archive.entryCount;++i) {
        if([[_rpp15Archive asciiNameAtIndex:i] caseInsensitiveCompare:name]!=NSOrderedSame)continue;
        DCDecodedImage *image=[_rpp15Archive decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:16*1024*1024 error:nil];
        uintptr_t handle=0;
        if(image&&dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&handle)==DC_OK) {
            _rpp15Textures[key]=@(handle);return handle;
        }
        break;
    }
    return 0;
}
- (void)replaceModel:(dc_game_model *)slot textureNamed:(NSString *)origName withRPP15Name:(NSString *)newName {
    if(!slot||!slot->xx||!slot->textures||!slot->baseTextures)return;
    uintptr_t handle=[self rpp15Texture:newName];
    if(!handle)return;
    for(uint32_t i=0;i<slot->info.textures;++i) {
        dc_xx_texture texture;if(dc_xx_texture_at(slot->xx,i,&texture)!=DC_OK)continue;
        NSString *name=[self decodedName:(const uint8_t *)slot->xxData.bytes+texture.name.offset length:texture.name.length];
        if([name caseInsensitiveCompare:origName]==NSOrderedSame) {
            slot->textures[i]=handle;
        }
    }
}
- (void)replaceActorTextureNamed:(NSString *)origName withRPP15Name:(NSString *)newName {
    [self replaceModel:&_actor textureNamed:origName withRPP15Name:newName];
}
- (void)syncDynamicActorTexturesForClip:(uint32_t)curClip bypass:(BOOL)bypass {
    if(!_actor.xx||!_actor.textures||!_actor.baseTextures||!_actor.textureCount)return;
    BOOL virginBlood=(!bypass&&_sceneType==6&&_storyStage==0&&_stageProgress==0&&!_editMode&&_nightPosMode==0u&&curClip>=4u);
    BOOL wetNeko=NO;
    if(!bypass) {
        if(_sceneType==4)wetNeko=(_vibeNekoUsed||_watchNekoVibeVisible||curClip==11u||curClip==13u);
        else if(_sceneType==5)wetNeko=(_vibeNekoUsed||_watchNekoVibeVisible||_stageOutcomeA>=1u||_watchClimaxElapsedMs>0u);
        else if(_sceneType==6)wetNeko=(curClip>=4u);
    }
    BOOL wetBou=(!bypass&&_sceneType==6&&curClip>=4u);
    BOOL inPos2=(_sceneType==6)?(_nightPosMode==1u&&curClip>=6u):(curClip>=33u&&curClip<=57u);
    uint8_t splatter=(!bypass&&_sceneType==6)?MIN(2u,_externalClimaxLevel):0u;
    uint8_t sweatLevel=0u;
    uint32_t multiDynBits=0u;
    if(!bypass) {
        if(_sceneType==4)sweatLevel=_watchVibeSwitch?2u:0u;
        else if(_sceneType==5)sweatLevel=(_watchClimaxElapsedMs>0u||_stageOutcomeA>0u)?4u:(uint8_t)MIN(4,(int)(_watchTouchGauge/25.f));
        else if(_sceneType==6) {
            BOOL inClimax=_inExternalClimax||_externalClimaxLevel>0u||(curClip>=24u&&curClip<=32u)||(curClip>=56u&&curClip<=58u);
            sweatLevel=inClimax?4u:(uint8_t)MIN(4,(int)(_nightExcitement/25.f));
        } else if(_sceneType==7) {
            float maxAr=0.f;
            BOOL anyClimax=(_type7State.phase==DC_TYPE7_PHASE_AFTERGLOW||_type7State.phase==DC_TYPE7_PHASE_MOUTH_HOLD);
            for(uint8_t s=0;s<_type7State.heroine_count;++s) {
                uint8_t h=_type7State.slots[s];
                if(h<3u) {
                    maxAr=fmaxf(maxAr,_type7State.arousal[h]);
                    if(_type7State.metrics[h].heroine_climaxes>0u)anyClimax=YES;
                    uint16_t outE=_type7State.metrics[h].out_ejac+_type7State.metrics[h].oral_out_ejac;
                    multiDynBits|=((uint32_t)MIN(2u,outE)<<(h*2u));
                    if(_type7State.arousal[h]>0.1f||_type7State.phase!=DC_TYPE7_PHASE_IDLE)multiDynBits|=(1u<<(6u+h));
                }
            }
            multiDynBits|=((uint32_t)(_type7PubicMask&7u)<<9)|((uint32_t)(_type7NonVirginMask&7u)<<12)|((_type7State.phase!=DC_TYPE7_PHASE_IDLE)?(1u<<15):0u);
            sweatLevel=anyClimax?4u:(uint8_t)MIN(4,(int)(maxAr*4.f));
        } else if(_sceneType==12) {
            sweatLevel=(_editClimaxCount>0u)?4u:(uint8_t)MIN(4,MAX(0,_editPlayer.cur_step/2));
            multiDynBits=((uint32_t)MIN(2u,_editClimaxCount))|((_editStateCopy.non_virgin[0]?1u:0u)<<2)|
                (((uint32_t)(_editVagPenMask&7u))<<3)|(((uint32_t)(_editAnalPenMask&7u))<<6);
        }
    }
    _sweatSheenLevel=sweatLevel;
    uint32_t editPubicBits=(_sceneType==12)?(((_editAssets.head_pubic_tex[0]==1u)?1u:0u)|(((_editAssets.head_pubic_tex[1]==1u)?1u:0u)<<1)|(((_editAssets.head_pubic_tex[2]==1u)?1u:0u)<<2)):0u;
    uint32_t clothStateBits=((uint32_t)(_clothingTopState&0xfu)<<10)|((uint32_t)(_clothingBraState&3u)<<14)|
        ((uint32_t)(_clothingSkirtState&7u)<<16)|((uint32_t)(_clothingPantyState&7u)<<19)|((uint32_t)(sweatLevel&7u)<<22)|(editPubicBits<<25);
    uint32_t mask=((_hairVisible?1u:0u)|(virginBlood?2u:0u)|(wetNeko?4u:0u)|(wetBou?8u:0u)|(inPos2?16u:0u)|(bypass?32u:0u)|((uint32_t)splatter<<6)|((_outfitVariant&3u)<<8)|clothStateBits)^(multiDynBits*2654435761u);
    if(mask==_lastDynamicTexMask)return;
    _lastDynamicTexMask=mask;
    dc_game_model *dynModels[]={&_actor,&_extraActors[0],&_extraActors[1],&_extraActors[2],&_face,&_extraFaces[0],&_extraFaces[1]};
    for(size_t dm=0;dm<sizeof(dynModels)/sizeof(dynModels[0]);++dm) {
        dc_game_model *ds=dynModels[dm];
        if(ds->textures&&ds->baseTextures) {
            for(uint32_t i=0;i<ds->textureCount;++i)ds->textures[i]=ds->baseTextures[i];
        }
    }
    if(bypass)return;
    if(sweatLevel>0u) {
        NSString *sweatName=[NSString stringWithFormat:@"zt00_%02u_90.bmp",sweatLevel];
        for(size_t dm=0;dm<sizeof(dynModels)/sizeof(dynModels[0]);++dm) {
            [self replaceModel:dynModels[dm] textureNamed:@"zt00_00_90.bmp" withRPP15Name:sweatName];
        }
    }
    if(_sceneType==12) {
        for(uint32_t hIdx=0;hIdx<_editAssets.head_count&&hIdx<3u;++hIdx) {
            uint8_t h=_headHeroines[hIdx];
            char pfx=dc_edit_heroine_prefix(h);
            BOOL shaved=(!_hairVisible||_editAssets.head_pubic_tex[hIdx]==1u);
            NSString *target=[NSString stringWithFormat:@"%ct00_%@_20.bmp",pfx,shaved?@"02":@"01"];
            NSString *tex01=[NSString stringWithFormat:@"%ct00_01_20.bmp",pfx];
            NSString *tex02=[NSString stringWithFormat:@"%ct00_02_20.bmp",pfx];
            dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[hIdx]];
            dc_game_model *fs=[self faceSlotAtIndex:hIdx];
            if(bs) {
                [self replaceModel:bs textureNamed:tex01 withRPP15Name:target];
                [self replaceModel:bs textureNamed:tex02 withRPP15Name:target];
                BOOL hVirginBlood=(h==0u&&_editStateCopy.non_virgin[0]==0u&&(((_editVagPenMask&1u)!=0u)||_editClimaxCount>0u));
                if(hVirginBlood) {
                    [self replaceModel:bs textureNamed:@"bt00_01_08.bmp" withRPP15Name:@"bt00_01_08s.bmp"];
                    [self replaceModel:bs textureNamed:@"st00_01_05.tga" withRPP15Name:@"st00_01_08s.tga"];
                }
                if(h<3u&&(((_editVagPenMask&(1u<<h))!=0u)||((_editAnalPenMask&(1u<<h))!=0u)||((_editPlayer.vibe_mask&(1u<<hIdx))!=0u)||_editClimaxCount>0u)) {
                    for(unsigned k=0;k<4;++k) {
                        NSString *orig=[NSString stringWithFormat:@"%ct%02u_01_21.bmp",pfx,k];
                        NSString *repl=[NSString stringWithFormat:@"%c%c%02u_01_21s.bmp",pfx,hVirginBlood?'g':'t',k];
                        [self replaceModel:bs textureNamed:orig withRPP15Name:repl];
                    }
                    for(unsigned k=0;k<4;++k) {
                        [self replaceModel:bs textureNamed:[NSString stringWithFormat:@"st%02u_01_35.tga",k]
                                             withRPP15Name:[NSString stringWithFormat:@"st%02u_01_35s.tga",k]];
                    }
                }
                if(_editClimaxCount>0u) {
                    char skinCh=(_editClimaxCount>=2u)?'w':'v';
                    if(fs) {
                        [self replaceModel:fs textureNamed:[NSString stringWithFormat:@"%ct00_01_01.bmp",pfx]
                                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_01.bmp",pfx,skinCh]];
                        [self replaceModel:fs textureNamed:[NSString stringWithFormat:@"%ct00_01_01x.bmp",pfx]
                                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_01x.bmp",pfx,skinCh]];
                    }
                    for(unsigned idx=8;idx<=16;++idx) {
                        if(idx==8&&hVirginBlood&&_editClimaxCount<2u)continue;
                        [self replaceModel:bs textureNamed:[NSString stringWithFormat:@"%ct00_01_%02u.bmp",pfx,idx]
                                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_%02u.bmp",pfx,skinCh,idx]];
                    }
                }
            }
        }
    } else if(_sceneType==7) {
        for(uint32_t hIdx=0;hIdx<_type7Assets.head_count&&hIdx<3u;++hIdx) {
            uint8_t h=_headHeroines[hIdx];
            if(h>=3u)continue;
            char pfx=dc_type7_heroine_prefix(h);
            dc_game_model *bs=[self bodySlotAtIndex:_headBodyIndices[hIdx]];
            dc_game_model *fs=[self faceSlotAtIndex:hIdx];
            BOOL shaved=(!_hairVisible||((_type7PubicMask&(1u<<h))!=0u));
            if(bs&&shaved) {
                [self replaceModel:bs textureNamed:[NSString stringWithFormat:@"%ct00_01_20.bmp",pfx]
                                     withRPP15Name:[NSString stringWithFormat:@"%ct00_02_20.bmp",pfx]];
            }
            BOOL hVirginBlood=(h==0u&&(_type7NonVirginMask&1u)==0u&&
                               (_type7State.metrics[0].vaginal_in_ejac>0u||
                                (_type7State.phase!=DC_TYPE7_PHASE_IDLE&&_type7State.hole==0u&&_type7State.rig_mode!=DC_TYPE7_RIG_ORAL&&
                                 (_type7State.active_slot<0?_type7State.slots[0]==0u:_type7State.slots[(uint8_t)_type7State.active_slot]==0u))));
            if(bs&&hVirginBlood) {
                [self replaceModel:bs textureNamed:@"bt00_01_08.bmp" withRPP15Name:@"bt00_01_08s.bmp"];
                [self replaceModel:bs textureNamed:@"st00_01_05.tga" withRPP15Name:@"st00_01_08s.tga"];
            }
            if(bs&&(_type7State.arousal[h]>0.1f||_type7State.phase!=DC_TYPE7_PHASE_IDLE||_type7State.vibe_mask!=0u)) {
                for(unsigned k=0;k<4;++k) {
                    [self replaceModel:bs textureNamed:[NSString stringWithFormat:@"%ct%02u_01_21.bmp",pfx,k]
                                         withRPP15Name:[NSString stringWithFormat:@"%c%c%02u_01_21s.bmp",pfx,hVirginBlood?'g':'t',k]];
                }
            }
            if(bs&&_type7State.phase!=DC_TYPE7_PHASE_IDLE) {
                for(unsigned k=0;k<4;++k) {
                    [self replaceModel:bs textureNamed:[NSString stringWithFormat:@"st%02u_01_35.tga",k]
                                         withRPP15Name:[NSString stringWithFormat:@"st%02u_01_35s.tga",k]];
                }
            }
            uint16_t outE=_type7State.metrics[h].out_ejac+_type7State.metrics[h].oral_out_ejac;
            if(outE>0u) {
                char skinCh=(outE>=2u)?'w':'v';
                if(fs) {
                    [self replaceModel:fs textureNamed:[NSString stringWithFormat:@"%ct00_01_01.bmp",pfx]
                                         withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_01.bmp",pfx,skinCh]];
                    [self replaceModel:fs textureNamed:[NSString stringWithFormat:@"%ct00_01_01x.bmp",pfx]
                                         withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_01x.bmp",pfx,skinCh]];
                }
                if(bs) {
                    for(unsigned idx=8;idx<=16;++idx) {
                        if(idx==8&&hVirginBlood&&outE<2u)continue;
                        [self replaceModel:bs textureNamed:[NSString stringWithFormat:@"%ct00_01_%02u.bmp",pfx,idx]
                                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_%02u.bmp",pfx,skinCh,idx]];
                    }
                }
            }
        }
    } else if(!_hairVisible) {
        NSString *orig=[NSString stringWithFormat:@"%ct00_01_20.bmp",_characterPrefix];
        NSString *repl=[NSString stringWithFormat:@"%ct00_02_20.bmp",_characterPrefix];
        [self replaceActorTextureNamed:orig withRPP15Name:repl];
    }
    if(virginBlood) {
        [self replaceActorTextureNamed:@"bt00_01_08.bmp" withRPP15Name:@"bt00_01_08s.bmp"];
        [self replaceActorTextureNamed:@"st00_01_05.tga" withRPP15Name:@"st00_01_08s.tga"];
        [self replaceActorTextureNamed:@"zt00_00_38.bmp" withRPP15Name:@"zt00_01_38s.bmp"];
        [self replaceActorTextureNamed:@"zt00_00_39.bmp" withRPP15Name:@"zt00_01_39s.bmp"];
    }
    if(wetNeko) {
        for(unsigned k=0;k<4;++k) {
            NSString *orig=[NSString stringWithFormat:@"%ct%02u_01_21.bmp",_characterPrefix,k];
            NSString *repl=[NSString stringWithFormat:@"%c%c%02u_01_21s.bmp",_characterPrefix,virginBlood?'g':'t',k];
            [self replaceActorTextureNamed:orig withRPP15Name:repl];
        }
    }
    if(wetBou) {
        for(unsigned k=0;k<4;++k) {
            NSString *orig=[NSString stringWithFormat:@"st%02u_01_35.tga",k];
            NSString *repl=inPos2?[NSString stringWithFormat:@"sz%02u_01_35.tga",k]:[NSString stringWithFormat:@"st%02u_01_35s.tga",k];
            [self replaceActorTextureNamed:orig withRPP15Name:repl];
        }
    }
    if(splatter>0u) {
        char skinCh=(splatter>=2u)?'w':'v';
        char clothCh=inPos2?((splatter>=2u)?'z':'y'):((splatter>=2u)?'z':'x');
        [self replaceModel:&_face textureNamed:[NSString stringWithFormat:@"%ct00_01_01.bmp",_characterPrefix]
             withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_01.bmp",_characterPrefix,skinCh]];
        [self replaceModel:&_face textureNamed:[NSString stringWithFormat:@"%ct00_01_01x.bmp",_characterPrefix]
             withRPP15Name:[NSString stringWithFormat:@"%c%c00_01_01x.bmp",_characterPrefix,skinCh]];
        [self replaceModel:&_face textureNamed:[NSString stringWithFormat:@"%ct00_01_05.tga",_characterPrefix]
             withRPP15Name:[NSString stringWithFormat:@"%cv00_01_05.tga",_characterPrefix]];
        NSString *hair06Ext=(_characterPrefix=='c')?@"tga":@"bmp";
        [self replaceModel:&_face textureNamed:[NSString stringWithFormat:@"%ct00_01_06.%@",_characterPrefix,hair06Ext]
             withRPP15Name:[NSString stringWithFormat:@"%cv00_01_06.%@",_characterPrefix,hair06Ext]];
        if(_characterPrefix!='a') {
            [self replaceModel:&_face textureNamed:[NSString stringWithFormat:@"%ct00_01_07.tga",_characterPrefix]
                 withRPP15Name:[NSString stringWithFormat:@"%cv00_01_07.tga",_characterPrefix]];
        }
        [self replaceModel:&_face textureNamed:[NSString stringWithFormat:@"%ct00_01_26.bmp",_characterPrefix]
             withRPP15Name:[NSString stringWithFormat:@"%cv00_01_26.bmp",_characterPrefix]];
        for(unsigned idx=8;idx<=16;++idx) {
            if(idx==8&&virginBlood&&splatter<2u)continue;
            NSString *orig=[NSString stringWithFormat:@"%ct00_01_%02u.bmp",_characterPrefix,idx];
            NSString *repl=[NSString stringWithFormat:@"%c%c00_01_%02u.bmp",_characterPrefix,skinCh,idx];
            [self replaceActorTextureNamed:orig withRPP15Name:repl];
        }
        if(splatter>=2u) {
            NSString *orig=[NSString stringWithFormat:@"%cv00_01_24.tga",_characterPrefix];
            NSString *repl=[NSString stringWithFormat:@"%cw00_01_24.tga",_characterPrefix];
            [self replaceActorTextureNamed:orig withRPP15Name:repl];
        }
        if((_storyStage==2)?(_clothingTopState<8u):(_clothingTopState<2u)) {
            [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_41.bmp",_characterPrefix]
                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_41.bmp",_characterPrefix,clothCh]];
        }
        if((_storyStage==2)?(_clothingTopState<8u):(_clothingSkirtState<4u)) {
            [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_42.bmp",_characterPrefix]
                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_42.bmp",_characterPrefix,clothCh]];
        }
        if(_characterPrefix!='a'&&_clothingBraState<2u) {
            [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_46.tga",_characterPrefix]
                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_46.tga",_characterPrefix,clothCh]];
        }
        if(_clothingPantyState<((_sceneType==6)?3u:4u)) {
            [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_47.tga",_characterPrefix]
                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_47.tga",_characterPrefix,clothCh]];
        }
    }
}
- (uintptr_t)sceneUITexture:(NSString *)name error:(NSString **)error {
    NSNumber *cached=_sceneUITextures[name];if(cached)return cached.unsignedLongLongValue;
    for(uint32_t i=0;i<_sceneUIArchive.entryCount;++i) {
        if([[_sceneUIArchive asciiNameAtIndex:i] caseInsensitiveCompare:name]!=NSOrderedSame)continue;
        DCDecodedImage *image=[_sceneUIArchive decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:16*1024*1024 error:nil];
        uintptr_t handle=0;
        if(image&&dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&handle)==DC_OK) {
            _sceneUITextures[name]=@(handle);return handle;
        }
        break;
    }
    if(error)*error=[NSString stringWithFormat:@"Original scene UI texture unavailable: %@",name];return 0;
}
- (NSString *)appendSceneUISprite:(NSString *)name pose:(dc_sprite_pose)pose draws:(dc_vk_geometry_item *)draws count:(size_t *)count storage:(NSMutableArray *)storage {
    NSString *error=nil;uintptr_t texture=[self sceneUITexture:name error:&error];if(!texture)return error;
    dc_sprite_vertex strip[4];if(dc_sprite_build_vertices(&pose,strip)!=DC_OK)return @"Scene UI vertex conversion failed";
    NSMutableData *data=[NSMutableData dataWithLength:6*sizeof(dc_sprite_vertex)];dc_sprite_vertex *v=data.mutableBytes;
    const unsigned order[]={0,1,2,2,1,3};for(unsigned i=0;i<6;++i)v[i]=strip[order[i]];
    [storage addObject:data];draws[(*count)++]=(dc_vk_geometry_item){.vertices=v,.vertex_count=6,.texture=texture,.blend_mode=3,.depth_mode=DC_VK_DEPTH_DISABLED,.cull_mode=DC_VK_CULL_NONE};
    return nil;
}
- (NSString *)appendSceneUI:(dc_vk_geometry_item *)draws count:(size_t *)count storage:(NSMutableArray *)storage viewport:(dc_viewport)viewport {
    _sceneUIDraws=0;if(!((_sceneType>=4&&_sceneType<=7)||_sceneType==12))return nil;
    float scale=viewport.width/1024.f;
    BOOL captureActive=(_captureGameplayFrame&&!_capturedGameplayFrame)||_requestedRenderCapture!=nil;
    if(!_hudHidden||_contextOpen) {
        NSArray<NSString *> *icons=@[@"chara",@"fuku",@"cam",@"sys"];
        uint32_t iconStage=(_sceneType==7)?_type7State.primary_heroine:_storyStage;
        for(unsigned row=1;row<=4;++row) {
            if(_sceneType==12&&(row==1||row==2))continue;
            if(row==2&&_sceneType!=7&&!_stageProgress&&!_editMode)continue;
            if(row==1&&_sceneType==5&&!_stageProgress&&!_editMode&&_naturalGameplayRoute)continue;
            float u0,u1;if(dc_scene_icon_uv(iconStage,row,&u0,&u1)!=DC_OK)return @"Scene icon atlas selection failed";
            dc_sprite_pose p={.width=96*scale,.height=96*scale,.x=viewport.x+920*scale,.y=viewport.y+(328+112*(row-1))*scale,
                .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u0=u0,.u1=u1,.v1=1};
            for(unsigned state=0;state<2;++state) {
                if(state&&_mainIconHover!=(int32_t)row)continue;
                NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icons[row-1],state?@"N":@"S"];
                NSString *error=[self appendSceneUISprite:name pose:p draws:draws count:count storage:storage];if(error)return error;++_sceneUIDraws;
            }
        }
        if(_sceneType==7&&[self sceneUITexture:@"kaikan_base.ema" error:nil]) {
            for(uint8_t g=0;g<_type7State.heroine_count&&g<3u;++g) {
                uint8_t h=_type7State.slots[g];
                if(h>=3u)continue;
                NSString *barName=(h==2)?@"kaikan_a.ema":((h==0)?@"kaikan_b.ema":@"kaikan_c.ema");
                float gx=viewport.x+(8.f+28.f*(float)g)*scale;
                if([self sceneUITexture:barName error:nil]) {
                    float gauge=_type7State.arousal[h]*100.f;
                    float barScaleY=(fminf(99.f,fmaxf(0.f,gauge))+1.f)*0.01f;
                    dc_sprite_pose barPose={.width=24*scale,.height=168*scale,.x=gx,.y=viewport.y+288*scale,
                        .origin_x=0.f,.origin_y=1.f,.scale_x=1,.scale_y=barScaleY,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
                    NSString *error=[self appendSceneUISprite:barName pose:barPose draws:draws count:count storage:storage];
                    if(error)return error;
                    ++_sceneUIDraws;
                }
                dc_sprite_pose basePose={.width=24*scale,.height=176*scale,.x=gx,.y=viewport.y+296*scale,
                    .origin_x=0.f,.origin_y=1.f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
                NSString *error=[self appendSceneUISprite:@"kaikan_base.ema" pose:basePose draws:draws count:count storage:storage];
                if(error)return error;
                ++_sceneUIDraws;
            }
        } else if((_sceneType==5||_sceneType==6)&&[self sceneUITexture:@"kaikan_base.ema" error:nil]) {
            NSString *barName=_storyStage==2?@"kaikan_a.ema":(_storyStage==0?@"kaikan_b.ema":@"kaikan_c.ema");
            if([self sceneUITexture:barName error:nil]) {
                float gauge=(_sceneType==5)?_watchTouchGauge:_nightExcitement;
                float barScaleY=(fminf(99.f,fmaxf(0.f,gauge))+1.f)*0.01f;
                dc_sprite_pose barPose={.width=24*scale,.height=168*scale,.x=viewport.x+8*scale,.y=viewport.y+288*scale,
                    .origin_x=0.f,.origin_y=1.f,.scale_x=1,.scale_y=barScaleY,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
                NSString *error=[self appendSceneUISprite:barName pose:barPose draws:draws count:count storage:storage];
                if(error)return error;
                ++_sceneUIDraws;
            }
            dc_sprite_pose basePose={.width=24*scale,.height=176*scale,.x=viewport.x+8*scale,.y=viewport.y+296*scale,
                .origin_x=0.f,.origin_y=1.f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
            NSString *error=[self appendSceneUISprite:@"kaikan_base.ema" pose:basePose draws:draws count:count storage:storage];
            if(error)return error;
            ++_sceneUIDraws;
        }
        if(!_contextOpen&&!captureActive&&_hoverTargetHit>=0&&_cursorIndex>=0&&[self sceneUITexture:@"D_cir.ema" error:nil]) {
            dc_sprite_pose cirPose={.width=64*scale,.height=64*scale,.x=viewport.x+_cursorX*scale,.y=viewport.y+_cursorY*scale,
                .origin_x=.5f,.origin_y=.5f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
            NSString *error=[self appendSceneUISprite:@"D_cir.ema" pose:cirPose draws:draws count:count storage:storage];
            if(error)return error;
            ++_sceneUIDraws;
        }
    }
    _sceneUIIconDraws=_sceneUIDraws;
    if(_contextOpen)for(unsigned i=0;i<_contextMenu.count;++i) {
        dc_scene_context_item item=_contextMenu.items[i];if(item.resource_id<0)continue;
        dc_sprite_pose p={.width=240*scale,.height=32*scale,.x=viewport.x+item.x*scale,.y=viewport.y+item.y*scale,.origin_x=.9f,.origin_y=.5f,
            .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
        for(unsigned state=0;state<2;++state) {
            if(_sceneType==7) {
                if(i>=_type7Menu.count||!_type7Menu.items[i].stem[0])continue;
                BOOL highlight=(_contextMenu.hover==(int32_t)i)||(_type7Menu.items[i].selected!=0);
                if(state&&!highlight)continue;
                NSString *spriteName=[NSString stringWithFormat:@"%s%c.ema",_type7Menu.items[i].stem,state?'N':'S'];
                NSString *error=[self appendSceneUISprite:spriteName pose:p draws:draws count:count storage:storage];
                if(error)return error;
                ++_sceneUIDraws;
                continue;
            }
            if(state&&_contextMenu.hover!=(int32_t)i)continue;
            NSString *spriteName=nil;
            if(_contextMenu.icon==4&&_editMode&&i>0) {
                spriteName=[NSString stringWithFormat:@"M_z%03d%c.ema",item.resource_id,state?'N':'S'];
            } else {
                uint32_t resourceSceneType=(_contextMenu.icon>=2&&((_sceneType>=4&&_sceneType<=6)||_sceneType==12))?4:_sceneType;
                char resource[32];if(dc_scene_context_resource(resourceSceneType,_contextMenu.icon,item.resource_id,state,resource,sizeof(resource))!=DC_OK)return @"Scene context resource profile failed";
                spriteName=[NSString stringWithUTF8String:resource];
            }
            NSString *error=[self appendSceneUISprite:spriteName pose:p draws:draws count:count storage:storage];if(error)return error;++_sceneUIDraws;
        }
    }
    if(!captureActive&&_cursorIndex>=0&&_cursorIndex<4) {
        static NSString *const kCursorNames[4]={@"k_defo.ema",@"k_roll.ema",@"k_zoom.ema",@"k_move.ema"};
        NSString *cursorName=kCursorNames[_cursorIndex];
        if([self sceneUITexture:cursorName error:nil]) {
            float origin=(_cursorIndex==0)?.1f:0.f;
            dc_sprite_pose curPose={.width=64*scale,.height=64*scale,.x=viewport.x+_cursorX*scale,.y=viewport.y+_cursorY*scale,
                .origin_x=origin,.origin_y=origin,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
            NSString *error=[self appendSceneUISprite:cursorName pose:curPose draws:draws count:count storage:storage];
            if(error)return error;
            ++_sceneUIDraws;
        }
    }
    return nil;
}

- (uint32_t)textureFor:(dc_game_model *)slot mesh:(const dc_xx_submesh *)mesh {
    dc_xx_material material;if(dc_xx_material_at(slot->xx,mesh->material,&material)!=DC_OK)return UINT32_MAX;
    uint32_t texSlot=0;
    BOOL isFaceSlot=(slot==&_face||slot==&_extraFaces[0]||slot==&_extraFaces[1]);
    BOOL isBodySlot=(slot==&_actor||slot==&_extraActors[0]||slot==&_extraActors[1]||slot==&_extraActors[2]);
    if(isFaceSlot&&_faceBlushActive&&material.texture_names[1].length>1) {
        texSlot=1;
    } else if(isBodySlot&&_materialCycleSlot>0&&material.texture_names[2].length>1&&material.texture_names[3].length>1) {
        NSString *matName=[self decodedName:(const uint8_t *)slot->xxData.bytes+material.name.offset length:material.name.length];
        if(![matName hasSuffix:@"_Mn_take"]||_hairVisible)
            texSlot=_materialCycleSlot&3u;
    }
    if(material.texture_names[texSlot].length<=1)texSlot=0;
    for(uint32_t i=0;i<slot->info.textures;++i) {
        dc_xx_texture texture;if(dc_xx_texture_at(slot->xx,i,&texture)!=DC_OK)continue;
        const uint8_t *a=(const uint8_t *)slot->xxData.bytes+material.texture_names[texSlot].offset;
        const uint8_t *b=(const uint8_t *)slot->xxData.bytes+texture.name.offset;size_t an=0,bn=0;
        while(an<material.texture_names[texSlot].length&&a[an]!=255)++an;while(bn<texture.name.length&&b[bn]!=255)++bn;
        if(an==bn&&an<material.texture_names[texSlot].length&&bn<texture.name.length&&!memcmp(a,b,an))return i;
    }
    return UINT32_MAX;
}

- (uint32_t)morphVectorNamed:(NSString *)name model:(dc_game_model *)slot {
    if(!slot->xaData || !name.length) return UINT32_MAX;
    for(uint32_t i=0;i<slot->xaInfo.morph_vector_sets;++i) {
        dc_xa_morph_vector_set view;
        if(dc_xa_morph_vector_set_at(slot->xaData.bytes,slot->xaData.length,i,&view)!=DC_OK) return UINT32_MAX;
        NSString *decoded=[self decodedName:(const uint8_t *)slot->xaData.bytes+view.data_offset length:view.data_length];
        if([decoded isEqualToString:name]) return i;
    }
    return UINT32_MAX;
}

- (uint32_t)morphIndexSetNamed:(NSString *)name model:(dc_game_model *)slot {
    if(!slot->xaData || !name.length) return UINT32_MAX;
    for(uint32_t i=0;i<slot->xaInfo.morph_index_sets;++i) {
        dc_xa_morph_index_set view;
        if(dc_xa_morph_index_set_at(slot->xaData.bytes,slot->xaData.length,i,&view)!=DC_OK) return UINT32_MAX;
        NSString *decoded=[self decodedName:(const uint8_t *)slot->xaData.bytes+view.data_offset length:view.data_length];
        if([decoded isEqualToString:name]) return i;
    }
    return UINT32_MAX;
}

- (NSString *)morphVectorNameForTrack:(uint32_t)track model:(dc_game_model *)slot frame:(float)frame {
    if(!slot->xaData || track>=slot->xaInfo.morph_tracks) return nil;
    dc_xa_morph_track view;
    if(dc_xa_morph_track_at(slot->xaData.bytes,slot->xaData.length,track,&view)!=DC_OK) return nil;
    uint32_t selected=UINT32_MAX,selectedFrame=0;
    for(uint32_t keyIndex=0;keyIndex<view.key_count;++keyIndex) {
        dc_xa_morph_key key;
        if(dc_xa_morph_key_at(slot->xaData.bytes,slot->xaData.length,track,keyIndex,&key)!=DC_OK)return nil;
        uint32_t keyFrame=0;memcpy(&keyFrame,key.raw,sizeof(keyFrame));
        if(selected==UINT32_MAX || ((float)keyFrame<=frame && keyFrame>=selectedFrame)) {
            if((float)keyFrame<=frame || selected==UINT32_MAX) { selected=keyIndex;selectedFrame=keyFrame; }
        }
    }
    if(selected==UINT32_MAX)return nil;
    dc_xa_morph_key key;
    if(dc_xa_morph_key_at(slot->xaData.bytes,slot->xaData.length,track,selected,&key)!=DC_OK)return nil;
    return [self decodedName:(const uint8_t *)slot->xaData.bytes+key.value_offset length:key.value_length];
}

- (BOOL)buildMorphCaches:(dc_game_model *)slot error:(NSString **)error {
    freeMorphCaches(slot);
    if(!slot->xaData || !slot->xaInfo.morph_tracks)return YES;
    dc_status status=dc_morph_open(slot->xx,slot->xxData.bytes,slot->xxData.length,
        slot->xaData.bytes,slot->xaData.length,&slot->morph);
    if(status!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Game morph runtime binding failed: %d",status];
        freeMorphCaches(slot);return NO;
    }
    dc_morph_info info={0};
    status=dc_morph_get_info(slot->morph,&info);
    if(status!=DC_OK||info.tracks!=slot->xaInfo.morph_tracks) {
        if(error)*error=@"Game morph runtime profile mismatch";
        freeMorphCaches(slot);return NO;
    }
    dc_morph_controls controls={0};
    if(dc_morph_get_controls(slot->morph,&controls)==DC_OK) {
        controls.eyes.blend=1.0f;
        controls.mouth.blend=1.0f;
        controls.left_phase=controls.eye_max;
        controls.right_phase=controls.eye_max;
        dc_morph_set_controls(slot->morph,&controls);
    }
    if(slot==&_face) {
        _eyeBlinkState[0]=_eyeBlinkState[1]=0;
        _eyeBlinkWaitTicks[0]=_eyeBlinkWaitTicks[1]=15;
        _eyeBlinkHoldTicks[0]=_eyeBlinkHoldTicks[1]=1;
        _eyeBlinkDuration[0]=_eyeBlinkDuration[1]=0;
        _eyeBlinkEndTick[0]=_eyeBlinkEndTick[1]=0;
    }
    return YES;
}

- (void)updateFaceEyeBlinkAtTick:(uint32_t)tick {
    if(!_face.morph)return;
    dc_morph_controls controls={0};
    if(dc_morph_get_controls(_face.morph,&controls)!=DC_OK)return;
    if(_captureGameplayFrame||_requestedRenderCapture) {
        controls.left_phase=controls.eye_max;
        controls.right_phase=controls.eye_max;
        dc_morph_set_controls(_face.morph,&controls);
        return;
    }
    dc_animation_state actorAnim={0};
    uint32_t clip=(dc_model_get_animation(_actor.model,&actorAnim)==DC_OK)?actorAnim.current:1u;
    uint32_t eyeExpr=0,mouthExpr=0;
    if(_sceneType==4) {
        if(clip==12||clip==13) {
            eyeExpr=3;mouthExpr=5;
        } else if(clip==10||clip==11) {
            eyeExpr=2;mouthExpr=4;
        } else if(clip==1) {
            eyeExpr=0;mouthExpr=_stageProgress?4u:0u;
        } else if(clip==6) {
            eyeExpr=4;mouthExpr=6;
        } else if(clip==5) {
            eyeExpr=_actorPlaybackSpeed>1.35f?4u:3u;mouthExpr=5;
        } else {
            eyeExpr=3;mouthExpr=4;
        }
    } else if(_sceneType==5) {
        if((clip>=160&&clip<=192)||(clip>=220&&clip<=229)) {
            eyeExpr=4;mouthExpr=6;
        } else if((clip>=100&&clip<=151)||_watchDragging) {
            eyeExpr=_watchTouchGauge>60.f?4u:3u;mouthExpr=5;
        } else if(_watchVibeSwitch) {
            eyeExpr=3;mouthExpr=5;
        } else if(_watchNekoVibeVisible||_watchToriVibeVisible) {
            eyeExpr=2;mouthExpr=4;
        } else if(clip==1||clip>=243) {
            eyeExpr=0;mouthExpr=_watchTouchGauge>20.f?4u:0u;
        } else {
            eyeExpr=2;mouthExpr=4;
        }
    } else if(_sceneType==6) {
        if(clip==1) {
            eyeExpr=0;mouthExpr=0;
        } else if(clip==2||clip==6||clip==10||clip==39||clip==55) {
            eyeExpr=2;mouthExpr=(clip>=10)?5u:4u;
        } else if((clip>=24&&clip<=32)||(clip>=56&&clip<=58)) {
            eyeExpr=4;mouthExpr=6;
        } else {
            eyeExpr=_nightExcitement>25.f?4u:3u;mouthExpr=5;
        }
    } else if(_sceneType==7) {
        uint8_t h0=_headHeroines[0]<3u?_headHeroines[0]:_type7State.primary_heroine;
        float ar=_type7State.arousal[h0];
        if(_type7State.phase==DC_TYPE7_PHASE_IDLE) {
            eyeExpr=0;mouthExpr=(ar>0.2f)?4u:0u;
        } else if(_type7State.phase==DC_TYPE7_PHASE_AFTERGLOW||_type7State.phase==DC_TYPE7_PHASE_MOUTH_HOLD) {
            eyeExpr=4;mouthExpr=6;
        } else if(_type7State.phase==DC_TYPE7_PHASE_FAST||ar>0.5f) {
            eyeExpr=4;mouthExpr=5;
        } else {
            eyeExpr=3;mouthExpr=5;
        }
    } else if(_sceneType==12) {
        int32_t em=(_editPlayer.cur_step>=0&&_editPlayer.cur_step<_editStateCopy.step_count)?_editStateCopy.steps[_editPlayer.cur_step].motion_id:6;
        if(em==30||em==31||em==32||em==33||em==60||em==61||em==62||em==70||em==71||em==72) {
            eyeExpr=4;mouthExpr=6;
        } else if(em==10||em==11||(em>=35&&em<=59)||(em>=63&&em<=74)) {
            eyeExpr=4;mouthExpr=5;
        } else if(em>=12||(em>=2&&em<=4)||_editPlayer.vibe_mask!=0u) {
            eyeExpr=3;mouthExpr=5;
        } else {
            eyeExpr=0;mouthExpr=(_editClimaxCount>0u)?4u:0u;
        }
    }
    if(controls.eyes.current!=eyeExpr) {
        controls.eyes.previous=controls.eyes.current;
        controls.eyes.current=eyeExpr;
        controls.eyes.blend_start=tick;
        controls.eyes.blend_end=tick+250u;
        controls.eyes.blend=0.f;
        controls.eyes.state=2;
    }
    if(controls.mouth.current!=mouthExpr) {
        controls.mouth.previous=controls.mouth.current;
        controls.mouth.current=mouthExpr;
        controls.mouth.blend_start=tick;
        controls.mouth.blend_end=tick+250u;
        controls.mouth.blend=0.f;
        controls.mouth.state=2;
    }
    float mp=((_sceneType==7||_sceneType==12)&&_headHeroines[0]<3u&&_voiceMouthPhaseByHeroine[_headHeroines[0]]>0.01f)?
        _voiceMouthPhaseByHeroine[_headHeroines[0]]:_voiceMouthPhase;
    if(mp>0.01f) {
        controls.mouth_phase=fminf(controls.mouth_max,mp);
    } else if(mouthExpr>=5) {
        float breath=0.5f+0.5f*sinf((float)tick*0.008f*fmaxf(1.f,_actorPlaybackSpeed));
        float span=controls.mouth_max-controls.mouth_min;
        controls.mouth_phase=controls.mouth_min+breath*span*(mouthExpr==6?0.85f:0.45f);
    } else {
        controls.mouth_phase=controls.mouth_min;
    }
    for(unsigned i=0;i<2;++i) {
        uint32_t remaining=_eyeBlinkEndTick[i]>=tick?_eyeBlinkEndTick[i]-tick:0;
        float phase=controls.eye_max;
        float span=controls.eye_max-controls.eye_min;
        if(_eyeBlinkState[i]==1) {
            float ratio=_eyeBlinkDuration[i]?(float)remaining/(float)_eyeBlinkDuration[i]:0.f;
            phase=controls.eye_min+ratio*span;
            if(phase<controls.eye_min)phase=controls.eye_min;
            else if(phase>controls.eye_max)phase=controls.eye_max;
        } else if(_eyeBlinkState[i]<0) {
            float ratio=_eyeBlinkDuration[i]?(float)remaining/(float)_eyeBlinkDuration[i]:0.f;
            phase=controls.eye_min+(1.f-ratio)*span;
            if(phase<controls.eye_min)phase=controls.eye_min;
            else if(phase>controls.eye_max)phase=controls.eye_max;
        }
        if(i==0&&(controls.scheduler_mode==0||controls.scheduler_mode==2))controls.left_phase=phase;
        else if(i==1&&(controls.scheduler_mode==0||controls.scheduler_mode==1))controls.right_phase=phase;
    }
    if(controls.link_eyes==1)controls.right_phase=controls.left_phase;
    dc_morph_set_controls(_face.morph,&controls);
    for(unsigned i=0;i<2;++i) {
        if((controls.scheduler_mode==1&&i==0)||(controls.scheduler_mode==2&&i==1)||controls.scheduler_mode==3)continue;
        if(_eyeBlinkEndTick[i]>=tick)continue;
        if(_eyeBlinkState[i]==0) {
            _eyeBlinkDuration[i]=150u+arc4random_uniform(50u);
            _eyeBlinkEndTick[i]=tick+_eyeBlinkDuration[i];
            if(--_eyeBlinkWaitTicks[i]<=0) {
                _eyeBlinkWaitTicks[i]=(int32_t)arc4random_uniform(30u);
                _eyeBlinkHoldTicks[i]=1+(int32_t)arc4random_uniform(3u);
                _eyeBlinkState[i]=1;
            }
        } else if(_eyeBlinkState[i]==1) {
            if(--_eyeBlinkHoldTicks[i]<=0) {
                _eyeBlinkDuration[i]=150u+arc4random_uniform(50u);
                _eyeBlinkEndTick[i]=tick+_eyeBlinkDuration[i];
                _eyeBlinkHoldTicks[i]=1+(int32_t)arc4random_uniform(3u);
                _eyeBlinkState[i]=-1;
            }
        } else {
            _eyeBlinkDuration[i]=150u+arc4random_uniform(50u);
            _eyeBlinkEndTick[i]=tick+_eyeBlinkDuration[i];
            _eyeBlinkState[i]=0;
        }
    }
    if(controls.link_eyes==1) {
        _eyeBlinkDuration[1]=_eyeBlinkDuration[0];
        _eyeBlinkEndTick[1]=_eyeBlinkEndTick[0];
        _eyeBlinkWaitTicks[1]=_eyeBlinkWaitTicks[0];
        _eyeBlinkHoldTicks[1]=_eyeBlinkHoldTicks[0];
        _eyeBlinkState[1]=_eyeBlinkState[0];
    }
}

- (void)updateExtraFaceEyeBlinkAtIndex:(uint32_t)ex tick:(uint32_t)tick {
    if(ex>=2u||!_extraFaces[ex].morph)return;
    dc_morph_controls controls={0};
    if(dc_morph_get_controls(_extraFaces[ex].morph,&controls)!=DC_OK)return;
    if(_captureGameplayFrame||_requestedRenderCapture) {
        controls.left_phase=controls.eye_max;
        controls.right_phase=controls.eye_max;
        dc_morph_set_controls(_extraFaces[ex].morph,&controls);
        return;
    }
    uint8_t h=_headHeroines[ex+1u]<3u?_headHeroines[ex+1u]:0u;
    float ar=(_sceneType==7)?_type7State.arousal[h]:0.f;
    uint32_t eyeExpr=0,mouthExpr=0;
    if(_sceneType==7) {
        if(_type7State.phase==DC_TYPE7_PHASE_IDLE) {
            eyeExpr=0;mouthExpr=(ar>0.2f)?4u:0u;
        } else if(_type7State.phase==DC_TYPE7_PHASE_AFTERGLOW||_type7State.phase==DC_TYPE7_PHASE_MOUTH_HOLD) {
            eyeExpr=4;mouthExpr=6;
        } else if(_type7State.phase==DC_TYPE7_PHASE_FAST||ar>0.5f) {
            eyeExpr=4;mouthExpr=5;
        } else {
            eyeExpr=3;mouthExpr=5;
        }
    } else if(_sceneType==12) {
        int32_t em=(_editPlayer.cur_step>=0&&_editPlayer.cur_step<_editStateCopy.step_count)?_editStateCopy.steps[_editPlayer.cur_step].motion_id:6;
        BOOL isAct=(_editPlayer.active_heroine==h);
        if(isAct&&(em==30||em==31||em==32||em==33||em==60||em==61||em==62||em==70||em==71||em==72)) {
            eyeExpr=4;mouthExpr=6;
        } else if(isAct&&(em==10||em==11||(em>=35&&em<=59)||(em>=63&&em<=74))) {
            eyeExpr=4;mouthExpr=5;
        } else if(isAct||(em>=2&&em<=4)||((_editPlayer.vibe_mask&(1u<<(ex+1u)))!=0)) {
            eyeExpr=3;mouthExpr=5;
        } else {
            eyeExpr=0;mouthExpr=4u;
        }
    }
    if(controls.eyes.current!=eyeExpr) {
        controls.eyes.previous=controls.eyes.current;
        controls.eyes.current=eyeExpr;
        controls.eyes.blend_start=tick;
        controls.eyes.blend_end=tick+250u;
        controls.eyes.blend=0.f;
        controls.eyes.state=2;
    }
    if(controls.mouth.current!=mouthExpr) {
        controls.mouth.previous=controls.mouth.current;
        controls.mouth.current=mouthExpr;
        controls.mouth.blend_start=tick;
        controls.mouth.blend_end=tick+250u;
        controls.mouth.blend=0.f;
        controls.mouth.state=2;
    }
    float mp=(h<3u)?_voiceMouthPhaseByHeroine[h]:0.f;
    if(mp>0.01f) {
        controls.mouth_phase=fminf(controls.mouth_max,mp);
    } else if(mouthExpr>=5) {
        float breath=0.5f+0.5f*sinf((float)(tick+ex*210u)*0.008f*fmaxf(1.f,_actorPlaybackSpeed));
        float span=controls.mouth_max-controls.mouth_min;
        controls.mouth_phase=controls.mouth_min+breath*span*(mouthExpr==6?0.85f:0.45f);
    } else {
        controls.mouth_phase=controls.mouth_min;
    }
    for(unsigned i=0;i<2;++i) {
        uint32_t remaining=_extraEyeBlinkEndTick[ex][i]>=tick?_extraEyeBlinkEndTick[ex][i]-tick:0;
        float phase=controls.eye_max;
        float span=controls.eye_max-controls.eye_min;
        if(_extraEyeBlinkState[ex][i]==1) {
            float ratio=_extraEyeBlinkDuration[ex][i]?(float)remaining/(float)_extraEyeBlinkDuration[ex][i]:0.f;
            phase=fmaxf(controls.eye_min,fminf(controls.eye_max,controls.eye_min+ratio*span));
        } else if(_extraEyeBlinkState[ex][i]<0) {
            float ratio=_extraEyeBlinkDuration[ex][i]?(float)remaining/(float)_extraEyeBlinkDuration[ex][i]:0.f;
            phase=fmaxf(controls.eye_min,fminf(controls.eye_max,controls.eye_min+(1.f-ratio)*span));
        }
        if(i==0&&(controls.scheduler_mode==0||controls.scheduler_mode==2))controls.left_phase=phase;
        else if(i==1&&(controls.scheduler_mode==0||controls.scheduler_mode==1))controls.right_phase=phase;
    }
    if(controls.link_eyes==1)controls.right_phase=controls.left_phase;
    dc_morph_set_controls(_extraFaces[ex].morph,&controls);
    for(unsigned i=0;i<2;++i) {
        if((controls.scheduler_mode==1&&i==0)||(controls.scheduler_mode==2&&i==1)||controls.scheduler_mode==3)continue;
        if(_extraEyeBlinkEndTick[ex][i]>=tick)continue;
        if(_extraEyeBlinkState[ex][i]==0) {
            _extraEyeBlinkDuration[ex][i]=150u+arc4random_uniform(50u);
            _extraEyeBlinkEndTick[ex][i]=tick+_extraEyeBlinkDuration[ex][i];
            if(--_extraEyeBlinkWaitTicks[ex][i]<=0) {
                _extraEyeBlinkWaitTicks[ex][i]=(int32_t)arc4random_uniform(30u);
                _extraEyeBlinkHoldTicks[ex][i]=1+(int32_t)arc4random_uniform(3u);
                _extraEyeBlinkState[ex][i]=1;
            }
        } else if(_extraEyeBlinkState[ex][i]==1) {
            if(--_extraEyeBlinkHoldTicks[ex][i]<=0) {
                _extraEyeBlinkDuration[ex][i]=150u+arc4random_uniform(50u);
                _extraEyeBlinkEndTick[ex][i]=tick+_extraEyeBlinkDuration[ex][i];
                _extraEyeBlinkHoldTicks[ex][i]=1+(int32_t)arc4random_uniform(3u);
                _extraEyeBlinkState[ex][i]=-1;
            }
        } else {
            _extraEyeBlinkDuration[ex][i]=150u+arc4random_uniform(50u);
            _extraEyeBlinkEndTick[ex][i]=tick+_extraEyeBlinkDuration[ex][i];
            _extraEyeBlinkState[ex][i]=0;
        }
    }
    if(controls.link_eyes==1) {
        _extraEyeBlinkDuration[ex][1]=_extraEyeBlinkDuration[ex][0];
        _extraEyeBlinkEndTick[ex][1]=_extraEyeBlinkEndTick[ex][0];
        _extraEyeBlinkWaitTicks[ex][1]=_extraEyeBlinkWaitTicks[ex][0];
        _extraEyeBlinkHoldTicks[ex][1]=_extraEyeBlinkHoldTicks[ex][0];
        _extraEyeBlinkState[ex][1]=_extraEyeBlinkState[ex][0];
    }
}

- (BOOL)applyMorphsToModel:(dc_game_model *)slot frame:(float)frame
    buffers:(dc_mesh_vertex **)buffers counts:(const uint32_t *)counts error:(NSString **)error {
    if(!slot->morph)return YES;
    dc_morph_mesh_buffer *meshBuffers=calloc(slot->info.submeshes?slot->info.submeshes:1,sizeof(*meshBuffers));
    if(!meshBuffers){if(error)*error=@"Game morph buffer descriptors failed";return NO;}
    for(uint32_t i=0;i<slot->info.submeshes;++i) {
        meshBuffers[i]=(dc_morph_mesh_buffer){.vertices=buffers[i],.count=counts[i]};
    }
    dc_status status=dc_morph_tick(slot->morph,frame,_lastTick,meshBuffers,slot->info.submeshes);
    free(meshBuffers);
    if(status!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Game morph runtime apply failed: %d",status];
        return NO;
    }
    return YES;
}
- (uint32_t)sheenTextureFor:(dc_game_model *)slot materialIndex:(uint32_t)matIndex outTCI:(uint32_t *)outTCI {
    if(outTCI)*outTCI=0u;
    if(!slot||!slot->xx||!slot->info.textures)return UINT32_MAX;
    uint8_t op=0,tci=0;
    if(dc_xx_material_stage_tci(slot->xx,matIndex,1,&op,&tci)!=DC_OK||!op||(tci!=1u&&tci!=3u))return UINT32_MAX;
    if(tci==1u&&_sweatSheenLevel==0u)return UINT32_MAX;
    dc_xx_material material;if(dc_xx_material_at(slot->xx,matIndex,&material)!=DC_OK)return UINT32_MAX;
    if(material.texture_names[1].length<=1)return UINT32_MAX;
    const uint8_t *a=(const uint8_t *)slot->xxData.bytes+material.texture_names[1].offset;
    size_t an=0;while(an<material.texture_names[1].length&&a[an]!=255)++an;
    if(!an||an>=material.texture_names[1].length)return UINT32_MAX;
    for(uint32_t i=0;i<slot->info.textures;++i) {
        dc_xx_texture texture;if(dc_xx_texture_at(slot->xx,i,&texture)!=DC_OK)continue;
        const uint8_t *b=(const uint8_t *)slot->xxData.bytes+texture.name.offset;
        size_t bn=0;while(bn<texture.name.length&&b[bn]!=255)++bn;
        if(an==bn&&bn<texture.name.length&&!memcmp(a,b,an)) {
            if(outTCI)*outTCI=tci;
            return i;
        }
    }
    return UINT32_MAX;
}
- (BOOL)buildLightRig:(dc_light_rig *)rig forModel:(dc_game_model *)slot camera:(const dc_camera_matrices *)camera sheenTCI:(uint32_t)sheenTCI {
    if(!rig||!slot||!camera)return NO;
    memset(rig,0,sizeof(*rig));
    rig->camera_eye[0]=camera->world.values[12];
    rig->camera_eye[1]=camera->world.values[13];
    rig->camera_eye[2]=camera->world.values[14];
    rig->view_matrix=camera->view;
    rig->shading_mode=DC_SHADING_D3D9;
    rig->enable_specular=(slot!=&_map)?1u:0u;
    rig->sheen_tci=sheenTCI;
    const dc_xl_d3d_light *src=NULL;uint32_t srcCount=0;const float *amb=NULL;
    dc_matrix anchor=gameIdentity();
    if(slot==&_map) {
        if(!_mapD3DLightCount)return NO;
        src=_mapD3DLights;srcCount=_mapD3DLightCount;amb=_mapGlobalAmbient;anchor=_map.world;
    } else {
        if(!_charD3DLightCount)return NO;
        src=_charD3DLights;srcCount=_charD3DLightCount;amb=_charGlobalAmbient;
        if(!_actor.model||dc_model_global(_actor.model,0,&anchor)!=DC_OK)anchor=_actor.world;
    }
    for(unsigned c=0;c<3;++c)rig->global_ambient[c]=amb[c];
    rig->count=MIN(srcCount,DC_LIGHT_RIG_MAX);
    const float *m=anchor.values;
    for(uint32_t k=0;k<rig->count;++k) {
        const dc_xl_d3d_light *lt=&src[k];
        dc_light_entry *dst=&rig->lights[k];
        dst->d3d_type=lt->d3d_type;
        for(unsigned c=0;c<3;++c) {
            dst->diffuse[c]=lt->diffuse[c];
            dst->specular[c]=lt->specular[c];
            dst->ambient[c]=lt->ambient[c];
            dst->attenuation[c]=lt->attenuation[c];
        }
        dst->position[0]=lt->position[0]*m[0]+lt->position[1]*m[4]+lt->position[2]*m[8]+m[12];
        dst->position[1]=lt->position[0]*m[1]+lt->position[1]*m[5]+lt->position[2]*m[9]+m[13];
        dst->position[2]=lt->position[0]*m[2]+lt->position[1]*m[6]+lt->position[2]*m[10]+m[14];
        dst->direction[0]=lt->direction[0]*m[0]+lt->direction[1]*m[4]+lt->direction[2]*m[8];
        dst->direction[1]=lt->direction[0]*m[1]+lt->direction[1]*m[5]+lt->direction[2]*m[9];
        dst->direction[2]=lt->direction[0]*m[2]+lt->direction[1]*m[6]+lt->direction[2]*m[10];
        dst->range=lt->range;dst->falloff=lt->falloff;dst->theta=lt->theta;dst->phi=lt->phi;
    }
    return YES;
}
- (void)appendMapGlareBloomWithCamera:(const dc_camera_matrices *)camera viewport:(const dc_viewport *)viewport
    draws:(dc_vk_geometry_item *)draws capacity:(size_t)capacity count:(size_t *)count storage:(NSMutableArray *)storage {
    if(!_hasGlare||_bypassLighting||!_mapD3DLightCount||!camera||!viewport||!draws||!count)return;
    const float *lp=NULL;
    for(uint32_t li=0;li<_mapD3DLightCount;++li) {
        if(_mapD3DLights[li].d3d_type!=3u) {
            lp=_mapD3DLights[li].position;
            break;
        }
    }
    if(!lp)return;
    uintptr_t softGlow=[self glareTexture];if(!softGlow)return;
    const float *m=_map.world.values;
    float wp[4]={
        lp[0]*m[0]+lp[1]*m[4]+lp[2]*m[8]+m[12],
        lp[0]*m[1]+lp[1]*m[5]+lp[2]*m[9]+m[13],
        lp[0]*m[2]+lp[1]*m[6]+lp[2]*m[10]+m[14],
        1.f
    },cp[4]={0};
    for(unsigned col=0;col<4;++col)for(unsigned k=0;k<4;++k)cp[col]+=wp[k]*camera->view_projection.values[k*4+col];
    if(!isfinite(cp[3])||cp[3]<=0.5f)return;
    float rw=1.f/cp[3],z=viewport->min_z+cp[2]*rw*(viewport->max_z-viewport->min_z);
    if(!isfinite(z)||z<0.f||z>1.f)return;
    float sx=viewport->x+(cp[0]*rw+1.f)*viewport->width*0.5f;
    float sy=viewport->y+(1.f-cp[1]*rw)*viewport->height*0.5f;
    float baseR=fminf(220.f,fmaxf(32.f,(viewport->width*22.f)*rw*fmaxf(0.5f,_glareInfo.spread)));
    float gain=fminf(1.f,fmaxf(0.1f,_glareInfo.intensity*(_glareInfo.scale>0.f?_glareInfo.scale:1.f)))*_mapAlpha;
    static const float kRadii[3]={0.35f,0.7f,1.25f};
    static const float kAlphas[3]={0.22f,0.12f,0.06f};
    for(unsigned ring=0;ring<3&&*count<capacity;++ring) {
        float r=baseR*kRadii[ring],a=fminf(1.f,gain*kAlphas[ring]);
        uint32_t ab=(uint32_t)(a*255.f+0.5f);if(!ab)continue;
        uint32_t col=(ab<<24)|0x00fff4dc;
        NSMutableData *q=[NSMutableData dataWithLength:6*sizeof(dc_sprite_vertex)];
        dc_sprite_vertex *v=q.mutableBytes;
        dc_sprite_vertex quad[4]={
            {sx-r,sy-r,z,rw,col,0xff000000u,0.f,0.f},
            {sx-r,sy+r,z,rw,col,0xff000000u,0.f,1.f},
            {sx+r,sy-r,z,rw,col,0xff000000u,1.f,0.f},
            {sx+r,sy+r,z,rw,col,0xff000000u,1.f,1.f}
        };
        const unsigned ord[6]={0,1,2,2,1,3};
        for(unsigned k=0;k<6;++k)v[k]=quad[ord[k]];
        [storage addObject:q];
        draws[(*count)++]=(dc_vk_geometry_item){.vertices=v,.vertex_count=6,.texture=softGlow,.blend_mode=1,.depth_mode=DC_VK_DEPTH_AUTO,.cull_mode=DC_VK_CULL_NONE};
    }
}
- (NSString *)append:(dc_game_model *)slot camera:(const dc_camera_matrices *)camera
    viewport:(const dc_viewport *)viewport draws:(dc_vk_geometry_item *)draws capacity:(size_t)capacity count:(size_t *)count storage:(NSMutableArray *)storage triangles:(uint32_t *)triangles {
    dc_status status;
    dc_mesh_vertex **morphVertices=NULL;uint32_t *morphCounts=NULL;
    if(slot->xaInfo.morph_tracks) {
        morphVertices=calloc(slot->info.submeshes?slot->info.submeshes:1,sizeof(*morphVertices));
        morphCounts=calloc(slot->info.submeshes?slot->info.submeshes:1,sizeof(*morphCounts));
        if(!morphVertices||!morphCounts){free(morphVertices);free(morphCounts);return @"Game morph buffer allocation failed";}
        for(uint32_t mesh=0;mesh<slot->info.submeshes;++mesh) {
            dc_xx_submesh meshView;if(dc_model_mesh(slot->model,mesh,&meshView)!=DC_OK) { free(morphVertices);free(morphCounts);return @"Game morph mesh metadata failed"; }
            morphCounts[mesh]=meshView.vertex_count;
            morphVertices[mesh]=calloc(meshView.vertex_count?meshView.vertex_count:1,sizeof(*morphVertices[mesh]));
            if(!morphVertices[mesh] || dc_model_load_source_vertices(slot->model,mesh,morphVertices[mesh],meshView.vertex_count)!=DC_OK) {
                for(uint32_t j=0;j<=mesh;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph vertex load failed";
            }
            /* Keep event-driven UV scrolling from the committed model while
             * replacing only position/normal with the morph result. */
            dc_mesh_vertex *current=calloc(meshView.vertex_count?meshView.vertex_count:1,sizeof(*current));
            if(!current || dc_model_load_vertices(slot->model,mesh,current,meshView.vertex_count)!=DC_OK) {
                free(current);for(uint32_t j=0;j<=mesh;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph UV state load failed";
            }
            for(uint32_t vertex=0;vertex<meshView.vertex_count;++vertex) {
                morphVertices[mesh][vertex].uv[0]=current[vertex].uv[0];
                morphVertices[mesh][vertex].uv[1]=current[vertex].uv[1];
            }
            free(current);
        }
        dc_animation_state actorAnimation;float morphFrame=0;
        if(dc_model_get_animation(slot->model,&actorAnimation)==DC_OK) morphFrame=actorAnimation.frame;
        NSString *morphError=nil;
        if(![self applyMorphsToModel:slot frame:morphFrame buffers:morphVertices counts:morphCounts error:&morphError]) {
            for(uint32_t mesh=0;mesh<slot->info.submeshes;++mesh)free(morphVertices[mesh]);free(morphVertices);free(morphCounts);return morphError ?: @"Game morph application failed";
        }
    }
    for(uint32_t i=0;i<slot->info.submeshes;++i) {
        uint32_t visible;if(dc_model_mesh_visible(slot->model,i,&visible)!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game mesh visibility failed";}if(!visible)continue;
        dc_xx_submesh mesh;dc_material_value material;if(dc_model_mesh(slot->model,i,&mesh)!=DC_OK||dc_model_material(slot->model,mesh.material,&material)!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game mesh metadata failed";}
        dc_xx_mesh_render_state renderState;
        if(dc_xx_mesh_render_state_at(slot->xx,i,&renderState)!=DC_OK)return @"Game mesh render flags rejected";
        if(slot==&_map) {
            material.components[3]*=_mapAlpha;
            if(_mapAlpha<1.f&&material.components[3]>0.f) {
                renderState.transparent_queue=1;
                if(!renderState.blend_mode)renderState.blend_mode=3;
            }
        } else if(slot==&_watchAuxiliary[0]||slot==&_watchAuxiliary[1]) {
            material.components[3]*=_handAlpha;
            if(_handAlpha<1.f&&material.components[3]>0.f) {
                renderState.transparent_queue=1;
                if(!renderState.blend_mode)renderState.blend_mode=3;
            }
        } else {
            dc_xx_material xxMat;
            if(dc_xx_material_at(slot->xx,mesh.material,&xxMat)==DC_OK) {
                NSString *matName=[self decodedName:(const uint8_t *)slot->xxData.bytes+xxMat.name.offset length:xxMat.name.length];
                if(slot==&_actor&&(_sceneType==5||_sceneType==6)&&renderState.transparent_queue&&[matName hasSuffix:@"_Mn_mata_siru"]) {
                    float gauge=(_sceneType==5)?_watchTouchGauge:_nightExcitement;
                    BOOL postClimax=(_sceneType==5)?(_watchClimaxElapsedMs>0u||(_lastClothingClip>=160u&&_lastClothingClip<=193u)):
                        ((_lastClothingClip>=24u&&_lastClothingClip<=32u)||(_lastClothingClip>=55u&&_lastClothingClip<=58u));
                    float alpha=postClimax?1.0f:fminf(1.0f,(fmaxf(0.0f,gauge)+1.0f)*0.01f);
                    material.components[3]*=alpha;
                } else if(_sceneType==7&&renderState.transparent_queue&&[matName hasSuffix:@"_Mn_mata_siru"]&&matName.length>=1) {
                    unichar mp=[matName characterAtIndex:0];
                    uint8_t h=(mp=='b')?0u:((mp=='c')?1u:2u);
                    float ar=_type7State.arousal[h]*100.f;
                    BOOL postClimax=(_type7State.metrics[h].heroine_climaxes>0u);
                    float alpha=postClimax?1.0f:fminf(1.0f,(fmaxf(0.0f,ar)+1.0f)*0.01f);
                    material.components[3]*=alpha;
                } else if(_sceneType==12&&renderState.transparent_queue&&[matName hasSuffix:@"_Mn_mata_siru"]&&matName.length>=1) {
                    material.components[3]*=(_editClimaxCount>0u)?1.0f:0.75f;
                }
                if(matName.length>=6) {
                    unichar pfx=[matName characterAtIndex:0];
                    if((pfx=='s'||pfx=='u'||pfx=='t'||pfx=='v')&&[[matName substringWithRange:NSMakeRange(1,4)] isEqualToString:@"_Mn_"]) {
                        NSString *stem=[matName substringFromIndex:5];
                        BOOL isGenital=([stem isEqualToString:@"bou1"]||[stem isEqualToString:@"bou2"]||[stem isEqualToString:@"tama"]);
                        BOOL isMaleBody=isGenital||([stem isEqualToString:@"take"]||[stem isEqualToString:@"huku"]||
                            [stem isEqualToString:@"karada"]||[stem isEqualToString:@"glass"]||[stem isEqualToString:@"huti"]||
                            [stem isEqualToString:@"kao"]||[stem isEqualToString:@"kami"]||[stem isEqualToString:@"te_L"]||
                            [stem isEqualToString:@"te_R"]||[stem isEqualToString:@"hada"]);
                        if(isMaleBody) {
                            if(_renderingSecondaryViewport||_maleUserHidden||(isGenital&&_maleGenitalUserHidden)) {
                                material.components[3]=0.f;
                            } else {
                                if(_sceneType==6&&pfx=='s') {
                                    if([stem isEqualToString:@"bou1"]&&_nightPosMode==1u)material.components[3]=0.f;
                                    else if([stem isEqualToString:@"bou2"]&&_nightPosMode==0u)material.components[3]=0.f;
                                }
                                float scaleAlpha=isGenital?_maleGenitalAlpha:_maleBodyAlpha;
                                material.components[3]*=scaleAlpha;
                                if(scaleAlpha<1.f&&material.components[3]>0.f) {
                                    renderState.transparent_queue=1;
                                    if(!renderState.blend_mode)renderState.blend_mode=3;
                                }
                            }
                        }
                    }
                }
            }
        }
        if(renderState.hidden||material.components[3]<=0)continue;
        uint8_t depth=renderState.transparent_queue?DC_VK_DEPTH_AUTO_TRANSLUCENT:DC_VK_DEPTH_AUTO;
        uint8_t cull=renderState.two_sided?DC_VK_CULL_NONE:DC_VK_FRONT_NEGATIVE_AREA;
        uint32_t texture=[self textureFor:slot mesh:&mesh];if(slot->info.textures>0&&texture==UINT32_MAX){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game material texture not found";}
        uintptr_t textureHandle=(slot->info.textures>0&&texture<slot->info.textures)?slot->textures[texture]:[self whiteTexture];
        if(!textureHandle){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game material texture handle unavailable";}
        if(*count>=capacity){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game draw buffer capacity exceeded";}
        size_t vertexCount=0;
        uint32_t sheenTCI=0u;
        uint32_t sheenTexIdx=(!_bypassLighting&&slot!=&_cameraTarget)?[self sheenTextureFor:slot materialIndex:mesh.material outTCI:&sheenTCI]:UINT32_MAX;
        uintptr_t sheenHandle=(sheenTexIdx<slot->info.textures)?slot->textures[sheenTexIdx]:0;
        dc_light_rig rig;
        BOOL useLit=(!_bypassLighting&&slot!=&_cameraTarget&&[self buildLightRig:&rig forModel:slot camera:camera sheenTCI:sheenHandle?sheenTCI:0u]);
        if(useLit) {
            BOOL wantSpec=(rig.enable_specular&&material.components[16]>0.f&&
                           (material.components[8]>0.f||material.components[9]>0.f||material.components[10]>0.f)&&[self whiteTexture]!=0);
            if(morphVertices) {
                status=dc_model_project_vertices_lit_clipped(slot->model,i,morphVertices[i],morphCounts[i],
                    &camera->view_projection,viewport,&material,&rig,NULL,NULL,NULL,0,&vertexCount,NULL);
            } else {
                status=dc_model_project_lit_clipped(slot->model,i,&camera->view_projection,viewport,
                    &material,&rig,NULL,NULL,NULL,0,&vertexCount,NULL);
            }
            if(status!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game lit mesh clip query failed";}
            if(!vertexCount)continue;
            NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];
            NSMutableData *specData=wantSpec?[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)]:nil;
            NSMutableData *sheenData=sheenHandle?[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)]:nil;
            uint32_t hasSpec=0u;
            if(morphVertices) {
                status=dc_model_project_vertices_lit_clipped(slot->model,i,morphVertices[i],morphCounts[i],
                    &camera->view_projection,viewport,&material,&rig,
                    vertices.mutableBytes,specData.mutableBytes,sheenData.mutableBytes,vertexCount,&vertexCount,&hasSpec);
            } else {
                status=dc_model_project_lit_clipped(slot->model,i,&camera->view_projection,viewport,
                    &material,&rig,vertices.mutableBytes,specData.mutableBytes,sheenData.mutableBytes,vertexCount,&vertexCount,&hasSpec);
            }
            if(status!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game lit mesh projection failed";}
            [storage addObject:vertices];
            draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=textureHandle,.blend_mode=renderState.blend_mode,.point_filter=renderState.point_filter,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};
            if(sheenData&&sheenHandle&&*count<capacity) {
                [storage addObject:sheenData];
                draws[(*count)++]=(dc_vk_geometry_item){.vertices=sheenData.bytes,.vertex_count=vertexCount,.texture=sheenHandle,.blend_mode=1,.point_filter=renderState.point_filter,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};
            }
            if(specData&&hasSpec&&*count<capacity) {
                [storage addObject:specData];
                draws[(*count)++]=(dc_vk_geometry_item){.vertices=specData.bytes,.vertex_count=vertexCount,.texture=[self whiteTexture],.blend_mode=1,.point_filter=0,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};
            }
            *triangles+=(uint32_t)(vertexCount/3);
            continue;
        }
        if(morphVertices) {
            /* Morphs operate on source-space vertices. The model API then
             * applies the current indexed skin palette once, matching the
             * ordinary render path and preventing detached clothing/face
             * geometry. */
            status=dc_model_project_vertices_clipped(slot->model,i,morphVertices[i],morphCounts[i],
                &camera->view_projection,viewport,gameColor(&material),NULL,0,&vertexCount);
            if(status!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh clip query failed";}
            if(!vertexCount)continue;
            NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];
            status=dc_model_project_vertices_clipped(slot->model,i,morphVertices[i],morphCounts[i],
                &camera->view_projection,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);
            if(status!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh projection failed";}
            [storage addObject:vertices];draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=textureHandle,.blend_mode=renderState.blend_mode,.point_filter=renderState.point_filter,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};*triangles+=(uint32_t)(vertexCount/3);continue;
        }
        status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),NULL,0,&vertexCount);if(status!=DC_OK){return @"Game mesh clip query failed";}if(!vertexCount)continue;
        NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);if(status!=DC_OK)return @"Game mesh projection failed";
        [storage addObject:vertices];
        draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=textureHandle,.blend_mode=renderState.blend_mode,.point_filter=renderState.point_filter,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};
        *triangles+=(uint32_t)(vertexCount/3);
    }
    if(morphVertices){for(uint32_t i=0;i<slot->info.submeshes;++i)free(morphVertices[i]);free(morphVertices);free(morphCounts);}
    return nil;
}
- (BOOL)resolveWatchClothingScrubForZone:(int32_t)zone clip:(uint32_t)curClip
    scrubClip:(uint32_t *)outScrub finishClip:(uint32_t *)outFinish returnClip:(uint32_t *)outReturn
    invert:(BOOL *)outInvert kind:(uint8_t *)outKind {
    if(zone<1||zone>6)return NO;
    BOOL pose7=(curClip==39u);
    BOOL pose4=(curClip==1u||curClip==9u||curClip==15u||curClip==21u||curClip==27u||curClip==33u);
    if(!pose7&&!pose4)return NO;
    BOOL topUndisp=(_storyStage==2)?(_clothingTopState<8u&&(_clothingTopState%2u)==0u):(_clothingTopState==0u);
    BOOL braUndisp=(_storyStage!=2&&_clothingBraState==0u);
    BOOL frontSkirtUndisp=(_storyStage==2)?(_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u):
        (_clothingSkirtState==0u||_clothingSkirtState==2u);
    BOOL backSkirtUndisp=(_storyStage==2)?(_clothingTopState<4u):(_clothingSkirtState==0u||_clothingSkirtState==1u);
    uint32_t sc=0u,fc=0u,rc=pose7?39u:15u;
    BOOL inv=NO;uint8_t k=0u;
    if(pose7) {
        if(zone==1||zone==2) {
            if(topUndisp){sc=266u;fc=267u;rc=39u;inv=NO;k=1u;}
            else if(braUndisp){sc=268u;fc=269u;rc=39u;inv=NO;k=2u;}
        } else if(zone==3||zone==5||zone==6) {
            if(frontSkirtUndisp){sc=272u;fc=273u;rc=39u;inv=NO;k=3u;}
            else if(_clothingPantyState<2u&&zone==3){sc=270u;fc=271u;rc=39u;inv=YES;k=4u;}
        }
    } else {
        if(zone==1) {
            if(topUndisp){sc=250u;fc=251u;rc=15u;inv=NO;k=1u;}
            else if(braUndisp){sc=254u;fc=255u;rc=15u;inv=NO;k=2u;}
        } else if(zone==2) {
            if(topUndisp){sc=252u;fc=253u;rc=15u;inv=NO;k=1u;}
            else if(braUndisp){sc=256u;fc=257u;rc=15u;inv=NO;k=2u;}
        } else if(zone==3||zone==5||zone==6) {
            if(frontSkirtUndisp){sc=258u;fc=259u;rc=21u;inv=NO;k=3u;}
            else if(_clothingPantyState<2u&&zone==3){sc=260u;fc=261u;rc=21u;inv=YES;k=4u;}
        } else if(zone==4) {
            if(backSkirtUndisp){sc=262u;fc=263u;rc=27u;inv=NO;k=5u;}
            else if(_clothingPantyState<2u){sc=264u;fc=265u;rc=27u;inv=YES;k=4u;}
        }
    }
    if(!sc)return NO;
    if(outScrub)*outScrub=sc;
    if(outFinish)*outFinish=fc;
    if(outReturn)*outReturn=rc;
    if(outInvert)*outInvert=inv;
    if(outKind)*outKind=k;
    return YES;
}
- (void)commitWatchScrubKind:(uint8_t)kind {
    if(kind==1u) {
        if(_storyStage==2) {
            if(_clothingTopState<8u&&(_clothingTopState%2u)==0u)++_clothingTopState;
        } else if(_clothingTopState==0u) {
            _clothingTopState=1u;
        }
    } else if(kind==2u) {
        if(_storyStage!=2&&_clothingBraState==0u)_clothingBraState=1u;
    } else if(kind==3u) {
        if(_storyStage==2) {
            if(_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u)_clothingTopState+=2u;
        } else if(_clothingSkirtState==0u||_clothingSkirtState==2u) {
            ++_clothingSkirtState;
        }
    } else if(kind==4u) {
        if(_clothingPantyState<2u)_clothingPantyState=2u;
    } else if(kind==5u) {
        if(_storyStage==2) {
            if(_clothingTopState<4u)_clothingTopState+=4u;
        } else if(_clothingSkirtState==0u||_clothingSkirtState==1u) {
            _clothingSkirtState+=2u;
        }
    }
    [self syncLegacyClothingSummary];
    [self applyClothingVisibility];
    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
}
- (NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput
    width:(uint32_t)width height:(uint32_t)height {
    if(!_loaded)return @"Game scene is not loaded";
    if(!_renderer)return @"Game scene renderer is detached";
    if(_needsResumeAtNextTick){_needsResumeAtNextTick=NO;if(_tickInitialized)[self resumeAtTick:tick];}
    BOOL gameplayScene=(_sceneType==4);
    BOOL cameraScene=(_sceneType>=4&&_sceneType<=7)||_sceneType==12;
    BOOL pcHome=(pcInput.keys[0xc7]&1)!=0,pcEnd=(pcInput.keys[0xcf]&1)!=0;
    BOOL pcPageUp=(pcInput.keys[0xc9]&1)!=0,pcPageDown=(pcInput.keys[0xd1]&1)!=0;
    BOOL pcNum8=(pcInput.keys[0x48]&1)!=0,pcNum4=(pcInput.keys[0x4b]&1)!=0;
    BOOL pcNum2=(pcInput.keys[0x50]&1)!=0,pcNum6=(pcInput.keys[0x4d]&1)!=0;
    BOOL pcArrowUp=(pcInput.keys[0xc8]&1)!=0,pcArrowLeft=(pcInput.keys[0xcb]&1)!=0;
    BOOL pcArrowDown=(pcInput.keys[0xd0]&1)!=0,pcArrowRight=(pcInput.keys[0xcd]&1)!=0;
    BOOL touchExercise=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"];
    if(pcInput.keys[0x2e]==3) {
        _pendingUserScreenshot=YES;
        _pendingEffectSlot=100u;_hasPendingEffect=YES;
        if(touchExercise)[self requestRenderCapture:@"gameplay-capture.png"];
    }
    if(cameraScene&&pcInput.keys[1]==3&&!_pendingSystemAction&&!_type7SwapPending&&!_characterAction.exit_pending&&!_characterAction.transition_pending&&
       (!_motionStateInitialized||!_motionState.transition_pending)){
        _contextOpen=NO;_watchDragging=NO;_nightDragging=NO;
        _pendingSystemAction=5;
        if(!self.transitionScene||[self.transitionScene requestTransition:3 tick:tick]!=DC_OK)
            return @"Original dummy-screen transition failed";
    }
    BOOL anyMouseHeld=(pcInput.mouse[0]&1)||(pcInput.mouse[1]&1)||(pcInput.mouse[2]&1);
    if(pcInput.keys[0x3b]==3)_f1UsedForCamera=NO;
    if((pcInput.keys[0x3b]&1)!=0&&(anyMouseHeld||pcInput.wheel!=0||pcNum4||pcNum6||pcNum8||pcNum2||
       pcPageUp||pcPageDown||pcHome||pcEnd||pcArrowLeft||pcArrowRight||pcArrowUp||pcArrowDown)) {
        _f1UsedForCamera=YES;
    }
    BOOL f1OpenConfig=touchExercise?(pcInput.keys[0x3b]==3&&!anyMouseHeld):(pcInput.keys[0x3b]==2&&!_f1UsedForCamera&&!anyMouseHeld);
    if(cameraScene&&(f1OpenConfig||(pcInput.keys[0x3c]==3&&!_editMode))&&!_pendingSystemAction&&!_type7SwapPending&&
       !_characterAction.exit_pending&&!_characterAction.transition_pending&&(!_motionStateInitialized||!_motionState.transition_pending)){
        _contextOpen=NO;_watchDragging=NO;_nightDragging=NO;
        _pendingSystemAction=f1OpenConfig?3:4;
        if(!self.transitionScene||[self.transitionScene requestTransition:2 tick:tick]!=DC_OK)
            return @"Original direct system transition failed";
        _pendingEffectSlot=0;_hasPendingEffect=YES;
    }
    float padDelta=_tickInitialized?fminf((tick-_lastTick)/1000.f,.1f):0;
    if(controller.pressed&DC_PAD_B){
        touching=NO;_inputInitialized=NO;
        if(_interactionState.active) {
            _interactionState.active=0;_interactionActive=NO;
            if(dc_model_request(_actor.model,1,tick)!=DC_OK)return @"Game interaction cancel failed";
        }
    }
    if(gameplayScene && controller.pressed&DC_PAD_X){_playerSaveDirty=YES;_manualSaveCompleted=[self savePlayerState];}
    if(controller.pressed&DC_PAD_Y){_padCameraYaw=0;_padCameraPitch=0;_padCameraZoom=0;_padCameraHeight=0;}
    /* Context-menu dismissal never advances the chapter. */
    if(gameplayScene && (controller.pressed&DC_PAD_B)&&_storyPhase==1) {
        _storyPhase=0;_interactionCompleted=NO;_interactionState.completed=0;
        _chapterEndAction=0;
    }
    /* Non-gameplay callbacks have separate state machines. Do not invent
     * tap-to-skip behavior for watch/night/ending chapters. */
    BOOL secondaryOwnsPointer=NO;
    BOOL primaryOwnsPointer=NO;
    BOOL pcCtrl=((pcInput.keys[0x1d]&1)||(pcInput.keys[0x9d]&1))!=0;
    int32_t cachedActorHit=-1;
    if(cameraScene) {
        for(unsigned i=0;i<3;++i) {
            if(pcInput.keys[2+i]==3) {
                _mapLayerVisible[i]=!_mapLayerVisible[i];
                NSString *mapError=[self applyMapLayerVisibility];
                if(mapError)return mapError;
            }
        }
        if(pcInput.keys[5]==3) {
            if(_sceneType==5)_watchAuxUserHidden=!_watchAuxUserHidden;
            else if(_sceneType==6||_sceneType==7||_sceneType==12)_maleUserHidden=!_maleUserHidden;
        }
        if(pcInput.keys[6]==3) {
            if(_sceneType==6||_sceneType==7||_sceneType==12)_maleGenitalUserHidden=!_maleGenitalUserHidden;
        }
        if(pcInput.keys[0x39]==3&&_sceneType!=12&&!touchExercise&&!_contextOpen) {
            _hudHidden=!_hudHidden;
        }
        if(pcInput.keys[0x2f]==3) {
            _secondaryVisible=!_secondaryVisible;++_secondaryVisibilityChanges;
#if DEBUG
            if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
                [self requestRenderCapture:_secondaryVisible?@"gameplay-secondary-visible-native.png":@"gameplay-secondary-hidden-native.png"];
#endif
        }
        if(_editMode&&!touchExercise&&!_pendingSystemAction&&!_editExitFadeStarted&&!_characterAction.exit_pending&&!_characterAction.transition_pending) {
            if(pcInput.keys[0x35]==3)[self toggleEditPauseOrResetSpeed];
            if(pcInput.keys[0x2b]==3)[self cycleEditSpeedMode];
            if(_sceneType==12&&!_contextOpen&&(pcInput.keys[0x39]==3||pcInput.keys[0x1c]==3)) {
                dc_edit_step_plan skipPlan={0};
                if(dc_edit_player_skip_step(&_editPlayer,&_editStateCopy,&skipPlan)==DC_OK) {
                    NSString *skipErr=[self applyEditStepPlan:&skipPlan tick:tick];
                    if(skipErr)return skipErr;
                }
            }
        }
        float inputScale=fminf((float)width/1024.f,(float)height/768.f);
        float mx=((x+1)*.5f*width-(width-1024*inputScale)*.5f)/inputScale;
        float my=((1-y)*.5f*height-(height-768*inputScale)*.5f)/inputScale;
        if(pcInput.pointer_active||touching||pcInput.mouse[0]||pcInput.mouse[1]||pcInput.mouse[2]){
            _cursorX=fmaxf(0.f,fminf(1024.f,mx));
            _cursorY=fmaxf(0.f,fminf(768.f,my));
        }
        BOOL held=(pcInput.mouse[0]&1)||(pcInput.mouse[1]&1)||(pcInput.mouse[2]&1);
        BOOL inside=mx>=0&&mx<=352&&my>=504&&my<=768;
        BOOL press=pcInput.mouse[0]==3||pcInput.mouse[1]==3||pcInput.mouse[2]==3;
        BOOL iconRegion=mx>=880&&my>=300&&my<=768;
        if(_sceneType==12&&!touchExercise&&!_pendingSystemAction&&!_editExitFadeStarted) {
            if(pcInput.mouse[0]==3&&!pcInput.mouse[1]&&!pcInput.mouse[2]&&!pcCtrl&&!_contextOpen&&!iconRegion&&!(_secondaryVisible&&inside)) {
                _editClickCandidate=YES;_editClickOriginX=mx;_editClickOriginY=my;
            }
            if(_editClickCandidate&&(pcCtrl||_contextOpen||pcInput.mouse[1]||pcInput.mouse[2]||hypotf(mx-_editClickOriginX,my-_editClickOriginY)>5.f)) {
                _editClickCandidate=NO;
            }
            if(pcInput.mouse[0]==2&&_editClickCandidate) {
                _editClickCandidate=NO;
                dc_edit_step_plan skipPlan={0};
                if(dc_edit_player_skip_step(&_editPlayer,&_editStateCopy,&skipPlan)==DC_OK) {
                    NSString *skipErr=[self applyEditStepPlan:&skipPlan tick:tick];
                    if(skipErr)return skipErr;
                }
            } else if(!(pcInput.mouse[0]&1)) {
                _editClickCandidate=NO;
            }
        }
        cachedActorHit=((_sceneType==5||_sceneType==6)&&!_contextOpen&&!iconRegion&&!(_secondaryVisible&&inside)&&!pcCtrl&&!_characterAction.exit_pending&&!_characterAction.transition_pending)?[self motionHitIndexAtX:x y:y width:width height:height]:-1;
        int32_t actorHit=cachedActorHit;
        dc_animation_state scene6Anim={0};
        if(_sceneType==6&&_actor.model) {
            dc_model_get_animation(_actor.model,&scene6Anim);
            if(_contextOpen&&(_contextMenu.icon==1||_contextMenu.icon==2)&&
               ((scene6Anim.current>=27&&scene6Anim.current<=32)||
                (scene6Anim.current>=56&&scene6Anim.current<=57)||
                scene6Anim.current==54))
                _contextOpen=NO;
        }
        dc_animation_state scene5Anim={0};
        if(_sceneType==5&&_actor.model)dc_model_get_animation(_actor.model,&scene5Anim);
        BOOL scene5CanStartScrub=(_sceneType==5&&!pcCtrl&&_watchScrubState==0u&&_watchPart<0&&!_watchDragging&&
                                  !pcInput.wheel&&pcInput.mouse[1]==3&&!pcInput.mouse[0]&&actorHit>=1&&
                                  [self resolveWatchClothingScrubForZone:actorHit clip:scene5Anim.current
                                      scrubClip:NULL finishClip:NULL returnClip:NULL invert:NULL kind:NULL]);
        BOOL scene6InPos=(scene6Anim.current>=10&&scene6Anim.current<=23)||(scene6Anim.current>=39&&scene6Anim.current<=53);
        BOOL scene6ThrustTarget=(!_naturalGameplayRoute||touchExercise)?YES:(actorHit>=0||_nightDragging);
        BOOL scene6Interactive=((scene6InPos&&scene6ThrustTarget)||_nightDragging||((scene6Anim.current==1||scene6Anim.current==26)&&actorHit>=0));
        if(!held&&!pcInput.wheel)_pointerCameraOwner=0;
        if(!_pointerCameraOwner&&!_contextOpen&&(press||pcInput.wheel)) {
            /* Scene 4 left-drag in the main viewport rotates the primary camera
             * (00513690). Scene 5/6 left presses on an active character target
             * belong to the actor-motion callback unless Ctrl is held (00492854). */
            if(_secondaryVisible&&inside)
                _pointerCameraOwner=2;
            else if(iconRegion&&(pcInput.mouse[0]||pcInput.mouse[1]))
                _pointerCameraOwner=1;
            else if(_sceneType==5&&!pcCtrl&&
                    (_watchScrubState!=0u||scene5CanStartScrub||
                     (!pcInput.wheel&&pcInput.mouse[0]&&!pcInput.mouse[1]&&(actorHit>=0||_watchPart>=0||_watchDragging))||
                     (!pcInput.wheel&&pcInput.mouse[1]==3&&!pcInput.mouse[0]&&_watchPart>=0)||
                     (pcInput.wheel&&!pcInput.mouse[1]&&_watchPart>=0)))
                _pointerCameraOwner=0;
            else if(_sceneType==6&&!pcCtrl&&!pcInput.mouse[1]&&
                    ((!pcInput.wheel&&pcInput.mouse[0]&&scene6Interactive)||
                     (pcInput.wheel&&(scene6InPos||scene6Anim.current==26))))
                _pointerCameraOwner=0;
            else if(_sceneType==7&&!pcCtrl&&!pcInput.mouse[1]&&!_type7SwapPending&&
                    pcInput.wheel&&_type7State.phase!=DC_TYPE7_PHASE_IDLE)
                _pointerCameraOwner=0;
            else
                _pointerCameraOwner=3;
        }
        if(_sceneType==7&&_pointerCameraOwner==0&&!_contextOpen&&!pcCtrl&&!pcInput.mouse[1]&&
           pcInput.wheel!=0&&_type7State.phase!=DC_TYPE7_PHASE_IDLE) {
            float wheelStep=(_secondaryLimits.wheel_step>0.f?_secondaryLimits.wheel_step:4.f)*0.05f;
            dc_type7_adjust_speed(&_type7State,pcInput.wheel>0?wheelStep:-wheelStep);
            _actorPlaybackSpeed=_type7State.speed;
        }
        dc_camera_pointer_limits cameraWheelLimits=_secondaryLimits;
        if(_pointerCameraOwner==2&&!_contextOpen&&(held||pcInput.wheel)) {
            secondaryOwnsPointer=YES;
            if(_secondaryCameraMode!=2) {
                dc_camera_pointer_input motion={pcInput.dx,pcInput.dy,pcInput.wheel,
                    pcInput.mouse[0],pcInput.mouse[1],pcInput.mouse[2],(pcInput.keys[0x3b]&1)!=0};
                dc_camera_orbit next;
                if(dc_camera_secondary_pointer(&_secondaryCamera,&cameraWheelLimits,&motion,&next)!=DC_OK)return @"Original secondary camera pointer update failed";
                if(memcmp(&next,&_secondaryCamera,sizeof(next))) {
                    _secondaryPointerBefore=_secondaryCamera;_secondaryLastPointer=motion;
                    _secondaryLastPointerOperation=(motion.left&1)?((motion.right&1)?2:0):((motion.right&1)?1:((motion.middle&1)?2:3));
                    _secondaryCamera=next;++_secondaryPointerUpdates;
#if DEBUG
                    if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"]) {
                        if(_secondaryLastPointerOperation==0&&motion.left==1)[self requestRenderCapture:@"gameplay-secondary-pointer-native.png"];
                        else if(_secondaryLastPointerOperation==1&&motion.right==1)[self requestRenderCapture:@"gameplay-secondary-right-native.png"];
                        else if(_secondaryLastPointerOperation==2)[self requestRenderCapture:@"gameplay-secondary-pan-native.png"];
                        else if(_secondaryLastPointerOperation==3)[self requestRenderCapture:@"gameplay-secondary-wheel-native.png"];
                    }
#endif
                }
            }
        }
        if(_pointerCameraOwner==3&&!_contextOpen&&(held||pcInput.wheel)) {
            primaryOwnsPointer=YES;
            dc_camera_orbit current=[self activeCameraOrbit],next;
            dc_camera_pointer_input motion={pcInput.dx,pcInput.dy,pcInput.wheel,
                pcInput.mouse[0],pcInput.mouse[1],pcInput.mouse[2],(pcInput.keys[0x3b]&1)!=0};
            float primaryAnchor[3]={_actor.world.values[12],_actor.world.values[13],_actor.world.values[14]};
            if(dc_camera_primary_pointer(&current,primaryAnchor,&cameraWheelLimits,&motion,&next)!=DC_OK)
                return @"Original primary camera pointer update failed";
            if(memcmp(&next,&current,sizeof(next))){
                [self adoptCameraOrbit:next];++_cameraActionCount;
                if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
                    [self requestRenderCapture:@"gameplay-primary-pointer-native.png"];
            }
        }
        _hoverTargetHit=-1;
        if(!_contextOpen&&_pointerCameraOwner==0&&!held) {
            if(_sceneType==5&&!_watchDragging&&actorHit>=0&&actorHit<7)_hoverTargetHit=actorHit;
            else if(_sceneType==6&&(scene6Anim.current==1||scene6Anim.current==26)&&actorHit>=0)_hoverTargetHit=actorHit;
        }
    }
    if(_sceneType==5&&_motionStateInitialized&&!_contextOpen&&
       !_characterAction.exit_pending&&!_characterAction.transition_pending) {
        uint32_t watchDelta=_tickInitialized?(tick-_lastTick):0u;
        if(_watchElapsedMs<100000u)_watchElapsedMs=MIN(100000u,_watchElapsedMs+watchDelta);
        static const uint32_t kWatchState1IdleClips[7]={9,15,21,27,33,39,39};
        static const uint32_t kWatchHoverClips[7]={55,61,67,73,79,85,91};
        static const uint32_t kWatchEntryFromIdle[7][6]={
            {50,50,52,53,54,54},
            {56,56,58,59,60,60},
            {62,62,64,65,66,66},
            {68,70,68,71,72,72},
            {74,76,77,74,78,78},
            {80,82,83,84,80,80},
            {86,88,89,90,86,86}
        };
        static const uint32_t kWatchRetractClips[7]={51,57,63,69,75,81,87};
        static const uint32_t kWatchDragEntryClips[7]={100,108,116,124,132,140,144};
        static const uint32_t kWatchDragLoopClips[7]={101,109,117,125,133,141,145};
        static const uint32_t kWatchDragFastLoopClips[7]={102,110,118,126,134,142,146};
        static const uint32_t kWatchReleaseClips[7]={103,111,119,127,135,143,147};
        static const uint32_t kWatchAuxDragClips[7]={2,4,4,6,8,26,26};
        static const uint32_t kWatchAuxReleaseClips[7]={3,5,5,7,9,27,27};
        static const uint32_t kWatchClimaxClips[7]={160,165,170,175,180,185,189};
        static const uint32_t kWatchClimaxEndClips[7]={164,169,174,179,184,188,192};
        dc_animation_state anim={0};
        if(dc_model_get_animation(_actor.model,&anim)==DC_OK)
            _motionState.clip=anim.current;
        BOOL inState1Idle=(anim.current==1||anim.current==9||anim.current==15||anim.current==21||anim.current==27||anim.current==33||anim.current==39);
        if(_watchPart<0&&_watchScrubState==0u&&inState1Idle) {
            if(_naturalGameplayRoute&&!touchExercise) {
                _actorPlaybackSpeed=_watchVibeSwitch?1.65f:((_watchNekoVibeVisible||_watchToriVibeVisible)?1.25f:1.0f);
                if(_stageProgress>=2u||_editMode) {
                    if(anim.current==39u) {
                        _watchPose7Active=YES;
                        _watchPose7DurationMs+=watchDelta;
                        if(_watchPose7DurationMs>=30000u) {
                            _watchPose7Active=NO;_watchPose7DurationMs=0u;_watchPose7IdleMs=0u;
                            static const uint32_t kPose7Exits[5]={40,41,42,43,44};
                            static const uint32_t kPose7Targets[5]={9,15,21,27,33};
                            uint32_t r=arc4random_uniform(5u);
                            dc_model_set_chain(_actor.model,kPose7Exits[r],(int32_t)kPose7Targets[r]);
                            _motionState.clip=kPose7Exits[r];
                            dc_model_request(_actor.model,kPose7Exits[r],tick);
                            ++_characterAnimationStarts;
                        }
                    } else {
                        _watchPose7Active=NO;_watchPose7DurationMs=0u;
                        BOOL frontSkirtDown=(_storyStage==2)?
                            (_clothingTopState==0u||_clothingTopState==1u||_clothingTopState==4u||_clothingTopState==5u):
                            (_clothingSkirtState==0u||_clothingSkirtState==2u);
                        _watchPose7IdleMs+=watchDelta;
                        if(_watchPose7IdleMs>=10000u) {
                            _watchPose7IdleMs=0u;
                            if(frontSkirtDown&&arc4random_uniform(10u)<4u) {
                                uint32_t stance=(anim.current==15u)?1u:((anim.current==21u)?2u:((anim.current==27u)?3u:((anim.current==33u)?4u:0u)));
                                static const uint32_t kPose7Entries[5]={14,20,26,32,38};
                                dc_model_set_chain(_actor.model,kPose7Entries[stance],39);
                                _motionState.clip=kPose7Entries[stance];
                                dc_model_request(_actor.model,kPose7Entries[stance],tick);
                                _watchPose7Active=YES;
                                ++_characterAnimationStarts;
                            }
                        }
                    }
                } else {
                    BOOL anyDisplaced=(_outfitVariant>0u||_clothingTopState>0u||_clothingBraState>0u||_clothingSkirtState>0u||_clothingPantyState>0u);
                    if(anim.current!=1u&&anim.current!=39u&&!_watchNekoVibeVisible&&!_watchToriVibeVisible&&_watchRedressCount<10u&&anyDisplaced) {
                        _watchRedressTimerMs+=watchDelta;
                        if(_watchRedressTimerMs>=12000u) {
                            _watchRedressTimerMs=0u;
                            ++_watchRedressCount;
                            [self resetClothingStatesForDefault];
                            [self applyClothingVisibility];
                            _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                            _pendingEffectSlot=2u;_hasPendingEffect=YES;
                        }
                    } else {
                        _watchRedressTimerMs=0u;
                    }
                }
            }
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
            if(_watchPendingExitAfterClimax) {
                _watchPendingExitAfterClimax=NO;
                _pendingEffectSlot=28u;_hasPendingEffect=YES;
                _characterAction.exit_pending=1;_exitSoundStartTick=tick;
            }
        } else {
            _watchRedressTimerMs=0u;
        }
        float inputScale=fminf((float)width/1024.f,(float)height/768.f);
        float mx=((x+1)*.5f*width-(width-1024*inputScale)*.5f)/inputScale;
        float my=((1-y)*.5f*height-(height-768*inputScale)*.5f)/inputScale;
        BOOL inside=mx>=0&&mx<=352&&my>=504&&my<=768;
        BOOL iconRegion=mx>=880&&my>=300&&my<=768;
        int32_t hit=(_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1]&&!iconRegion&&!(_secondaryVisible&&inside))?cachedActorHit:-1;
        if(_watchScrubState==0u&&_pointerCameraOwner==0&&!pcCtrl&&pcInput.mouse[1]==3&&!pcInput.mouse[0]&&
           _watchPart<0&&!_watchDragging&&!iconRegion&&!(_secondaryVisible&&inside)&&cachedActorHit>=1&&
           [self resolveWatchClothingScrubForZone:cachedActorHit clip:anim.current
               scrubClip:&_watchScrubClip finishClip:&_watchScrubFinishClip returnClip:&_watchScrubReturnClip
               invert:&_watchScrubInvert kind:&_watchScrubKind]) {
            _watchScrubState=1u;_watchScrubProgress=0.f;_watchScrubTremorPhase=0.f;
            _watchPose7IdleMs=0u;_actorPlaybackSpeed=1.0f;
            [self applyClothingVisibility];
            _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
            dc_model_scrub_clip(_actor.model,_watchScrubClip,0.f,0.f,&_actor.world);
            _motionState.clip=_watchScrubClip;
            ++_characterActionCount;
        } else if(_watchScrubState!=0u) {
            if(_watchScrubState==1u) {
                if((pcInput.mouse[1]&1)!=0) {
                    float step=(_watchScrubInvert?(float)pcInput.dy:-(float)pcInput.dy)*0.0065f;
                    _watchScrubProgress=fminf(1.0f,fmaxf(0.0f,_watchScrubProgress+step));
                    _watchScrubTremorPhase=fmodf(_watchScrubTremorPhase+(float)watchDelta*0.001f,1.0f);
                    float tremor=sinf(_watchScrubTremorPhase*6.2831853f)*0.3f;
                    dc_model_scrub_clip(_actor.model,_watchScrubClip,_watchScrubProgress,tremor,&_actor.world);
                    _motionState.clip=_watchScrubClip;
                } else {
                    _watchScrubState=(_watchScrubProgress>=0.5f)?2u:3u;
                }
            }
            if(_watchScrubState==2u) {
                _watchScrubProgress=fminf(1.0f,_watchScrubProgress+(float)MAX(16u,watchDelta)/220.f);
                if(_watchScrubProgress<1.0f) {
                    dc_model_scrub_clip(_actor.model,_watchScrubClip,_watchScrubProgress,0.f,&_actor.world);
                } else {
                    _watchScrubState=0u;
                    [self commitWatchScrubKind:_watchScrubKind];
                    dc_model_set_chain(_actor.model,_watchScrubFinishClip,(int32_t)_watchScrubReturnClip);
                    _motionState.clip=_watchScrubFinishClip;
                    dc_model_request(_actor.model,_watchScrubFinishClip,tick);
                    ++_characterAnimationStarts;
                    _pendingEffectSlot=2u;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:5 climax:NO];
                }
            } else if(_watchScrubState==3u) {
                _watchScrubProgress=fmaxf(0.0f,_watchScrubProgress-(float)MAX(16u,watchDelta)/220.f);
                if(_watchScrubProgress>0.0f) {
                    dc_model_scrub_clip(_actor.model,_watchScrubClip,_watchScrubProgress,0.f,&_actor.world);
                } else {
                    _watchScrubState=0u;
                    [self applyClothingVisibility];
                    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                    _motionState.clip=_watchScrubReturnClip;
                    dc_model_request(_actor.model,_watchScrubReturnClip,tick);
                }
            }
        } else if(pcInput.mouse[1]==3&&!pcInput.mouse[0]&&_watchPart>=0&&_watchPart<7&&!iconRegion&&!(_secondaryVisible&&inside)) {
            uint32_t retractClip=kWatchRetractClips[_watchPart];
            dc_model_set_chain(_actor.model,retractClip,(int32_t)kWatchState1IdleClips[_watchPart]);
            _motionState.clip=retractClip;_motionState.phase=1;
            _watchPart=-1;_watchDragging=NO;_watchUndressStep=0.f;_watchDragVelocity=0.f;
            _actorPlaybackSpeed=(_naturalGameplayRoute&&!touchExercise)?(_watchVibeSwitch?1.65f:((_watchNekoVibeVisible||_watchToriVibeVisible)?1.25f:1.0f)):1.0f;
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
            if(dc_model_request(_actor.model,retractClip,tick)!=DC_OK)return @"Original watch retract animation request failed";
            ++_characterAnimationStarts;++_characterActionCount;
            _pendingEffectSlot=2u;_hasPendingEffect=YES;
        } else if(pcInput.mouse[0]==3&&_pointerCameraOwner==0&&hit>=0&&hit<7&&(_watchPart<0||(!_watchDragging&&hit!=_watchPart))) {
            uint32_t idleCol=0u;
            if(_motionState.clip==15||_motionState.clip==61||_motionState.clip==67)idleCol=1u;
            else if(_motionState.clip==21||_motionState.clip==73)idleCol=2u;
            else if(_motionState.clip==27||_motionState.clip==79)idleCol=3u;
            else if(_motionState.clip==33)idleCol=4u;
            else if(_motionState.clip==39||_motionState.clip==85||_motionState.clip==91)idleCol=5u;
            uint32_t entryClip=(_motionState.clip==1||_motionState.clip>=230)?((uint32_t)hit+2u):kWatchEntryFromIdle[hit][idleCol];
            _watchPart=hit;_motionState.phase=2;_watchDragging=NO;_watchUndressStep=0.f;_watchDragVelocity=0.f;
            _watchSlideTheta=0.f;_watchSlidePhi=0.f;_watchPose7IdleMs=0u;
            _motionState.clip=entryClip;
            unsigned activeAux=(hit==1||hit==5)?0u:1u;
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model) {
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,auxiliary==activeAux?0:1);
                if(auxiliary==activeAux)dc_model_request(_watchAuxiliary[auxiliary].model,1,tick);
            }
            if(dc_model_request(_actor.model,entryClip,tick)!=DC_OK)return @"Original watch animation request failed";
            ++_characterAnimationStarts;++_characterActionCount;
            _pendingEffectSlot=3u;_hasPendingEffect=YES;
            [self queueCyclicReactionVoiceForScene:5 climax:NO];
        } else if(pcInput.mouse[0]==3&&_pointerCameraOwner==0&&!_watchDragging&&hit>=0&&hit==_watchPart) {
            /* Clicking again on the already-selected body part advances its
             * progressive clothing displacement stage (00493230 / 004a9880 / 004ae795). */
            BOOL advanced=[self advanceWatchClothingForPart:hit];
            if(advanced&&_lastUndressClip>0u) {
                dc_model_set_chain(_actor.model,_lastUndressClip,(int32_t)kWatchHoverClips[hit]);
                _motionState.clip=_lastUndressClip;
                dc_model_request(_actor.model,_lastUndressClip,tick);
                ++_characterAnimationStarts;
            }
            ++_characterActionCount;
            _pendingEffectSlot=advanced?2u:3u;_hasPendingEffect=YES;
            [self queueCyclicReactionVoiceForScene:5 climax:NO];
        } else {
            float rawDrag=(_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1]&&!iconRegion&&!(_secondaryVisible&&inside))?hypotf((float)pcInput.dx,(float)pcInput.dy):0.f;
            BOOL watchWheelStep=(_watchPart>=0&&_watchPart<7&&_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1]&&pcInput.wheel!=0);
            float wheelStep=(_secondaryLimits.wheel_step>0.f?_secondaryLimits.wheel_step:4.f)*0.05f;
            if(watchWheelStep) {
                if(!_watchDragging&&[self isOuterClothingUndisplacedForWatchPart:_watchPart]) {
                    if([self advanceWatchClothingForPart:_watchPart]&&_lastUndressClip>0u) {
                        dc_model_set_chain(_actor.model,_lastUndressClip,(int32_t)kWatchHoverClips[_watchPart]);
                        _motionState.clip=_lastUndressClip;
                        dc_model_request(_actor.model,_lastUndressClip,tick);
                        ++_characterAnimationStarts;
                        _pendingEffectSlot=2u;_hasPendingEffect=YES;
                    }
                } else {
                    _actorPlaybackSpeed=fminf(3.0f,fmaxf(0.5f,_actorPlaybackSpeed+(pcInput.wheel>0?wheelStep:-wheelStep)));
                    rawDrag=fmaxf(rawDrag,(_secondaryLimits.wheel_step>0.f?_secondaryLimits.wheel_step:4.f)*2.2f);
                }
            }
            BOOL watchCanDrag=_watchPart>=0&&_watchPart<7&&_pointerCameraOwner==0&&(((pcInput.mouse[0]&1)!=0)||watchWheelStep);
            if(watchCanDrag) {
                if(rawDrag>0.f) {
                    _watchDragVelocity=(_watchDragVelocity<=0.1f)?rawDrag:(_watchDragVelocity*0.65f+rawDrag*0.35f);
                } else {
                    float decay=expf(-(float)MAX(16u,MIN(100u,watchDelta))/220.f);
                    _watchDragVelocity*=decay;
                    if(_watchDragVelocity<0.35f)_watchDragVelocity=0.f;
                }
            } else {
                _watchDragVelocity=0.f;
            }
            float dragAmount=(rawDrag>0.f)?rawDrag:(_watchDragging?_watchDragVelocity*0.45f:0.f);
            if(watchCanDrag&&(rawDrag>0.f||(_watchDragging&&_watchDragVelocity>0.f))) {
                if(!_watchDragging&&[self isOuterClothingUndisplacedForWatchPart:_watchPart]) {
                    /* 00493230 / 004a9880 / 004ae795: starting a grope drag on a
                     * clothed body part immediately lifts/opens its outer layer. */
                    [self advanceWatchClothingForPart:_watchPart];
                    _watchUndressStep=0.f;
                }
                if(!watchWheelStep) {
                    _actorPlaybackSpeed=fminf(2.4f,0.85f+_watchDragVelocity*0.055f);
                    if((pcInput.mouse[0]&1)!=0) {
                        _watchSlideTheta=fmaxf(-0.35f,fminf(0.35f,_watchSlideTheta+(float)pcInput.dx*0.005f));
                        _watchSlidePhi=fmaxf(-0.35f,fminf(0.35f,_watchSlidePhi+(float)pcInput.dy*0.005f));
                    }
                }
                _watchTouchGauge=fminf(100.f,_watchTouchGauge+dragAmount*0.35f);
                _watchFeedbackStep+=dragAmount;
                _watchUndressStep+=dragAmount;
                if(_watchUndressStep>=85.f) {
                    _watchUndressStep=0.f;
                    if([self advanceWatchClothingForPart:_watchPart]) {
                        _pendingEffectSlot=2u;_hasPendingEffect=YES;
                    }
                }
                _motionState.metric=fminf(10000.f,_motionState.metric+dragAmount);
                _motionState.average_motion=.8f*_motionState.average_motion+.2f*dragAmount;
                if(_motionState.sample_count<UINT32_MAX)++_motionState.sample_count;
                BOOL vibeGrope=(_watchPart==3&&(_watchNekoVibeVisible||_watchToriVibeVisible));
                uint32_t entryClip=vibeGrope?148u:kWatchDragEntryClips[_watchPart];
                uint32_t slowLoopClip=vibeGrope?149u:kWatchDragLoopClips[_watchPart];
                uint32_t fastLoopClip=vibeGrope?150u:kWatchDragFastLoopClips[_watchPart];
                uint32_t activeLoopClip=(_watchTouchGauge>=55.f)?fastLoopClip:slowLoopClip;
                if(!_watchDragging||(_motionState.clip!=entryClip&&_motionState.clip!=slowLoopClip&&_motionState.clip!=fastLoopClip)) {
                    _watchDragging=((pcInput.mouse[0]&1)!=0);
                    dc_model_set_chain(_actor.model,entryClip,(int32_t)activeLoopClip);
                    _motionState.clip=entryClip;
                    if(dc_model_request(_actor.model,entryClip,tick)!=DC_OK)return @"Original watch drag animation request failed";
                    unsigned activeAux=(_watchPart==1||_watchPart==5)?0u:1u;
                    if(_watchAuxiliary[activeAux].model)
                        dc_model_request(_watchAuxiliary[activeAux].model,kWatchAuxDragClips[_watchPart],tick);
                    ++_characterAnimationStarts;
                } else if(_motionState.clip==slowLoopClip&&activeLoopClip==fastLoopClip) {
                    _motionState.clip=fastLoopClip;
                    dc_model_request(_actor.model,fastLoopClip,tick);
                }
                if(_watchFeedbackStep>=42.f) {
                    _watchFeedbackStep=0.f;
                    _pendingEffectSlot=4u+(_voiceSequenceIndex%3u);_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:5 climax:NO];
                }
                if(_watchTouchGauge>=100.f) {
                    if(_watchClimaxElapsedMs==0u||_watchElapsedMs<_watchClimaxElapsedMs)
                        _watchClimaxElapsedMs=MAX(1u,_watchElapsedMs);
                    int32_t climaxPart=_watchPart;
                    uint32_t climaxClip=kWatchClimaxClips[climaxPart];
                    uint32_t climaxEndClip=kWatchClimaxEndClips[climaxPart];
                    uint32_t postClip=((_stageProgress>=2||_editMode)&&climaxPart==3&&_watchSkirtStage>=1&&_watchPantyStage>=1)?243u:kWatchState1IdleClips[climaxPart];
                    dc_model_set_chain(_actor.model,climaxEndClip,(int32_t)postClip);
                    _watchDragging=NO;_watchUndressStep=0.f;_watchDragVelocity=0.f;_actorPlaybackSpeed=1.0f;
                    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                        dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
                    _watchTouchGauge=0.f;_watchPart=-1;_motionState.phase=1;_motionState.clip=climaxClip;
                    if(dc_model_request(_actor.model,climaxClip,tick)!=DC_OK)return @"Original watch climax animation request failed";
                    ++_characterAnimationStarts;
                    _pendingEffectSlot=15u;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:5 climax:YES];
                    ++_interactionCount;_interactionCompleted=YES;
                    _player.interaction_count=_interactionCount;_playerSaveDirty=YES;
                    if(!_stageProgress&&!_editMode)_watchPendingExitAfterClimax=YES;
                }
            } else if(_watchDragging&&!(pcInput.mouse[0]&1)) {
                _watchDragging=NO;_watchDragVelocity=0.f;_actorPlaybackSpeed=1.0f;
                if(_watchPart>=0&&_watchPart<7) {
                    BOOL vibeGrope=(_watchPart==3&&(_watchNekoVibeVisible||_watchToriVibeVisible));
                    uint32_t relClip=vibeGrope?151u:kWatchReleaseClips[_watchPart];
                    dc_model_set_chain(_actor.model,relClip,(int32_t)kWatchHoverClips[_watchPart]);
                    _motionState.clip=relClip;
                    dc_model_request(_actor.model,relClip,tick);
                    unsigned activeAux=(_watchPart==1||_watchPart==5)?0u:1u;
                    if(_watchAuxiliary[activeAux].model)
                        dc_model_request(_watchAuxiliary[activeAux].model,kWatchAuxReleaseClips[_watchPart],tick);
                }
            } else if(_watchDragging) {
                _actorPlaybackSpeed=0.75f;
            }
        }
    } else if(_sceneType==6&&_motionStateInitialized&&!_contextOpen&&
              !_characterAction.exit_pending&&!_characterAction.transition_pending) {
        uint32_t nightDelta=_tickInitialized?(tick-_lastTick):0u;
        dc_animation_state animation={0};
        if(dc_model_get_animation(_actor.model,&animation)==DC_OK&&animation.current<=0xffu)
            _motionState.clip=animation.current;
        uint32_t clip=_motionState.clip;
        int32_t hit=(_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1])?cachedActorHit:-1;
        float wheelStep=(_secondaryLimits.wheel_step>0.f?_secondaryLimits.wheel_step:4.f)*0.05f;
        if(clip==26&&_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1]&&pcInput.wheel!=0) {
            /* 00486a0c -> 004c9320: wheel steps post-climax breathing speed by wheel_step * 0.05. */
            _actorPlaybackSpeed=fminf(3.0f,fmaxf(0.5f,_actorPlaybackSpeed+(pcInput.wheel>0?wheelStep:-wheelStep)));
        }
        if((!_naturalGameplayRoute||touchExercise)&&clip==1&&pcInput.mouse[0]==3&&_pointerCameraOwner==0&&hit>=0) {
            dc_scene_motion_event motionEvent;
            if(dc_scene_motion_context(&_motionState,0,&motionEvent)==DC_OK) {
                ++_characterActionCount;
                _stageOutcomeA=_motionState.outcome_a;_stageOutcomeB=_motionState.outcome_b;
                _pendingEffectSlot=2u;_hasPendingEffect=YES;
                [self queueCyclicReactionVoiceForScene:6 climax:NO];
                NSString *motionFailure=[self applyMotionEvent:motionEvent tick:tick];if(motionFailure)return motionFailure;
                clip=_motionState.clip;
            }
        } else if((!_naturalGameplayRoute||touchExercise)&&clip==26&&pcInput.mouse[0]==3&&_pointerCameraOwner==0&&hit>=0) {
            ++_characterActionCount;
            _motionState.clip=27u;_motionState.phase=2;_motionState.pointer_mode=0;
            _nightExcitement=0.f;_nightDragging=NO;_nightDragVelocity=0.f;_actorPlaybackSpeed=1.0f;
            _nightHadInternalClimax=YES;
            if(_nightPosMode==0u){if(_nightInternalVagCount<10000u)++_nightInternalVagCount;}
            else {if(_nightInternalAnalCount<10000u)++_nightInternalAnalCount;}
            _pendingEffectSlot=15u;_hasPendingEffect=YES;
            [self queueCyclicReactionVoiceForScene:6 climax:YES];
            ++_interactionCount;_interactionCompleted=YES;
            _player.interaction_count=_interactionCount;_playerSaveDirty=YES;
            dc_scene_motion_event ev={.request_clip=27u,.request_chain_from=DC_SCENE_MOTION_NO_REQUEST,.request_chain_to=DC_SCENE_MOTION_NO_REQUEST};
            NSString *motionFailure=[self applyMotionEvent:ev tick:tick];if(motionFailure)return motionFailure;
            clip=_motionState.clip;
        }
        BOOL inPos1=(clip>=10&&clip<=23);
        BOOL inPos2=(clip>=39&&clip<=53);
        if((inPos1||inPos2)&&_pointerCameraOwner==0) {
            float rawDrag=(!pcCtrl&&!pcInput.mouse[1]&&((pcInput.mouse[0]&1)!=0))?hypotf((float)pcInput.dx,(float)pcInput.dy):0.f;
            BOOL wheelStepActive=(!pcCtrl&&!pcInput.mouse[1]&&pcInput.wheel!=0);
            float wheelImpulse=wheelStepActive?((_secondaryLimits.wheel_step>0.f?_secondaryLimits.wheel_step:4.f)*1.8f):0.f;
            if((pcInput.mouse[0]&1)!=0) {
                if(rawDrag>0.f) {
                    _nightDragVelocity=(_nightDragVelocity<=0.1f)?rawDrag:(_nightDragVelocity*0.65f+rawDrag*0.35f);
                } else {
                    float decay=expf(-(float)MAX(16u,MIN(100u,nightDelta))/220.f);
                    _nightDragVelocity*=decay;
                    if(_nightDragVelocity<0.35f)_nightDragVelocity=0.f;
                }
            } else {
                _nightDragVelocity=0.f;
            }
            float effectiveDrag=(rawDrag>0.f)?rawDrag:(_nightDragging?_nightDragVelocity*0.45f:0.f);
            float thrustAmount=effectiveDrag+wheelImpulse;
            if(thrustAmount>0.f) {
                if((pcInput.mouse[0]&1)!=0) {
                    _nightDragging=YES;
                    _actorPlaybackSpeed=fminf(2.4f,0.85f+_nightDragVelocity*0.055f);
                } else if(wheelStepActive) {
                    /* 0048691f..00486a00 & 004c9320: wheel steps thrust speed slightly once per click. */
                    _actorPlaybackSpeed=fminf(3.0f,fmaxf(0.5f,_actorPlaybackSpeed+(pcInput.wheel>0?wheelStep:-wheelStep)));
                }
                _nightExcitement=fminf(100.f,_nightExcitement+fminf(thrustAmount,10.f)*0.45f);
                _nightFeedbackStep+=thrustAmount;
                _motionState.metric=fminf(10000.f,_motionState.metric+fminf(thrustAmount,4.f));
                _motionState.average_motion=.8f*_motionState.average_motion+.2f*thrustAmount;
                if(_motionState.sample_count<UINT32_MAX)++_motionState.sample_count;
                uint32_t targetLoop=inPos2?(_nightExcitement>=45.f?49u:42u):(_nightExcitement>=45.f?20u:13u);
                if(clip!=targetLoop&&clip!=targetLoop+1u) {
                    _motionState.clip=targetLoop;
                    if(dc_model_request(_actor.model,targetLoop,tick)!=DC_OK)return @"Original night thrusting animation request failed";
                    ++_characterAnimationStarts;
                }
                if(_nightFeedbackStep>=42.f) {
                    _nightFeedbackStep=0.f;
                    _pendingEffectSlot=7u+(_voiceSequenceIndex%3u);_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:NO];
                }
                if(_nightExcitement>=100.f) {
                    _nightExcitement=0.f;_nightDragging=NO;_nightDragVelocity=0.f;_actorPlaybackSpeed=1.0f;
                    _nightHadInternalClimax=YES;
                    if(_nightPosMode==0u) {
                        if(_nightInternalVagCount<10000u)++_nightInternalVagCount;
                        if((_stageOutcomeA==0u||inPos2)&&_stageOutcomeA<10000u)++_stageOutcomeA;
                        _motionState.outcome_a=_stageOutcomeA;
                    } else {
                        if(_nightInternalAnalCount<10000u)++_nightInternalAnalCount;
                        if((_stageOutcomeB==0u||inPos2)&&_stageOutcomeB<10000u)++_stageOutcomeB;
                        _motionState.outcome_b=_stageOutcomeB;
                    }
                    uint32_t climaxClip=inPos2?56u:24u;
                    _motionState.clip=climaxClip;_motionState.phase=3;
                    if(dc_model_request(_actor.model,climaxClip,tick)!=DC_OK)return @"Original night climax animation request failed";
                    ++_characterAnimationStarts;
                    _pendingEffectSlot=15u;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:YES];
                    if(inPos2||(_naturalGameplayRoute&&!touchExercise)) {
                        ++_interactionCount;_interactionCompleted=YES;
                        _player.interaction_count=_interactionCount;_playerSaveDirty=YES;
                    }
                }
            } else if(_nightDragging&&!(pcInput.mouse[0]&1)) {
                _nightDragging=NO;_nightDragVelocity=0.f;_actorPlaybackSpeed=1.0f;
                uint32_t stopClip=inPos2?((_naturalGameplayRoute&&clip>=48u)?51u:44u):((_naturalGameplayRoute&&clip>=19u)?22u:15u);
                _motionState.clip=stopClip;
                dc_model_request(_actor.model,stopClip,tick);
            } else if(_nightDragging) {
                _actorPlaybackSpeed=0.75f;
            }
        }
    }
    if(cameraScene) {
        BOOL held=(pcInput.mouse[0]&1)||(pcInput.mouse[1]&1)||(pcInput.mouse[2]&1);
        if(!_contextOpen&&((_sceneType==5&&_watchPart>=0&&_watchDragging&&(pcInput.mouse[0]&1))||
                           (_sceneType==6&&_nightDragging&&(pcInput.mouse[0]&1)))) {
            _cursorIndex=-1;
        } else if(!_contextOpen&&(_pointerCameraOwner==2||_pointerCameraOwner==3)&&held) {
            if(((pcInput.mouse[0]&1)&&(pcInput.mouse[1]&1))||(pcInput.mouse[2]&1))
                _cursorIndex=3;
            else if(pcInput.mouse[1]&1)
                _cursorIndex=2;
            else
                _cursorIndex=1;
        } else {
            _cursorIndex=0;
        }
    }
    if(cameraScene&&!secondaryOwnsPointer&&!primaryOwnsPointer&&!_characterAction.exit_pending&&!_characterAction.transition_pending) {
        float scale=fminf((float)width/1024.f,(float)height/768.f);
        float px=((x+1)*.5f*width-(width-1024*scale)*.5f)/scale;
        float py=((1-y)*.5f*height-(height-768*scale)*.5f)/scale;
        uint32_t left=pcInput.pointer_active||pcInput.mouse[0]?pcInput.mouse[0]:(touching?(_previousGameMenuTouch?1:3):(_previousGameMenuTouch?2:0));
        if(_contextOpen) {
            NSString *error=[self stepContextAtX:px y:py left:left right:pcInput.mouse[1]];if(error)return error;
        } else {
            dc_animation_state curMenuAnim={0};
            if(_actor.model)dc_model_get_animation(_actor.model,&curMenuAnim);
            dc_menu_button buttons[DC_GAME_MENU_COUNT];dc_game_menu_profile(buttons,DC_GAME_MENU_COUNT);
            BOOL charaDisabled=NO;
            if(_sceneType==4&&!touchExercise&&(_characterAction.delay_pending||(curMenuAnim.current!=1&&curMenuAnim.current!=11&&curMenuAnim.current!=13)))
                charaDisabled=YES;
            else if(_sceneType==5&&!_stageProgress&&!_editMode&&_naturalGameplayRoute)
                charaDisabled=YES;
            else if(_sceneType==5&&!touchExercise&&_naturalGameplayRoute&&
                    (_watchPart>=0||_watchDragging||_watchScrubState!=0u||
                     (curMenuAnim.current!=1&&curMenuAnim.current!=9&&curMenuAnim.current!=15&&
                      curMenuAnim.current!=21&&curMenuAnim.current!=27&&curMenuAnim.current!=33&&
                      curMenuAnim.current!=245)))
                charaDisabled=YES;
            else if(_sceneType==6&&!touchExercise&&_naturalGameplayRoute&&
                    (_nightDragging||
                     (curMenuAnim.current!=1&&
                      curMenuAnim.current!=26&&
                      curMenuAnim.current!=39&&
                      curMenuAnim.current!=55)))
                charaDisabled=YES;
            else if(_sceneType==7&&_type7SwapPending)
                charaDisabled=YES;
            else if(_sceneType==12)
                charaDisabled=YES;
            buttons[1].disabled=charaDisabled?1:0;
            BOOL clothDisabled=!(_stageProgress||_editMode||_sceneType==7);
            if((_sceneType==7&&_type7SwapPending)||_sceneType==12)clothDisabled=YES;
            if(_sceneType==12&&_editExitFadeStarted){buttons[3].disabled=1;buttons[4].disabled=1;}
            if(!clothDisabled&&!touchExercise) {
                if(_sceneType==6&&curMenuAnim.current==31)
                    clothDisabled=YES;
                else if(_naturalGameplayRoute) {
                    if(_sceneType==4&&(_characterAction.delay_pending||(curMenuAnim.current!=1&&curMenuAnim.current!=11&&curMenuAnim.current!=13)))
                        clothDisabled=YES;
                    else if(_sceneType==5&&(_watchPart>=0||_watchDragging||_watchScrubState!=0u||
                            (curMenuAnim.current!=1&&curMenuAnim.current!=9&&curMenuAnim.current!=15&&
                             curMenuAnim.current!=21&&curMenuAnim.current!=27&&curMenuAnim.current!=33&&
                             curMenuAnim.current!=39)))
                        clothDisabled=YES;
                    else if(_sceneType==6&&(_nightDragging||
                            (curMenuAnim.current!=1&&curMenuAnim.current!=10&&curMenuAnim.current!=18&&
                             curMenuAnim.current!=26&&curMenuAnim.current!=39&&curMenuAnim.current!=47&&
                             curMenuAnim.current!=55)))
                        clothDisabled=YES;
                }
            }
            buttons[2].disabled=clothDisabled?1:0;
            int32_t result=-1;
            if(dc_menu_step(&_gameMenu,buttons,DC_GAME_MENU_COUNT,(int32_t)lrintf(px),(int32_t)lrintf(py),1,0,&result)!=DC_OK)return @"Scene icon hover failed";
            if(left!=0&&dc_menu_step(&_gameMenu,buttons,DC_GAME_MENU_COUNT,(int32_t)lrintf(px),(int32_t)lrintf(py),1,left,&result)!=DC_OK)
                return @"Scene icon input failed";
            _mainIconHover=result==-1?-1:_gameMenu.hover;
            if(result==1&&_mainIconHover>=1&&_mainIconHover<=4){
                ++_acceptedMenuEvents;_lastAcceptedMenuRow=(uint32_t)_mainIconHover;
                if(_sceneType==4&&_mapSelector==0&&_mainIconHover==1&&!_pendingVoiceName)
                    [self queueCharacterVoice:@"st001_01.wav"];
                if(_mainIconHover==2&&!clothDisabled&&(touchExercise||!pcInput.active)){
                    _outfitVariant=(_outfitVariant+1)&3u;
                    [self applyOutfitVariant:_outfitVariant];
                    _pendingEffectSlot=2u;_hasPendingEffect=YES;
                }
            }
            BOOL openContext=(pcInput.mouse[1]==3)||(result==1&&pcInput.active&&!touchExercise);
            if(openContext&&_mainIconHover>=1&&_mainIconHover<=4) {
                if(pcInput.mouse[1]==3&&_mainIconHover==2&&(_stageProgress||_editMode)&&touchExercise){
                    _outfitVariant=(_outfitVariant+1)&3u;
                    [self applyOutfitVariant:_outfitVariant];
                }
                dc_animation_state animation={0};dc_model_get_animation(_actor.model,&animation);
                uint32_t contextSceneType=(_mainIconHover>=3&&((_sceneType>=4&&_sceneType<=6)||_sceneType==12))?4:_sceneType;
                dc_scene_context_input input={.scene_type=contextSceneType,.icon=(uint32_t)_mainIconHover,.stage_progress=_mainIconHover==1?0:(_editMode?2u:MIN(_stageProgress,2u)),
                    .animation=animation.current,.camera_mode=_primaryCameraMode,.secondary_camera_mode=_secondaryCameraMode,.x=px,.y=py};
                dc_status status=dc_scene_context_build(&input,&_contextMenu);
                if(status!=DC_OK&&status!=DC_NOT_FOUND)return @"Scene context profile failed";
                float unit=105.f*.3333333432674408f;
                const float dx[7]={0,unit,unit+unit,105,unit+unit,unit,0};
                const float dy[7]={-105,-(unit+unit),-unit,0,unit,unit+unit,105};
                if(_sceneType==7) {
                    [self rebuildType7ContextMenuForHub:(uint8_t)_mainIconHover atX:px y:py right:(pcInput.mouse[1]==3)];
                    status=DC_OK;
                } else if(_mainIconHover==1&&_sceneType==4&&!touchExercise&&
                   ((_stageProgress>0||_editMode)||(status==DC_OK&&_contextMenu.count==0))) {
                    BOOL freeMode=(_stageProgress>0||_editMode);
                    _contextMenu=(dc_scene_context){.icon=1,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1,.count=freeMode?6u:2u};
                    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                    if(freeMode) {
                        BOOL bottomExposed=(_outfitVariant>=2)||((_storyStage==2)?(_clothingTopState>=6u):(_clothingSkirtState>=3u));
                        BOOL vibeActive=(animation.current==11||animation.current==13);
                        BOOL anyVibe=(!_naturalGameplayRoute)?vibeActive:(vibeActive||_watchNekoVibeVisible||_watchToriVibeVisible);
                        const int32_t ids[6]={
                            1,
                            3,
                            (bottomExposed&&(!_naturalGameplayRoute?!vibeActive:!_watchNekoVibeVisible))?4:-1,
                            (bottomExposed&&(!_naturalGameplayRoute?!vibeActive:!_watchToriVibeVisible))?5:-1,
                            (bottomExposed&&anyVibe)?6:-1,
                            (bottomExposed&&anyVibe)?((animation.current==13)?8:7):-1
                        };
                        const uint32_t arr[6]={6,0,2,3,5,4};
                        for(unsigned i=0;i<6;++i)_contextMenu.items[i]=(dc_scene_context_item){ids[i],arr[i],0,0};
                    } else {
                        _contextMenu.items[0]=(dc_scene_context_item){1,6,0,0};
                        _contextMenu.items[1]=(dc_scene_context_item){2,0,0,0};
                    }
                    for(unsigned i=0;i<_contextMenu.count;++i) {
                        uint32_t a=_contextMenu.items[i].arrangement;
                        _contextMenu.items[i].x=px-dx[a];_contextMenu.items[i].y=py+dy[a];
                    }
                    status=DC_OK;
                } else if(_mainIconHover==1&&_sceneType==5&&!touchExercise&&(animation.current==245||_stageProgress>0||_editMode)) {
                    _contextMenu=(dc_scene_context){.icon=1,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1};
                    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                    if(animation.current==245) {
                        _contextMenu.count=2u;
                        _contextMenu.items[0]=(dc_scene_context_item){7,0,0,0};
                        _contextMenu.items[1]=(dc_scene_context_item){6,6,0,0};
                    } else {
                        BOOL frontExposed=(!_naturalGameplayRoute||_outfitVariant>=2||
                            ((_storyStage==2)?(_clothingTopState==2u||_clothingTopState==3u||_clothingTopState>=6u):
                             (_clothingSkirtState==1u||_clothingSkirtState>=3u)));
                        BOOL backExposed=(!_naturalGameplayRoute||_outfitVariant>=2||
                            ((_storyStage==2)?(_clothingTopState>=4u):(_clothingSkirtState>=2u)));
                        BOOL nekoAllowed=frontExposed&&(!_naturalGameplayRoute||(animation.current==21u&&!_watchNekoVibeVisible));
                        BOOL toriAllowed=backExposed&&(!_naturalGameplayRoute||(animation.current==27u&&!_watchToriVibeVisible));
                        BOOL vibeAllowed=(frontExposed||backExposed||_watchNekoVibeVisible||_watchToriVibeVisible);
                        BOOL anyVibe=(_watchNekoVibeVisible||_watchToriVibeVisible);
                        _contextMenu.count=5u;
                        const int32_t ids[5]={
                            nekoAllowed?1:-1,
                            toriAllowed?2:-1,
                            (vibeAllowed&&(!_naturalGameplayRoute||anyVibe))?3:-1,
                            (!_naturalGameplayRoute)?(vibeAllowed?4:-1):(anyVibe?(_watchVibeSwitch?5:4):-1),
                            7
                        };
                        const uint32_t arr[5]={1,2,4,3,0};
                        for(unsigned i=0;i<5;++i)_contextMenu.items[i]=(dc_scene_context_item){ids[i],arr[i],0,0};
                    }
                    for(unsigned i=0;i<_contextMenu.count;++i) {
                        uint32_t a=_contextMenu.items[i].arrangement;
                        _contextMenu.items[i].x=px-dx[a];_contextMenu.items[i].y=py+dy[a];
                    }
                    status=DC_OK;
                } else if(_mainIconHover==1&&_sceneType==6&&!touchExercise) {
                    _contextMenu=(dc_scene_context){.icon=1,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1};
                    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                    if(animation.current==26||(!_naturalGameplayRoute&&animation.current>=10&&animation.current<=26)) {
                        _contextMenu.count=2u;
                        _contextMenu.items[0]=(dc_scene_context_item){9,0,0,0};
                        _contextMenu.items[1]=(dc_scene_context_item){10,6,0,0};
                        if(animation.current==26&&_naturalGameplayRoute&&!_nightQuestionAsked) {
                            _contextMenu.count=6u;
                            for(unsigned q=0;q<4;++q)
                                _contextMenu.items[2+q]=(dc_scene_context_item){19+(int32_t)q,1+q,0,0};
                        }
                    } else if(animation.current==39||(!_naturalGameplayRoute&&animation.current>=27&&animation.current<=54)) {
                        _contextMenu.count=2u;
                        _contextMenu.items[0]=(dc_scene_context_item){11,0,0,0};
                        _contextMenu.items[1]=(dc_scene_context_item){12,6,0,0};
                    } else if(animation.current>=55||!_naturalGameplayRoute||_stageProgress>0||_editMode) {
                        _contextMenu.count=3u;
                        _contextMenu.items[0]=(dc_scene_context_item){1,0,0,0};
                        _contextMenu.items[1]=(dc_scene_context_item){2,1,0,0};
                        _contextMenu.items[2]=(dc_scene_context_item){13,6,0,0};
                    } else {
                        _contextMenu.count=2u;
                        _contextMenu.items[0]=(dc_scene_context_item){1,0,0,0};
                        _contextMenu.items[1]=(dc_scene_context_item){2,1,0,0};
                    }
                    for(unsigned i=0;i<_contextMenu.count;++i) {
                        uint32_t a=_contextMenu.items[i].arrangement;
                        _contextMenu.items[i].x=px-dx[a];_contextMenu.items[i].y=py+dy[a];
                    }
                    status=DC_OK;
                } else if(_mainIconHover==2&&(_stageProgress||_editMode)&&!touchExercise) {
                    [self buildClothingContextMenuAtX:px y:py right:(pcInput.mouse[1]==3) animation:animation.current];
                    status=DC_OK;
                } else if(_mainIconHover==4&&_editMode&&!touchExercise) {
                    static const int32_t kEditSpeedResourceIds[4]={2,4,8,2};
                    _contextMenu=(dc_scene_context){.icon=4,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1,.count=4u};
                    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                    _contextMenu.items[0]=(dc_scene_context_item){2,0,px-dx[0],py+dy[0]};
                    _contextMenu.items[1]=(dc_scene_context_item){(_editPaused||_editSpeedMode!=0)?9:10,2,px-dx[2],py+dy[2]};
                    _contextMenu.items[2]=(dc_scene_context_item){kEditSpeedResourceIds[_editSpeedMode&3u],1,px-dx[1],py+dy[1]};
                    _contextMenu.items[3]=(dc_scene_context_item){1,3,px-dx[3],py+dy[3]};
                    status=DC_OK;
                }
                if(status==DC_OK&&_contextMenu.count){
                    _contextMenu.opening_right=(pcInput.mouse[1]==3)?1u:0u;
                    _contextOpen=YES;++_contextOpens;
                    /* Original update dispatches the newly opened menu in
                     * the same frame, including simultaneous mouse buttons. */
                    uint32_t openLeft=(pcInput.mouse[1]==3)?left:0u;
                    NSString *error=[self stepContextAtX:px y:py left:openLeft right:pcInput.mouse[1]];if(error)return error;
                    if(_contextOpen&&!_hasPendingEffect){_pendingEffectSlot=24u;_hasPendingEffect=YES;}
#if DEBUG
                    if(_contextOpen&&_contextOpens==1&&[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
                        [self requestRenderCapture:@"gameplay-context-native.png"];
#endif
                }
            }
        }
    }
    _previousGameMenuTouch=touching;
    float nearOriginX=_actorOriginX-_actor.world.values[12],nearOriginZ=_actorOriginZ-_actor.world.values[14];
    BOOL nearInteraction=fabsf(nearOriginX)<12.0f&&fabsf(nearOriginZ)<12.0f;
    BOOL renderCheckpoint=NO;
#if DEBUG
    renderCheckpoint=[NSProcessInfo.processInfo.environment[@"PORTLAB_RENDER_PROBE"] isEqualToString:@"1"];
#endif
    /* The old 800ms completion was a test harness, not a recovered gameplay
     * state machine. Keep it confined to independent DEBUG GPU checkpoints. */
    if(renderCheckpoint) {
        dc_game_interaction_input interactionInput={.tick=tick,.new_touch=(controller.pressed&DC_PAD_A)!=0,.near_target=nearInteraction};
        dc_game_interaction_state interactionNext;dc_game_interaction_result interactionResult;
        if(dc_game_interaction_step(&_interactionState,&interactionInput,&interactionNext,&interactionResult)!=DC_OK)return @"Game interaction state update failed";
        if(interactionResult.begin) {
            if(dc_model_request(_actor.model,2,tick)!=DC_OK)return @"Game interaction animation request failed";
        } else if(interactionResult.restore) {
            if(dc_model_request(_actor.model,1,tick)!=DC_OK)return @"Game interaction animation restore failed";
        }
        _interactionState=interactionNext;_interactionActive=_interactionState.active;_interactionStartTick=_interactionState.start_tick;_interactionCount=_interactionState.interaction_count;
        if(interactionResult.completed){_interactionCompleted=YES;_storyPhase=1;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
    }
    if(gameplayScene && _storyChapter==24 && _interactionCompleted)_gameFinished=YES;
    if(touching) {
        // A game tap selects/interacts. Dragging that tap must not secretly
        // translate the player; explicit position adjustment uses its pad.
        _lastInputX=x;_lastInputY=y;_inputInitialized=YES;
    } else { _inputInitialized=NO; }
    // Controller movement goes directly to the player; it is never a fake drag.
    float moveX=controller.lx/32767.f,moveZ=-controller.ly/32767.f;
    if(controller.buttons&DC_PAD_LEFT)moveX-=1;
    if(controller.buttons&DC_PAD_RIGHT)moveX+=1;
    if(controller.buttons&DC_PAD_UP)moveZ-=1;
    if(controller.buttons&DC_PAD_DOWN)moveZ+=1;
    float moveLength=hypotf(moveX,moveZ);
    if(moveLength>1){moveX/=moveLength;moveZ/=moveLength;}
    if(gameplayScene && moveLength>0.01f && !_interactionActive && !_gameFinished) {
        dc_game_player next;
        dc_game_input movement={.axis_x=moveX,.axis_z=moveZ,.touching=1};
        float speed=(controller.buttons&DC_PAD_L3)?2.f:1.f;
        if(dc_game_player_step(&_player,&movement,padDelta*speed,&next)==DC_OK) {
            BOOL changed=next.x!=_player.x || next.z!=_player.z;
            if([self movePlayerTo:&next] && changed)_controllerMovementAdvanced=YES;
        }
    } else if(!touching) { [self savePlayerState]; }
    uint32_t delta=_tickInitialized ? tick-_lastTick : 0;_tickInitialized=YES;_lastTick=tick;
    NSString *cameraSelectionError=[self autoSelectCameraAtTick:tick];if(cameraSelectionError)return cameraSelectionError;
    _primaryCameraTargetActive=primaryOwnsPointer;
    _secondaryCameraTargetActive=secondaryOwnsPointer;
    if(_primaryCameraMode!=2) {
    if(controller.pressed&DC_PAD_R3){_padCameraYaw=0;_padCameraPitch=0;_padCameraZoom=0;_padCameraHeight=0;}
    float kbFast=(pcInput.keys[0x3b]&1)?2.f:1.f;
    float effPadDelta=padDelta*kbFast;
    float cameraX=controller.rx/32767.f,cameraY=controller.ry/32767.f;
    if(pcNum4)cameraX-=1.f;if(pcNum6)cameraX+=1.f;
    if(pcNum8)cameraY-=1.f;if(pcNum2)cameraY+=1.f;
    float heightDelta=(pcPageUp?1.f:0.f)-(pcPageDown?1.f:0.f);
    if(padDelta>0 && (cameraX!=0 || cameraY!=0 || heightDelta!=0))_controllerCameraAdvanced=YES;
    if(controller.buttons&DC_PAD_L)cameraX-=1;
    if(controller.buttons&DC_PAD_R)cameraX+=1;
    _padCameraYaw=remainderf(_padCameraYaw+cameraX*effPadDelta*1.5f,6.2831853f);
    _padCameraPitch=fmaxf(-.7f,fminf(.7f,_padCameraPitch+cameraY*effPadDelta));
    _padCameraHeight=fmaxf(_secondaryLimits.low-_cameraHeight,fminf(_secondaryLimits.high-_cameraHeight,_padCameraHeight+heightDelta*effPadDelta*5.0f));
    float zoom=((controller.buttons&DC_PAD_ZR)?1.f:0.f)-((controller.buttons&DC_PAD_ZL)?1.f:0.f);
    if(pcHome)zoom+=1.f;if(pcEnd)zoom-=1.f;
    _padCameraZoom=fmaxf(-.7f,fminf(1.f,_padCameraZoom+zoom*effPadDelta));
    float panX=(pcArrowRight?1.f:0.f)-(pcArrowLeft?1.f:0.f);
    float panZ=(pcArrowDown?1.f:0.f)-(pcArrowUp?1.f:0.f);
    float yaw=_cameraYaw+_padCameraYaw,cy=cosf(yaw),sy=sinf(yaw);
    _padCameraPanX=fmaxf(-50.f,fminf(50.f,_padCameraPanX+(panX*cy+panZ*sy)*effPadDelta*2.0f));
    _padCameraPanZ=fmaxf(-50.f,fminf(50.f,_padCameraPanZ+(-panX*sy+panZ*cy)*effPadDelta*2.0f));
    if(cameraX!=0.f||cameraY!=0.f||heightDelta!=0.f||zoom!=0.f||panX!=0.f||panZ!=0.f)_primaryCameraTargetActive=YES;
    }
    /* Advance each model exactly once before selecting the rendered camera.
     * The original automatic view uses this frame's animated nodes. */
    dc_animation_state curAnim={0};
    if(_actor.model)dc_model_get_animation(_actor.model,&curAnim);
    if(_sceneType==6) {
        if(curAnim.current==31u||curAnim.current==57u) {
            if(!_inExternalClimax) {
                _inExternalClimax=YES;
                if(_externalClimaxLevel<2u)++_externalClimaxLevel;
                _lastClothingClip=UINT32_MAX;
            }
        } else {
            _inExternalClimax=NO;
        }
    }
    if(cameraScene&&_sceneType!=7&&_sceneType!=12) {
        [self syncDynamicClothingForPart:_watchPart clip:curAnim.current];
        if(_sceneType==5||_sceneType==6) {
            float gauge=(_sceneType==5)?_watchTouchGauge:_nightExcitement;
            if(gauge>0.f&&_actor.model) {
                uint32_t mataNode=[self findNode:&_actor name:[self characterNode:@"a_On_mata_siru"]];
                if(mataNode!=UINT32_MAX)dc_model_hide_node(_actor.model,mataNode,0);
            }
        }
    }
    BOOL captureActive=(_captureGameplayFrame&&!_capturedGameplayFrame)||_requestedRenderCapture!=nil;
    BOOL bypassDynamicTex=captureActive||!_naturalGameplayRoute||touchExercise;
    [self syncDynamicActorTexturesForClip:curAnim.current bypass:bypassDynamicTex];
    if(bypassDynamicTex) {
        _materialCycleSlot=0;_faceBlushActive=NO;
    } else {
        int32_t editMid=(_sceneType==12&&_editPlayer.cur_step>=0&&_editPlayer.cur_step<_editStateCopy.step_count)?_editStateCopy.steps[_editPlayer.cur_step].motion_id:6;
        BOOL shouldCycle=NO;
        if(_sceneType==4)shouldCycle=_watchVibeSwitch;
        else if(_sceneType==5)shouldCycle=YES;
        else if(_sceneType==6)shouldCycle=(curAnim.current!=1u&&curAnim.current!=2u);
        else if(_sceneType==7)shouldCycle=(_type7State.phase!=DC_TYPE7_PHASE_IDLE||_type7State.vibe_mask!=0u);
        else if(_sceneType==12)shouldCycle=(editMid>=10||_editPlayer.vibe_mask!=0u);
        if(!shouldCycle) {
            _materialCycleSlot=0;_lastMaterialCycleTick=tick;
        } else if(!(_editMode&&_editPaused)) {
            if(!_lastMaterialCycleTick)_lastMaterialCycleTick=tick;
            else if(tick>=_lastMaterialCycleTick&&tick-_lastMaterialCycleTick>=100u) {
                uint32_t steps=(tick-_lastMaterialCycleTick)/100u;
                _materialCycleSlot=(_materialCycleSlot+steps)&3u;
                _lastMaterialCycleTick+=steps*100u;
            }
        }
        if(_sceneType==4||_sceneType==5) {
            uint8_t effectiveTop=MAX(_watchTopStage,(_outfitVariant==1u)?1u:((_outfitVariant>=2u)?2u:0u));
            _faceBlushActive=(effectiveTop>=1u)||(_stageOutcomeA>=1u)||(_watchClimaxElapsedMs>0u)||_voiceBlushActive;
        } else if(_sceneType==6) {
            _faceBlushActive=(curAnim.current==57u&&(_stageOutcomeA!=0u||_stageOutcomeB!=0u))||
                             (curAnim.current>=24u&&curAnim.current<=32u)||
                             (curAnim.current>=56u&&curAnim.current<=58u)||
                             _voiceBlushActive;
        } else if(_sceneType==7) {
            _faceBlushActive=(_type7State.phase!=DC_TYPE7_PHASE_IDLE)||_voiceBlushActive;
        } else if(_sceneType==12) {
            _faceBlushActive=(editMid>=10||_editPlayer.vibe_mask!=0u||_editClimaxCount>0u)||_voiceBlushActive;
        } else {
            _faceBlushActive=NO;
        }
    }
    if(_sceneType==4&&_naturalGameplayRoute&&!touchExercise&&!(_editMode&&_editPaused)) {
        if(!_characterAction.delay_pending&&(curAnim.current==1u||curAnim.current==11u||curAnim.current==13u)) {
            _scene4IdleMs+=delta;
            _scene4StageDecayMs+=delta;
            while(_scene4IdleMs>=4000u) {
                _scene4IdleMs-=4000u;
                if(!_watchVibeSwitch&&_actorPlaybackSpeed>1.0f)
                    _actorPlaybackSpeed=fmaxf(1.0f,_actorPlaybackSpeed-0.125f);
            }
            while(_scene4StageDecayMs>=30000u) {
                _scene4StageDecayMs-=30000u;
                if(_characterAction.activation_count>0u)--_characterAction.activation_count;
            }
        } else {
            _scene4IdleMs=0u;_scene4StageDecayMs=0u;
        }
    }
    static const float kEditSpeedScales[4]={1.f,2.f,4.f,8.f};
    float editScale=_editMode?(_editPaused?0.f:kEditSpeedScales[_editSpeedMode&3u]):1.f;
    uint32_t mapDelta=(uint32_t)lrintf((float)delta*editScale);
    float effActorSpeed=(_actorPlaybackSpeed>0.f?_actorPlaybackSpeed:1.0f);
    float maxActorSpeed=2.5f;
    if(_sceneType==7) {
        maxActorSpeed=5.0f;
        if(_type7State.phase==DC_TYPE7_PHASE_IDLE||_type7State.phase==DC_TYPE7_PHASE_AFTERGLOW||
           _type7State.phase==DC_TYPE7_PHASE_PAUSE_HOLD||_type7State.phase==DC_TYPE7_PHASE_SECOND_HOLD) {
            effActorSpeed=(_type7State.idle_anim_speed>0.f)?_type7State.idle_anim_speed:1.0f;
        }
    }
    uint32_t actorDelta=(_sceneType==5&&_watchScrubState!=0u)?0u:
        (uint32_t)lrintf((float)delta*editScale*fmaxf(0.25f,fminf(maxActorSpeed,effActorSpeed)));
    [self clearProceduralActorExtras];
    dc_animation_state editBefore={0};
    if(_sceneType==12&&_actor.model)dc_model_get_animation(_actor.model,&editBefore);
    if(dc_model_tick(_map.model,mapDelta,tick,&_map.world)!=DC_OK||
       dc_model_tick(_actor.model,actorDelta,tick,&_actor.world)!=DC_OK)return @"Game model tick failed";
    for(uint32_t eb=0;eb<_extraActorCount&&eb<3u;++eb) {
        if(_extraActors[eb].model&&dc_model_tick(_extraActors[eb].model,actorDelta,tick,&_extraActors[eb].world)!=DC_OK)
            return @"Extra game actor tick failed";
    }
    if(_sceneType==7&&!_type7SwapPending&&_actor.model) {
        dc_animation_state t7Anim={0};
        if(dc_model_get_animation(_actor.model,&t7Anim)==DC_OK) {
            dc_type7_observe_clip(&_type7State,t7Anim.current);
            float clipProg=0.f;
            if(t7Anim.current<512u) {
                dc_animation_clip ci=_type7Clips[t7Anim.current];
                float span=ci.last_frame-ci.first_frame;
                if(span>0.001f)clipProg=fmaxf(0.f,fminf(1.f,(t7Anim.frame-ci.first_frame)/span));
            }
            dc_type7_plan tickPlan={0};
            if(dc_type7_tick(&_type7State,mapDelta,t7Anim.current,clipProg,&tickPlan)==DC_OK&&
               (tickPlan.body_count>0u||tickPlan.chain_count>0u||tickPlan.loop_count>0u||tickPlan.voice_stem[0]!='\0'||tickPlan.se_name[0]!='\0')) {
                NSString *t7Err=[self applyType7Plan:&tickPlan tick:tick];
                if(t7Err)return t7Err;
            }
        }
        [self applyType7ClothingAndVibeVisibility];
    } else if(_sceneType==12&&!_editPaused&&!_editExitFadeStarted&&!_pendingSystemAction&&actorDelta>0u&&_actor.model) {
        dc_animation_state editAfter={0};
        if(dc_model_get_animation(_actor.model,&editAfter)==DC_OK) {
            uint32_t expClip=_editExpectedClip<512u?_editExpectedClip:1u;
            int32_t chainClip=_editStepPlan.body_next_clip[0];
            BOOL clipEnded=NO;
            if(chainClip>=0&&chainClip<512) {
                uint32_t cc=(uint32_t)chainClip;
                if(editBefore.current==cc&&editAfter.current==cc) {
                    dc_animation_clip nc=_editClips[cc];
                    clipEnded=nc.loop?(nc.reverse?(editAfter.frame>editBefore.frame):(editAfter.frame<editBefore.frame||nc.last_frame<=nc.first_frame)):
                        (nc.reverse?(editAfter.frame<=nc.first_frame+0.001f):(editAfter.frame>=nc.last_frame-0.001f));
                } else if(cc!=expClip&&editBefore.current==cc&&editAfter.current!=cc) {
                    clipEnded=YES;
                }
            } else {
                dc_animation_clip ci=_editClips[expClip];
                if(ci.loop) {
                    if(editBefore.current==expClip&&editAfter.current==expClip)
                        clipEnded=ci.reverse?(editAfter.frame>editBefore.frame):(editAfter.frame<editBefore.frame||ci.last_frame<=ci.first_frame);
                } else if(editAfter.current==expClip) {
                    clipEnded=ci.reverse?(editAfter.frame<=ci.first_frame+0.001f):(editAfter.frame>=ci.last_frame-0.001f);
                }
            }
            if(clipEnded) {
                dc_edit_step_plan nextPlan={0};
                uint8_t advanced=0u;
                if(dc_edit_player_on_clip_end(&_editPlayer,&_editStateCopy,&nextPlan,&advanced)==DC_OK&&(advanced||nextPlan.finished)) {
                    NSString *stepErr=[self applyEditStepPlan:&nextPlan tick:tick];
                    if(stepErr)return stepErr;
                }
            }
        }
    }
    if(_face.model) {
        if(![self updateFaceAttachment])return @"Game face anchor lookup failed";
        if(!(_editMode&&_editPaused))[self updateFaceEyeBlinkAtTick:tick];
        if(dc_model_tick(_face.model,0,tick,&_face.world)!=DC_OK)return @"Game face tick failed";
    }
    for(uint32_t ef=0;ef<_extraFaceCount&&ef<2u;++ef) {
        if(_extraFaces[ef].model) {
            if(![self updateExtraFaceAttachmentAtIndex:ef])return @"Extra game face anchor lookup failed";
            if(!(_editMode&&_editPaused))[self updateExtraFaceEyeBlinkAtIndex:ef tick:tick];
            if(dc_model_tick(_extraFaces[ef].model,0,tick,&_extraFaces[ef].world)!=DC_OK)return @"Extra game face tick failed";
        }
    }
    [self updateWatchAuxiliaryPlacement];
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model) {
        if(dc_model_tick(_watchAuxiliary[auxiliary].model,actorDelta,tick,&_watchAuxiliary[auxiliary].world)!=DC_OK)
            return @"Watch auxiliary model tick failed";
    }
    if(_autoCamera.model) {
        dc_matrix target;
        if([self cameraBinding:DC_CAMERA_ANIMATION_TARGET matrix:&target]!=DC_OK)return @"Original animated camera target unavailable";
        _autoCamera.world=gameIdentity();
        for(unsigned i=0;i<3;++i)_autoCamera.world.values[12+i]=target.values[12+i];
        if(dc_model_tick(_autoCamera.model,delta,tick,&_autoCamera.world)!=DC_OK)return @"Original camera animation tick failed";
    }
    dc_camera_orbit orbit=[self activeCameraOrbit];dc_matrix automaticWorld=gameIdentity();
    if(_primaryCameraMode==2||_secondaryCameraMode==2) {
        if([self cameraBinding:DC_CAMERA_ANIMATION_EYE matrix:&_autoCameraEye]!=DC_OK||
           [self cameraBinding:DC_CAMERA_ANIMATION_TARGET matrix:&_autoCameraTarget]!=DC_OK)return @"Original automatic camera binding failed";
        /* 00513690 raises the look target by DAT_0062e664 (2.0), then calls
         * 00417ac0 on the eye supplied by the separate auto_cam animation. */
        _autoCameraTarget.values[13]+=2.f;
        if(dc_camera_look_at(&_autoCameraEye,&_autoCameraTarget,&automaticWorld)!=DC_OK)return @"Original automatic camera orientation failed";
    }
    if(_primaryCameraMode==2) {
        orbit=(dc_camera_orbit){.base=automaticWorld};++_cameraAutoFrames;
#if DEBUG
        if(_cameraAutoFrames==8&&[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
            [self requestRenderCapture:@"gameplay-camera-auto-later-native.png"];
#endif
    }
    dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices camera;
    if(dc_camera_build(&orbit,&lens,&camera)!=DC_OK)return @"Game camera build failed";
    _renderedCameraWorld=camera.world;
    {
        float camEye[3]={camera.world.values[12],camera.world.values[13],camera.world.values[14]};
        uint32_t procDelta=(_editMode&&_editPaused)?0u:mapDelta;
        BOOL bypassProc=(!_naturalGameplayRoute||touchExercise||renderCheckpoint);
        [self updateProceduralCharacterPoseWithCameraEye:camEye delta:procDelta clip:curAnim.current bypass:bypassProc];
    }
    float scale=fminf((float)width/1024,(float)height/768);dc_viewport viewport={(width-1024*scale)*.5f,(height-768*scale)*.5f,1024*scale,768*scale,0,1};
    dc_camera_orbit secondaryOrbit=_secondaryCamera;dc_camera_matrices secondaryCamera={0};
    if(cameraScene) {
        if(dc_camera_secondary_viewport(&viewport,&_secondaryViewport)!=DC_OK)return @"Original secondary viewport unavailable";
        if(_secondaryCameraMode==2) {
            secondaryOrbit=(dc_camera_orbit){.base=automaticWorld};++_secondaryAutoFrames;
#if DEBUG
            if(_secondaryAutoFrames==8&&[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
                [self requestRenderCapture:@"gameplay-secondary-auto-later-native.png"];
#endif
        }
        dc_camera_lens secondaryLens={.3f,.5f,10000,(uint32_t)_secondaryViewport.width,(uint32_t)_secondaryViewport.height};
        if(dc_camera_build(&secondaryOrbit,&secondaryLens,&secondaryCamera)!=DC_OK)return @"Original secondary camera build failed";
        _secondaryRenderedWorld=secondaryCamera.world;
    }
    _bypassLighting=(captureActive||!_naturalGameplayRoute||touchExercise||renderCheckpoint);
    size_t auxiliaryMeshes=_watchAuxiliary[0].model?_watchAuxiliary[0].info.submeshes:0;
    auxiliaryMeshes+=_watchAuxiliary[1].model?_watchAuxiliary[1].info.submeshes:0;
    size_t extraBodyMeshes=0,extraFaceMeshes=0;
    for(uint32_t eb=0;eb<_extraActorCount&&eb<3u;++eb)if(_extraActors[eb].model)extraBodyMeshes+=_extraActors[eb].info.submeshes;
    for(uint32_t ef=0;ef<_extraFaceCount&&ef<2u;++ef)if(_extraFaces[ef].model)extraFaceMeshes+=_extraFaces[ef].info.submeshes;
    size_t targetMeshes=_cameraTarget.model?_cameraTarget.info.submeshes:0;
    size_t geometryCapacity=(_map.info.submeshes+_actor.info.submeshes+extraBodyMeshes+_face.info.submeshes+extraFaceMeshes+auxiliaryMeshes+targetMeshes)*3*(_secondaryVisible?2:1)+16;
    size_t capacity=geometryCapacity+48+self.transitionScene.transitionMeshCapacity;
    dc_vk_geometry_item *draws=calloc(capacity,sizeof(*draws));if(!draws)return @"Game draw allocation failed";
    __attribute__((objc_precise_lifetime)) NSMutableArray *storage=[NSMutableArray array];size_t count=0;_visibleMapTriangles=_visibleActorTriangles=0;
    NSString *failure=[self append:&_map camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&_visibleMapTriangles];
    size_t mapDrawCount=count;
    if(!failure)failure=[self append:&_actor camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&_visibleActorTriangles];
    for(uint32_t eb=0;!failure&&eb<_extraActorCount&&eb<3u;++eb) {
        if(_extraActors[eb].model)
            failure=[self append:&_extraActors[eb] camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&_visibleActorTriangles];
    }
    if(!failure && delta && _actorSkinMeshCount)_actorSkinAdvanced=YES;
    BOOL actorHeadVis=(!_actor.model||_actorHeadNode==UINT32_MAX||dc_model_node_visible(_actor.model,_actorHeadNode)!=0);
    BOOL actorBodyVis=(!_actor.model||_kosiNode==UINT32_MAX||dc_model_node_visible(_actor.model,_kosiNode)!=0);
    if(!failure && _face.model && actorHeadVis)failure=[self append:&_face camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&_visibleActorTriangles];
    for(uint32_t ef=0;!failure&&ef<_extraFaceCount&&ef<2u;++ef) {
        if(!_extraFaces[ef].model)continue;
        dc_game_model *hbs=[self bodySlotAtIndex:_headBodyIndices[ef+1u]];
        BOOL ehVis=(!hbs||!hbs->model||_extraActorHeadNodes[ef]==UINT32_MAX||dc_model_node_visible(hbs->model,_extraActorHeadNodes[ef])!=0);
        if(ehVis)failure=[self append:&_extraFaces[ef] camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&_visibleActorTriangles];
    }
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(!failure&&actorBodyVis&&!_watchAuxUserHidden&&_watchAuxiliary[auxiliary].model)
        failure=[self append:&_watchAuxiliary[auxiliary] camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure)[self appendMapGlareBloomWithCamera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage];
    size_t primaryCleanCount=count;
    if(!failure&&cameraScene&&_cameraTargetVisible&&!bypassDynamicTex&&_primaryCameraTargetActive&&_primaryCameraMode!=2&&_cameraTarget.model) {
        _cameraTarget.world=gameIdentity();
        _cameraTarget.world.values[12]=orbit.base.values[12];
        _cameraTarget.world.values[13]=orbit.base.values[13]+orbit.height;
        _cameraTarget.world.values[14]=orbit.base.values[14];
        if(dc_model_tick(_cameraTarget.model,0,tick,&_cameraTarget.world)==DC_OK) {
            uint32_t targetTriangles=0;
            failure=[self append:&_cameraTarget camera:&camera viewport:&viewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&targetTriangles];
        }
    }
    size_t primarySceneCount=count,secondaryStart=count,secondaryMapCount=0,secondarySceneCount=0;
    if(!failure&&_secondaryVisible) {
        uint32_t secondaryMapTriangles=0,secondaryActorTriangles=0;
        failure=[self append:&_map camera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&secondaryMapTriangles];
        secondaryMapCount=count-secondaryStart;
        _renderingSecondaryViewport=YES;
        if(!failure)failure=[self append:&_actor camera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&secondaryActorTriangles];
        for(uint32_t eb=0;!failure&&eb<_extraActorCount&&eb<3u;++eb) {
            if(_extraActors[eb].model)
                failure=[self append:&_extraActors[eb] camera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&secondaryActorTriangles];
        }
        if(!failure&&_face.model&&actorHeadVis)failure=[self append:&_face camera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&secondaryActorTriangles];
        for(uint32_t ef=0;!failure&&ef<_extraFaceCount&&ef<2u;++ef) {
            if(!_extraFaces[ef].model)continue;
            dc_game_model *hbs=[self bodySlotAtIndex:_headBodyIndices[ef+1u]];
            BOOL ehVis=(!hbs||!hbs->model||_extraActorHeadNodes[ef]==UINT32_MAX||dc_model_node_visible(hbs->model,_extraActorHeadNodes[ef])!=0);
            if(ehVis)failure=[self append:&_extraFaces[ef] camera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&secondaryActorTriangles];
        }
        for(unsigned auxiliary=0;auxiliary<2;++auxiliary) {
            if(!failure&&actorBodyVis&&!_watchAuxUserHidden&&_watchAuxiliary[auxiliary].model)
                failure=[self append:&_watchAuxiliary[auxiliary] camera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage triangles:&secondaryActorTriangles];
        }
        _renderingSecondaryViewport=NO;
        if(!failure)[self appendMapGlareBloomWithCamera:&secondaryCamera viewport:&_secondaryViewport draws:draws capacity:geometryCapacity count:&count storage:storage];
        secondarySceneCount=count-secondaryStart;
    }
    size_t sceneDrawCount=count;
    if(!failure)failure=[self appendSceneUI:draws count:&count storage:storage viewport:viewport];
    if(!failure&&(_characterAction.transition_pending||(_motionStateInitialized&&_motionState.transition_pending)||_pendingSystemAction!=0||_type7SwapPending||_type7SwapFadeInActive||_editExitFadeStarted)) {
        failure=[self.transitionScene appendTransitionAtTick:tick viewport:viewport draws:draws capacity:capacity count:&count storage:storage];
    }
    if(!failure&&_editExitFadeStarted) {
        uint32_t ready=0;
        if(!self.transitionScene||[self.transitionScene queryTransitionReady:&ready]!=DC_OK) {
            failure=@"Edit exit transition query failed";
        } else if(ready) {
            _chapterEndAction=6u;
            _editExitFadeStarted=NO;
        }
    }
    if(!failure&&_type7SwapPending) {
        uint32_t ready=0;
        if(!self.transitionScene||[self.transitionScene queryTransitionReady:&ready]!=DC_OK) {
            failure=@"Type 7 swap transition query failed";
        } else if(ready) {
            _type7SwapPending=NO;
            dc_type7_plan swapPlan={0};
            NSString *swapErr=nil;
            if(dc_type7_complete_fade(&_type7State,&swapPlan)!=DC_OK||
               ![self loadType7ModelsAndCameraFromDirectory:_directory reloadOnly:YES error:&swapErr]) {
                failure=swapErr?:@"Type 7 swap reload failed";
            } else {
                failure=[self applyType7Plan:&swapPlan tick:tick];
                if(!failure&&self.transitionScene&&[self.transitionScene requestTransition:4 tick:tick]==DC_OK)
                    _type7SwapFadeInActive=YES;
            }
        }
    } else if(!failure&&_type7SwapFadeInActive) {
        uint32_t ready=0;
        if(self.transitionScene&&[self.transitionScene queryTransitionReady:&ready]==DC_OK&&ready)
            _type7SwapFadeInActive=NO;
    }
    if(!failure&&_characterAction.transition_pending) {
        uint32_t ready=0;
        if(!failure&&[self.transitionScene queryTransitionReady:&ready]!=DC_OK)failure=@"Character exit transition query failed";
        /* Only the initial progress-zero type-4 callback is admitted here.
         * Evolved progress and special ending routing require separate ports. */
        if(!failure&&ready){_chapterEndAction=_editMode?6:2;_characterAction.transition_pending=0;}
    }
    if(!failure&&_motionStateInitialized&&_motionState.transition_pending) {
        uint32_t ready=0;
        if(!self.transitionScene||[self.transitionScene queryTransitionReady:&ready]!=DC_OK)
            failure=@"Scene motion transition query failed";
        else if(ready&&_motionAudioReady) {
            _chapterEndAction=_editMode?6:2;
            _motionState.transition_pending=0;
        }
    }
    if(!failure) {
        dc_vk_clip_rect clip=gameClip(viewport,width,height),secondaryClip=_secondaryVisible?gameClip(_secondaryViewport,width,height):(dc_vk_clip_rect){0};
        if(_pendingUserScreenshot) {
            _pendingUserScreenshot=NO;
            NSMutableData *shotPixels=[NSMutableData dataWithLength:(size_t)width*height*4];
            if(gameRenderPasses(_renderer,draws,primaryCleanCount,secondaryStart,0,sceneDrawCount,0,clip,secondaryClip,NO,_backgroundColor,shotPixels.mutableBytes,shotPixels.length)==DC_OK) {
                uint8_t *buf=shotPixels.mutableBytes;
                for(size_t off=3;off<shotPixels.length;off+=4)buf[off]=255;
                if(_hasGlare&&!_bypassLighting)dc_glare_apply_rgba(&_glareInfo,buf,width,height);
                CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
                CGDataProviderRef dp=CGDataProviderCreateWithCFData((__bridge CFDataRef)shotPixels);
                CGImageRef img=CGImageCreate(width,height,8,32,width*4,cs,kCGBitmapByteOrderDefault|kCGImageAlphaPremultipliedLast,dp,NULL,false,kCGRenderingIntentDefault);
                CGDataProviderRelease(dp);CGColorSpaceRelease(cs);
                NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
                while(_userScreenshotSerial<10000u) {
                    NSString *capName=[NSString stringWithFormat:@"cap%04u.png",_userScreenshotSerial++];
                    NSURL *capURL=[documents URLByAppendingPathComponent:capName];
                    if(![NSFileManager.defaultManager fileExistsAtPath:capURL.path]) {
                        CGImageDestinationRef dst=img?CGImageDestinationCreateWithURL((__bridge CFURLRef)capURL,CFSTR("public.png"),1,NULL):NULL;
                        if(dst){CGImageDestinationAddImage(dst,img,NULL);CGImageDestinationFinalize(dst);CFRelease(dst);}
                        break;
                    }
                }
                if(img)CGImageRelease(img);
            }
        }
        BOOL capture=(_captureGameplayFrame&&!_capturedGameplayFrame)||_requestedRenderCapture!=nil;
        NSMutableData *pixels=capture?[NSMutableData dataWithLength:(size_t)width*height*4]:nil;
        if(gameRenderPasses(_renderer,draws,primarySceneCount,secondaryStart,secondarySceneCount,sceneDrawCount,count-sceneDrawCount,clip,secondaryClip,_secondaryVisible,_backgroundColor,pixels.mutableBytes,pixels.length)!=DC_OK)failure=@"Game Vulkan draw failed";
        if(!failure&&capture) {
            // Compare against the same GPU scene with no actor/face. A blue
            // background cannot masquerade as character visibility this way.
            NSMutableData *background=[NSMutableData dataWithLength:pixels.length];
            if(gameRenderPasses(_renderer,draws,mapDrawCount,secondaryStart,secondaryMapCount,sceneDrawCount,0,clip,secondaryClip,_secondaryVisible,_backgroundColor,background.mutableBytes,background.length)!=DC_OK)
                failure=@"Actor visibility background readback failed";
            if(failure){free(draws);return failure;}
            NSMutableData *scenePixels=[NSMutableData dataWithLength:pixels.length];
            if(gameRenderPasses(_renderer,draws,primarySceneCount,secondaryStart,secondarySceneCount,sceneDrawCount,0,clip,secondaryClip,_secondaryVisible,_backgroundColor,scenePixels.mutableBytes,scenePixels.length)!=DC_OK){free(draws);return @"Scene-only visibility readback failed";}
            NSMutableData *iconPixels=_contextOpen?[NSMutableData dataWithLength:pixels.length]:nil;
            if(iconPixels&&gameRenderPasses(_renderer,draws,primarySceneCount,secondaryStart,secondarySceneCount,sceneDrawCount,_sceneUIIconDraws,clip,secondaryClip,_secondaryVisible,_backgroundColor,iconPixels.mutableBytes,iconPixels.length)!=DC_OK){free(draws);return @"Scene context visibility readback failed";}
            NSMutableData *primaryOnly=_secondaryVisible?[NSMutableData dataWithLength:pixels.length]:nil;
            if(primaryOnly&&gameRenderPasses(_renderer,draws,primarySceneCount,secondaryStart,0,sceneDrawCount,0,clip,secondaryClip,NO,_backgroundColor,primaryOnly.mutableBytes,primaryOnly.length)!=DC_OK){free(draws);return @"Primary-only visibility readback failed";}
            if(gameRenderPasses(_renderer,draws,primarySceneCount,secondaryStart,secondarySceneCount,sceneDrawCount,count-sceneDrawCount,clip,secondaryClip,_secondaryVisible,_backgroundColor,NULL,0)!=DC_OK){free(draws);return @"Scene UI presentation restore failed";}
            const uint8_t *base=background.bytes,*scene=scenePixels.bytes;uint8_t *frame=pixels.mutableBytes;
            const uint8_t *icons=iconPixels.bytes;size_t uiVisible=0,contextVisible=0;
            size_t visible=0,primaryActorVisible=0,secondaryActorVisible=0,secondaryVisiblePixels=0,secondaryChangedOutside=0;uint32_t minX=width,minY=height,maxX=0,maxY=0;
            const uint8_t *primaryPixels=primaryOnly.bytes;
            for(uint32_t py=0;py<height;++py)for(uint32_t px=0;px<width;++px) {
                size_t offset=((size_t)py*width+px)*4;
                if(abs((int)scene[offset]-(int)base[offset])>8||
                   abs((int)scene[offset+1]-(int)base[offset+1])>8||
                   abs((int)scene[offset+2]-(int)base[offset+2])>8) {
                    ++visible;minX=MIN(minX,px);minY=MIN(minY,py);maxX=MAX(maxX,px);maxY=MAX(maxY,py);
                    if(_secondaryVisible&&px>=secondaryClip.x&&px<secondaryClip.x+secondaryClip.width&&py>=secondaryClip.y&&py<secondaryClip.y+secondaryClip.height)++secondaryActorVisible;
                    else ++primaryActorVisible;
                }
                if(primaryPixels&&(abs((int)scene[offset]-(int)primaryPixels[offset])>8||abs((int)scene[offset+1]-(int)primaryPixels[offset+1])>8||abs((int)scene[offset+2]-(int)primaryPixels[offset+2])>8)) {
                    if(px>=secondaryClip.x&&px<secondaryClip.x+secondaryClip.width&&py>=secondaryClip.y&&py<secondaryClip.y+secondaryClip.height)++secondaryVisiblePixels;
                    else ++secondaryChangedOutside;
                }
                if(abs((int)frame[offset]-(int)scene[offset])>8||abs((int)frame[offset+1]-(int)scene[offset+1])>8||abs((int)frame[offset+2]-(int)scene[offset+2])>8)++uiVisible;
                if(icons&&(abs((int)frame[offset]-(int)icons[offset])>8||abs((int)frame[offset+1]-(int)icons[offset+1])>8||abs((int)frame[offset+2]-(int)icons[offset+2])>8))++contextVisible;
                // CAMetalLayer is opaque. Store that presented RGB directly,
                // without misinterpreting the render-target blend alpha.
                frame[offset+3]=255;
            }
            CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
            CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrderDefault|kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault);
            CGDataProviderRelease(provider);CGColorSpaceRelease(color);
            NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSString *captureName=_requestedRenderCapture?:@"gameplay-first-native.png";
            NSURL *url=[documents URLByAppendingPathComponent:captureName];
            CGImageDestinationRef destination=image?CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL):NULL;
            BOOL saved=NO;if(destination){CGImageDestinationAddImage(destination,image,NULL);saved=CGImageDestinationFinalize(destination);CFRelease(destination);}
            if(image)CGImageRelease(image);
            if(saved) {
                _sceneUIVisiblePixels=uiVisible;if(_contextOpen)_sceneContextVisiblePixels=contextVisible;
                dc_animation_state pose={0};dc_model_get_animation(_actor.model,&pose);
                dc_animation_state cameraAnimation={0};
                if(_autoCamera.model)dc_model_get_animation(_autoCamera.model,&cameraAnimation);
                dc_camera_orbit controllerPose=[self activeCameraOrbit];
                _lastRenderCapture=@{@"file":captureName,@"chapter":@(_storyChapter),@"map":@(_mapSelector),
                    @"stage":@(_storyStage),@"anchor":_anchorName?:@"",@"camera":_cameraSource?:@"",
                    @"camera_preset":@(_cameraPreset),@"camera_modes":@[@(_primaryCameraMode),@(_secondaryCameraMode)],
                    @"camera_pose":@[@(orbit.height),@(orbit.stored_distance),@(orbit.pitch),@(orbit.yaw),@(orbit.base.values[12]),@(orbit.base.values[13]),@(orbit.base.values[14])],
                    @"camera_controller_pose":@[@(controllerPose.height),@(controllerPose.stored_distance),@(controllerPose.pitch),@(controllerPose.yaw),@(controllerPose.base.values[12]),@(controllerPose.base.values[13]),@(controllerPose.base.values[14])],
                    @"camera_world":gameMatrixValues(&_renderedCameraWorld),@"camera_target_binding":@(_lastCameraTargetBinding),
                    @"secondary_visible":@(_secondaryVisible),@"secondary_world":gameMatrixValues(&_secondaryRenderedWorld),
                    @"secondary_viewport":@[@(_secondaryViewport.x),@(_secondaryViewport.y),@(_secondaryViewport.width),@(_secondaryViewport.height),@(_secondaryViewport.min_z),@(_secondaryViewport.max_z)],
                    @"secondary_pose":@[@(secondaryOrbit.height),@(secondaryOrbit.stored_distance),@(secondaryOrbit.pitch),@(secondaryOrbit.yaw),@(secondaryOrbit.base.values[12]),@(secondaryOrbit.base.values[13]),@(secondaryOrbit.base.values[14])],
                    @"secondary_controller_pose":@[@(_secondaryCamera.height),@(_secondaryCamera.stored_distance),@(_secondaryCamera.pitch),@(_secondaryCamera.yaw),@(_secondaryCamera.base.values[12]),@(_secondaryCamera.base.values[13]),@(_secondaryCamera.base.values[14])],
                    @"secondary_target_binding":@(_secondaryTargetBinding),@"secondary_target_matrix":_secondaryRetargets?gameMatrixValues(&_secondaryTarget):@[],
                    @"secondary_actions":@(_secondaryActions),@"secondary_retargets":@(_secondaryRetargets),@"secondary_resets":@(_secondaryResets),
                    @"secondary_auto_enters":@(_secondaryAutoEnters),@"secondary_auto_leaves":@(_secondaryAutoLeaves),
                    @"secondary_pointer_owner":@(_pointerCameraOwner),@"secondary_pointer_operation":@(_secondaryLastPointerOperation),
                    @"secondary_pointer_input":@[@(_secondaryLastPointer.dx),@(_secondaryLastPointer.dy),@(_secondaryLastPointer.wheel),@(_secondaryLastPointer.left),@(_secondaryLastPointer.right),@(_secondaryLastPointer.middle),@(_secondaryLastPointer.fast)],
                    @"secondary_pointer_limits":@[@(_secondaryLimits.far_distance),@(_secondaryLimits.near_distance),@(_secondaryLimits.high),@(_secondaryLimits.low),@(_secondaryLimits.wheel_step)],
                    @"pointer_logical":@[@(((x+1)*.5f*width-viewport.x)/scale),@(((1-y)*.5f*height-viewport.y)/scale)],
                    @"secondary_pointer_before_base":gameMatrixValues(&_secondaryPointerBefore.base),
                    @"secondary_pointer_before_pose":@[@(_secondaryPointerBefore.height),@(_secondaryPointerBefore.stored_distance),@(_secondaryPointerBefore.pitch),@(_secondaryPointerBefore.yaw)],
                    @"secondary_auto_frames":@(_secondaryAutoFrames),@"secondary_pointer_updates":@(_secondaryPointerUpdates),
                    @"secondary_map_draws":@(secondaryMapCount),@"secondary_scene_draws":@(secondarySceneCount),@"secondary_visible_pixels":@(secondaryVisiblePixels),@"secondary_changed_outside":@(secondaryChangedOutside),
                    @"secondary_actor_visible_pixels":@(secondaryActorVisible),@"primary_actor_visible_pixels":@(primaryActorVisible),
                    @"camera_body_retargets":@(_cameraBodyRetargetCount),@"camera_auto_frames":@(_cameraAutoFrames),
                    @"camera_animation_clip":@(cameraAnimation.current),@"camera_animation_frame":@(cameraAnimation.frame),
                    @"automatic_eye_world":(_cameraAutoFrames||_secondaryAutoFrames)?gameMatrixValues(&_autoCameraEye):@[],
                    @"automatic_target":(_cameraAutoFrames||_secondaryAutoFrames)?@[@(_autoCameraTarget.values[12]),@(_autoCameraTarget.values[13]),@(_autoCameraTarget.values[14])]:@[],
                    @"automatic_center":_autoCamera.model?@[@(_autoCamera.world.values[12]),@(_autoCamera.world.values[13]),@(_autoCamera.world.values[14])]:@[],
                    @"camera_actions":@(_cameraActionCount),@"camera_resets":@(_cameraResetCount),@"camera_retargets":@(_cameraRetargetCount),
                    @"camera_target":_cameraRetargetCount?@[@(_lastCameraTarget.values[12]),@(_lastCameraTarget.values[13]),@(_lastCameraTarget.values[14])]:@[],
                    @"camera_target_matrix":_cameraRetargetCount?@[@(_lastCameraTarget.values[0]),@(_lastCameraTarget.values[1]),@(_lastCameraTarget.values[2]),@(_lastCameraTarget.values[3]),
                        @(_lastCameraTarget.values[4]),@(_lastCameraTarget.values[5]),@(_lastCameraTarget.values[6]),@(_lastCameraTarget.values[7]),
                        @(_lastCameraTarget.values[8]),@(_lastCameraTarget.values[9]),@(_lastCameraTarget.values[10]),@(_lastCameraTarget.values[11]),
                        @(_lastCameraTarget.values[12]),@(_lastCameraTarget.values[13]),@(_lastCameraTarget.values[14]),@(_lastCameraTarget.values[15])]:@[],
                    @"width":@(width),@"height":@(height),@"viewport_pixels":@((double)viewport.width*viewport.height),
                    @"scene_ui_draws":@(_sceneUIDraws),@"scene_ui_visible_pixels":@(uiVisible),@"context_visible_pixels":@(contextVisible),@"context_open":@(_contextOpen),@"context_icon":@(_contextMenu.icon),@"context_count":@(_contextMenu.count),
                    @"actor_visible_pixels":@(visible),@"actor_bbox":visible?@[@(minX),@(minY),@(maxX),@(maxY)]:@[],
                    @"interaction_active":@(_interactionActive),@"interaction_completed":@(_interactionCompleted),
                    @"pose_frame":@(pose.frame),@"depth_policy":@"material_auto",
                    @"animation_clip":@(pose.current),@"character_actions":@(_characterActionCount),@"character_starts":@(_characterAnimationStarts),
                    @"map_animation":@(_map.xaData!=nil),
                    @"world_position":@[@(_actor.world.values[12]),@(_actor.world.values[13]),@(_actor.world.values[14])]};
                NSData *metadata=[NSJSONSerialization dataWithJSONObject:_lastRenderCapture options:NSJSONWritingPrettyPrinted error:nil];
                [metadata writeToURL:[[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"] atomically:YES];
                _requestedRenderCapture=nil;_capturedGameplayFrame=YES;
            } else failure=@"Gameplay frame capture failed";
        }
    }
    if(!failure)_framePresented=YES;
    free(draws);return failure;
}
@end
