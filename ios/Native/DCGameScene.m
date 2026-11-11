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
    NSData *_mapVariantLightData;
    dc_xl_info _mapVariantLightInfo;
    dc_xl_light _mapVariantLight;
    dc_vk_sprite *_renderer;
    dc_game_model _map,_actor,_autoCamera,_cameraTarget;
    dc_game_model _face,_watchAuxiliary[2];
    uintptr_t _whiteTexture;
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
    BOOL _primaryCameraTargetActive,_secondaryCameraTargetActive;
    BOOL _faceBlushActive,_voiceBlushActive,_inExternalClimax;
    uint8_t _externalClimaxLevel;
    uint32_t _materialCycleSlot,_lastMaterialCycleTick,_lastDynamicTexMask;
    BOOL _gameFinished;
    NSString *_pendingVoiceName;
    float _voiceMouthPhase,_actorPlaybackSpeed;
    BOOL _watchDragging,_nightDragging;
    BOOL _scene4ObservedOnce,_watchPendingExitAfterClimax,_accessoryHidden,_watchAuxUserHidden;
    BOOL _watchNekoVibeVisible,_watchToriVibeVisible,_watchVibeSwitch;
    BOOL _vibeNekoUsed,_vibeToriUsed,_accessoryToggled;
    uint8_t _watchTopStage,_watchSkirtStage,_watchPantyStage;
    uint8_t _lastWatchTopStage,_lastWatchSkirtStage,_lastWatchPantyStage;
    int32_t _watchPart,_hoverTargetHit,_cursorIndex;
    int32_t _lastClothingPart;uint32_t _lastClothingClip;
    uint32_t _targetNodes[7],_skirtTargetNodes[2];
    float _cursorX,_cursorY;
    float _watchTouchGauge,_watchFeedbackStep,_watchUndressStep;
    float _nightExcitement,_nightFeedbackStep;
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
- (BOOL)vibeNekoUsed { return _vibeNekoUsed; }
- (BOOL)vibeToriUsed { return _vibeToriUsed; }
- (BOOL)vibratorLoopActive { return _watchVibeSwitch && !(_editMode && _editPaused) && !_characterAction.exit_pending && !_characterAction.transition_pending; }
- (BOOL)accessoryToggled { return _accessoryToggled; }
- (uint32_t)flowLevel { return _chapterEndAction==2?2:0; }
- (uint32_t)flowFlagB { return _chapterEndAction==2?1:0; }
- (uint32_t)flowCount {
    if(_motionStateInitialized&&_motionState.sample_count)return _motionState.sample_count;
    return _interactionCount;
}
- (uint32_t)storyStage { return _storyStage; }
- (uint32_t)sceneKind { return _sceneKind; }
- (uint32_t)sceneType { return _sceneType; }
- (BOOL)interactiveScene { return _sceneType>=4&&_sceneType<=6; }
- (BOOL)secondaryViewVisible { return _secondaryVisible; }
- (void)setSecondaryViewVisible:(BOOL)visible { _secondaryVisible=visible&&(_sceneType>=4&&_sceneType<=6); }
- (float)voiceMouthPhase { return _voiceMouthPhase; }
- (void)setVoiceMouthPhase:(float)phase {
    _voiceMouthPhase=isfinite(phase)&&phase>0.f?phase:0.f;
    if(_voiceMouthPhase<=0.01f&&!_pendingVoiceName)_voiceBlushActive=NO;
}
- (void)queueCharacterVoice:(NSString *)stem {
    if(!stem.length||_pendingVoiceName)return;
    _pendingVoiceName=[NSString stringWithFormat:@"%c%@",_characterPrefix,stem];
    NSString *lower=stem.lowercaseString;
    _voiceBlushActive=([lower hasPrefix:@"kx003"]||[lower hasPrefix:@"kx004"]||[lower hasPrefix:@"kx008"]||[lower hasPrefix:@"kx009"]||
                       [lower hasPrefix:@"cd00"]||[lower hasPrefix:@"cg004"]||[lower hasPrefix:@"cg007"]||[lower hasPrefix:@"cg008"]||
                       [lower hasPrefix:@"hd00"]||[lower hasPrefix:@"ht004"]||[lower hasPrefix:@"zg00"]||[lower hasPrefix:@"zd00"]||[lower hasPrefix:@"zd10"]);
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
- (BOOL)takeEditPauseStopRequest {
    if(!_editPauseStopRequested)return NO;
    _editPauseStopRequested=NO;return YES;
}
- (void)toggleEditPauseOrResetSpeed {
    if(_editSpeedMode!=0) {
        _editSpeedMode=0;_editPaused=NO;
    } else {
        _editPaused=!_editPaused;
        if(_editPaused){_pendingVoiceName=nil;_editPauseStopRequested=YES;}
    }
}
- (void)cycleEditSpeedMode {
    if(_editSpeedMode==0) {
        _editSpeedMode=1u;_editPaused=NO;
    } else {
        _editSpeedMode=(uint8_t)((_editSpeedMode%3u)+1u);
    }
}
- (uint32_t)takePendingEffectSlot {
    if(!_hasPendingEffect)return DC_SCENE_NO_REQUEST;
    _hasPendingEffect=NO;return _pendingEffectSlot;
}
- (NSString *)applyCharacterEvent:(dc_scene_character_event)event tick:(uint32_t)tick {
    if(event.configure_animation) {
        if(dc_model_set_chain(_actor.model,6,7)!=DC_OK||dc_model_set_loop(_actor.model,5,1)!=DC_OK)
            return @"Original character animation configuration failed";
    }
    if(event.request_clip!=DC_SCENE_NO_REQUEST) {
        if(dc_model_request(_actor.model,event.request_clip,tick)!=DC_OK)return @"Original character animation request failed";
        ++_characterAnimationStarts;
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
    if(_autoCamera.model)dc_model_shift_clock(_autoCamera.model,elapsed);
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
        dc_model_shift_clock(_watchAuxiliary[auxiliary].model,elapsed);
    _lastTick=_characterLastTick=tick;_characterClockInitialized=YES;
    _exitSoundStartTick+=elapsed;_interactionStartTick+=elapsed;_interactionState.start_tick+=elapsed;
    _eyeBlinkEndTick[0]+=elapsed;_eyeBlinkEndTick[1]+=elapsed;
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
        BOOL hideJokyaku=((_storyChapter==24&&_sceneType==6)||_editMode);
        dc_model_hide_node(_map.model,jokyaku4,hideJokyaku?1:0);
    }
    return nil;
}
- (NSString *)applyConfiguration:(const dc_config *)configuration {
    if(!configuration)return @"Missing scene configuration";
    uint32_t secondary=0,hair=1,cameraTarget=1;float wheel=4;
    dc_config_switch_value(configuration,3,&hair);
    dc_config_switch_value(configuration,4,&secondary);
    dc_config_switch_value(configuration,5,&cameraTarget);
    dc_config_slider_value(configuration,6,&wheel);
    _hairVisible=hair!=0;_cameraTargetVisible=cameraTarget!=0;
    _secondaryVisible=(_sceneType>=4&&_sceneType<=6)&&secondary!=0;_secondaryLimits.wheel_step=wheel;
    for(unsigned i=0;i<3;++i){
        uint32_t visible;dc_config_switch_value(configuration,i,&visible);
        _mapLayerVisible[i]=visible!=0;
        float channel;dc_config_slider_value(configuration,7+i,&channel);_backgroundColor[i]=(uint8_t)channel;
    }
    _backgroundColor[3]=255;
    return [self applyMapLayerVisibility];
}
- (dc_camera_orbit)activeCameraOrbit {
    float height=fmaxf(_secondaryLimits.low,fminf(_secondaryLimits.high,_cameraHeight+_padCameraHeight));
    dc_camera_orbit orbit={.base=_cameraBase,.stored_distance=_cameraDistance*expf(_padCameraZoom),
        .height=height,.pitch=_cameraPitch+_padCameraPitch,.yaw=_cameraYaw+_padCameraYaw};
    orbit.base.values[12]=_cameraOriginX+_actor.world.values[12]-_actorOriginX+_padCameraPanX;
    orbit.base.values[13]=_cameraBase.values[13]+_actor.world.values[13]-_actorOriginY;
    orbit.base.values[14]=_cameraOriginZ+_actor.world.values[14]-_actorOriginZ+_padCameraPanZ;
    return orbit;
}
- (void)adoptCameraOrbit:(dc_camera_orbit)orbit {
    _cameraBase=orbit.base;
    _cameraBase.values[12]-=_actor.world.values[12]-_actorOriginX;
    _cameraBase.values[13]-=_actor.world.values[13]-_actorOriginY;
    _cameraBase.values[14]-=_actor.world.values[14]-_actorOriginZ;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _cameraDistance=orbit.stored_distance;_cameraHeight=orbit.height;_cameraPitch=orbit.pitch;_cameraYaw=orbit.yaw;
    _padCameraYaw=_padCameraPitch=_padCameraZoom=_padCameraHeight=_padCameraPanX=_padCameraPanZ=0;
    _cameraAutoSelected=YES;
}
- (NSString *)applyContextSelection:(uint32_t)selection {
    BOOL touchExercise=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"];
    if(_contextMenu.icon==2) {
        int32_t resourceId=(selection<_contextMenu.count)?_contextMenu.items[selection].resource_id:-1;
        if(resourceId>=16||(_sceneType==5&&_stageProgress==1&&!_editMode&&!touchExercise)) {
            _accessoryHidden=!_accessoryHidden;
            _accessoryToggled=YES;
            [self applyBaseOutfitVisibility:_outfitVariant];
            _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
            _pendingEffectSlot=2;_hasPendingEffect=YES;
            ++_characterActionCount;
            return nil;
        }
        if(selection<4) {
            if(_sceneType==4&&_stageProgress==1&&!_editMode&&!touchExercise)
                _outfitVariant=(_outfitVariant==0)?1u:0u;
            else if(_naturalGameplayRoute&&!touchExercise) {
                uint32_t targetVariant=(selection+1u)&3u;
                _outfitVariant=(_outfitVariant==targetVariant)?selection:targetVariant;
            } else
                _outfitVariant=selection&3u;
            if(_outfitVariant<2&&(_watchNekoVibeVisible||_watchToriVibeVisible||_watchVibeSwitch)) {
                _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
                _actorPlaybackSpeed=1.0f;
                if(_actor.model) {
                    dc_animation_state anim={0};
                    if(dc_model_get_animation(_actor.model,&anim)==DC_OK) {
                        if(_sceneType==4&&(anim.current==11u||anim.current==13u)) {
                            dc_model_set_chain(_actor.model,6u,7u);
                            dc_model_set_chain(_actor.model,15u,1u);
                            dc_model_set_chain(_actor.model,16u,1u);
                            dc_model_request(_actor.model,(anim.current==13u)?16u:15u,_lastTick);
                        } else if(_sceneType==5&&anim.current==201u) {
                            _motionState.clip=21u;
                            dc_model_request(_actor.model,21u,_lastTick);
                        }
                    }
                }
            }
            [self applyOutfitVariant:_outfitVariant];
            if(_sceneType==5&&_naturalGameplayRoute&&!touchExercise&&_outfitVariant>=2&&_actor.model) {
                dc_animation_state anim={0};
                if(dc_model_get_animation(_actor.model,&anim)==DC_OK&&anim.current==33u) {
                    uint32_t nextClip=34u+(_voiceSequenceIndex%5u);
                    _motionState.clip=nextClip;
                    dc_model_request(_actor.model,nextClip,_lastTick);
                }
            }
            _pendingEffectSlot=2;_hasPendingEffect=YES;
            ++_characterActionCount;
            return nil;
        }
        if(!touchExercise) {
            _accessoryHidden=!_accessoryHidden;
            _accessoryToggled=YES;
            [self applyBaseOutfitVisibility:_outfitVariant];
            _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
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
                dc_model_set_loop(_actor.model,5,1);
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
                if(_outfitVariant<2) {
                    _outfitVariant=(resourceId==4)?2u:3u;
                    [self applyOutfitVariant:_outfitVariant];
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
                [self applyBaseOutfitVisibility:_outfitVariant];
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
                for(NSString *v in @[@"a_On_neko_vive",@"a_On_tori_vive"]) {
                    uint32_t vn=[self findNode:&_actor name:[self characterNode:v]];
                    if(vn!=UINT32_MAX)dc_model_hide_node(_actor.model,vn,1);
                }
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
                    _nightQuestionAsked=YES;
                    _pendingEffectSlot=1u;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:NO];
                    return nil;
                }
                if(resourceId==9||resourceId==10||((_motionState.clip>=10&&_motionState.clip<=26)&&selection<2)) {
                    ++_characterActionCount;
                    BOOL separate=(resourceId==10||selection==1);
                    if(separate) {
                        if(_motionState.outcome_a>0)--_motionState.outcome_a;
                        if(_motionState.outcome_b<10000)++_motionState.outcome_b;
                    } else {
                        if(_motionState.outcome_a==0)_motionState.outcome_a=1;
                    }
                    _stageOutcomeA=(uint32_t)_motionState.outcome_a;
                    _stageOutcomeB=(uint32_t)_motionState.outcome_b;
                    uint32_t targetClip=separate?30u:27u;
                    _motionState.clip=targetClip;_motionState.phase=2;_motionState.pointer_mode=0;
                    _nightExcitement=0.f;_nightDragging=NO;_actorPlaybackSpeed=1.0f;
                    _pendingEffectSlot=separate?2u:15u;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:6 climax:!separate];
                    ++_interactionCount;_interactionCompleted=YES;
                    _player.interaction_count=_interactionCount;_playerSaveDirty=YES;
                    dc_scene_motion_event ev={
                        .request_clip=targetClip,
                        .request_chain_from=separate?32u:DC_SCENE_MOTION_NO_REQUEST,
                        .request_chain_to=separate?55u:DC_SCENE_MOTION_NO_REQUEST
                    };
                    return [self applyMotionEvent:ev tick:_lastTick];
                }
                if(resourceId==11||resourceId==12||((_motionState.clip>=27&&_motionState.clip<=54)&&selection<2)) {
                    ++_characterActionCount;
                    BOOL finishPos2=(resourceId==12||selection==1);
                    if(finishPos2) {
                        if(_motionState.outcome_b==0)_motionState.outcome_b=1;
                    } else {
                        if(_motionState.outcome_a<10000)++_motionState.outcome_a;
                    }
                    _stageOutcomeA=(uint32_t)_motionState.outcome_a;
                    _stageOutcomeB=(uint32_t)_motionState.outcome_b;
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
                    if(resourceId==1){if(_motionState.outcome_a<10000)++_motionState.outcome_a;}
                    else {if(_motionState.outcome_b<10000)++_motionState.outcome_b;if(_pos2SelectedCount<10000)++_pos2SelectedCount;}
                    _stageOutcomeA=(int32_t)_motionState.outcome_a;
                    _stageOutcomeB=(int32_t)_motionState.outcome_b;
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
                _watchPart=-1;_watchDragging=NO;
                for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                    dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
                dc_animation_state anim={0};
                uint32_t curClip=(_actor.model&&dc_model_get_animation(_actor.model,&anim)==DC_OK)?anim.current:_motionState.clip;
                BOOL inIdle=(curClip==1u||curClip==9u||curClip==15u||curClip==21u||curClip==27u||curClip==33u||curClip==39u||curClip==245u);
                uint32_t targetClip=inIdle?curClip:21u;
                if(resourceId==1||resourceId==2) {
                    if(resourceId==1){_watchNekoVibeVisible=YES;_vibeNekoUsed=YES;if(_storyStage!=1&&_stageProgress<=1)_tearVisible=YES;}
                    else {_watchToriVibeVisible=YES;_vibeToriUsed=YES;if(_storyStage!=0||_stageProgress<=1)_tearVisible=YES;}
                    if(_watchSkirtStage<1)_watchSkirtStage=1;
                    if(_watchPantyStage<1)_watchPantyStage=1;
                    [self applyBaseOutfitVisibility:_outfitVariant];
                    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                    _pendingEffectSlot=2;_hasPendingEffect=YES;
                    [self queueCyclicReactionVoiceForScene:5 climax:NO];
                } else if(resourceId==3) {
                    _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
                    if(_watchPantyStage==1)_watchPantyStage=0;
                    [self applyBaseOutfitVisibility:_outfitVariant];
                    _lastClothingPart=-2;_lastClothingClip=UINT32_MAX;
                    _pendingEffectSlot=2;_hasPendingEffect=YES;
                } else {
                    _watchVibeSwitch=(resourceId==4);
                    _pendingEffectSlot=3;_hasPendingEffect=YES;
                    if(_watchVibeSwitch)[self queueCyclicReactionVoiceForScene:5 climax:NO];
                }
                _actorPlaybackSpeed=_watchVibeSwitch?1.65f:((_watchNekoVibeVisible||_watchToriVibeVisible)?1.25f:1.0f);
                _motionState.clip=targetClip;_motionState.phase=1;
                if(!inIdle) {
                    if(dc_model_request(_actor.model,targetClip,_lastTick)!=DC_OK)return @"Original watch vibrator animation request failed";
                    ++_characterAnimationStarts;
                }
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
                    if(selection==1&&_pos2SelectedCount<10000)++_pos2SelectedCount;
                    _stageOutcomeA=_motionState.outcome_a;
                    _stageOutcomeB=_motionState.outcome_b;
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
            dc_status transStatus=[self.transitionScene requestTransition:2];
            if(transStatus!=DC_OK)return @"System transition request failed";
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
            dc_status transStatus=[self.transitionScene requestTransition:2];
            if(transStatus!=DC_OK)return @"System transition request failed";
            _pendingEffectSlot=1u;_hasPendingEffect=YES;
            return nil;
        }
    }
    dc_scene_action_plan plan;
    uint32_t actionSceneType=(_contextMenu.icon>=3&&_sceneType>=4&&_sceneType<=6)?4:_sceneType;
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
    char name[32];dc_status status=dc_camera_scene_node(_storyStage,binding,name,sizeof(name));
    if(status!=DC_OK)return status;
    dc_game_model *slot=binding==DC_CAMERA_FACE_TARGET?&_face:
        (binding==DC_CAMERA_ANIMATION_EYE?&_autoCamera:&_actor);
    if(!slot->model)return DC_NOT_FOUND;
    uint32_t node=[self findNode:slot name:[NSString stringWithUTF8String:name]];
    return node==UINT32_MAX?DC_NOT_FOUND:dc_model_global(slot->model,node,out);
}
- (NSString *)stepContextAtX:(float)x y:(float)y left:(uint32_t)left right:(uint32_t)right {
    dc_scene_context_event event;
    if(dc_scene_context_step(&_contextMenu,x,y,left,right,&event)!=DC_OK)return @"Scene context input failed";
    if(event.close_code) {
        _contextOpen=NO;
        if(event.selected>=0) {
            ++_contextSelections;_lastContextSelection=event.selected;
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
- (void)applyBaseOutfitVisibility:(uint32_t)variant {
    [self applyInitialVisibility];
    NSArray<NSString *> *top=@[@"a_On_wanpi",@"a_On_wanpi_U",@"a_On_wanpiEHC",@"a_On_ribon",@"a_On_belt",
        @"b_Nn_sera_OBJ",@"c_On_uwagi"];
    NSArray<NSString *> *skirt=@[@"a_On_skart",@"a_On_skart_mae",@"a_On_skart_usiro",@"a_On_skartHA"];
    NSArray<NSString *> *bra=@[@"a_On_bura",@"a_On_buraH"];
    NSArray<NSString *> *panty=@[@"a_On_pantu",@"a_On_pantuH"];
    if(variant>=1&&variant<=3) {
        for(NSString *name in top){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    }
    if(variant==2||variant==3) {
        for(NSString *name in skirt){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
        for(NSString *name in bra){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    }
    if(variant==3) {
        for(NSString *name in panty){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    }
    if(_watchNekoVibeVisible) {
        uint32_t vn=[self findNode:&_actor name:[self characterNode:@"a_On_neko_vive"]];
        if(vn!=UINT32_MAX)dc_model_hide_node(_actor.model,vn,0);
    }
    if(_watchToriVibeVisible) {
        uint32_t vn=[self findNode:&_actor name:[self characterNode:@"a_On_tori_vive"]];
        if(vn!=UINT32_MAX)dc_model_hide_node(_actor.model,vn,0);
    }
    if(_accessoryHidden) {
        if(_storyStage==0&&_face.model) {
            uint32_t longHair=[self findNode:&_face name:@"b_On_long"];
            if(longHair!=UINT32_MAX)dc_model_hide_node(_face.model,longHair,0);
            for(NSString *twin in @[@"b_On_kami_L",@"b_On_kami_R"]) {
                uint32_t n=[self findNode:&_face name:twin];
                if(n!=UINT32_MAX)dc_model_hide_node(_face.model,n,1);
            }
        } else if(_storyStage==1) {
            for(NSString *glass in @[@"c_On_megane",@"c_Nn_megane_ani"]) {
                uint32_t fn=_face.model?[self findNode:&_face name:glass]:UINT32_MAX;
                if(fn!=UINT32_MAX)dc_model_hide_node(_face.model,fn,1);
                uint32_t an=_actor.model?[self findNode:&_actor name:glass]:UINT32_MAX;
                if(an!=UINT32_MAX)dc_model_hide_node(_actor.model,an,1);
            }
        } else if(_storyStage==2&&_face.model) {
            uint32_t ears=[self findNode:&_face name:@"a_On_nekomimi"];
            if(ears!=UINT32_MAX)dc_model_hide_node(_face.model,ears,0);
        }
    }
}
- (void)syncDynamicClothingForPart:(int32_t)part clip:(uint32_t)clip {
    if(!_actor.model||(part==_lastClothingPart&&clip==_lastClothingClip&&
       _watchTopStage==_lastWatchTopStage&&_watchSkirtStage==_lastWatchSkirtStage&&_watchPantyStage==_lastWatchPantyStage))return;
    _lastClothingPart=part;_lastClothingClip=clip;
    _lastWatchTopStage=_watchTopStage;_lastWatchSkirtStage=_watchSkirtStage;_lastWatchPantyStage=_watchPantyStage;
    [self applyBaseOutfitVisibility:_outfitVariant];
    if(_sceneType==5) {
        uint8_t topStage=MAX(_watchTopStage,(uint8_t)((_outfitVariant>=2)?2:(_outfitVariant==1?1:0)));
        uint8_t skirtStage=MAX(_watchSkirtStage,(uint8_t)((_outfitVariant>=2)?1:0));
        uint8_t pantyStage=MAX(_watchPantyStage,(uint8_t)((_outfitVariant>=3)?1:0));
        if(topStage>=1&&_outfitVariant<2) {
            NSArray<NSString *> *hideTop=@[@"b_Nn_sera_OBJ",@"c_On_uwagi",@"a_On_wanpi",@"a_On_wanpi_U"];
            NSArray<NSString *> *showTopH=@[@"b_On_seraH_O",@"b_On_seraH_U",@"b_On_eriH_O",@"b_On_eriH_U",
                @"b_On_shatuH",@"b_On_shatuH_U",@"b_On_nekuH_R",@"c_On_uwagiH",@"c_On_uwagiH_U",
                @"a_On_wanpiHEC",@"a_On_wanpiHEC_U"];
            for(NSString *name in hideTop){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,1);}
            if(_outfitVariant==0) {
                for(NSString *name in showTopH){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);}
            }
            if(topStage>=2) {
                uint32_t bra=[self findNode:&_actor name:[self characterNode:@"a_On_bura"]];
                if(bra!=UINT32_MAX)dc_model_hide_node(_actor.model,bra,1);
                for(NSString *name in @[@"a_On_buraH",@"a_On_buraH_U"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);}
            }
        }
        if(skirtStage==1&&_outfitVariant<2) {
            for(NSString *name in @[@"a_On_skart",@"a_On_wanpi",@"a_On_wanpi_U"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,1);}
            for(NSString *name in @[@"a_On_skartHF",@"a_On_skartHF_U",@"a_On_wanpiEHM",@"a_On_wanpiEHM_U"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);}
        } else if(skirtStage>=2&&_outfitVariant<2) {
            for(NSString *name in @[@"a_On_skart",@"a_On_wanpi",@"a_On_wanpi_U"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,1);}
            for(NSString *name in @[@"a_On_skartHB",@"a_On_skartHB_U",@"a_On_wanpiEHU",@"a_On_wanpiEHU_U"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);}
        }
        if(pantyStage>=1&&_outfitVariant<3) {
            for(NSString *name in @[@"a_On_pantu"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,1);}
            for(NSString *name in @[@"a_On_pantuH",@"a_On_pantuH1"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);}
        }
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
        if(clip>=10&&clip<=54&&_outfitVariant<3) {
            for(NSString *name in @[@"a_On_pantu"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,1);}
            for(NSString *name in @[@"a_On_pantuH",@"a_On_pantuH1"]){uint32_t n=[self findNode:&_actor name:[self characterNode:name]];if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);}
        }
        if((clip>=24&&clip<=32)||(clip>=55&&clip<=58)||_nightExcitement>0.f) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_mata_siru"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
        }
        if((clip>=24&&clip<=32)||(clip>=55&&clip<=58)||_externalClimaxLevel>0u) {
            uint32_t n=[self findNode:&_actor name:[self characterNode:@"a_On_kokan_siru"]];
            if(n!=UINT32_MAX)dc_model_hide_node(_actor.model,n,0);
        }
        if((clip>=26&&clip<=32)||(clip>=55&&clip<=57)) {
            BOOL big=(_stageOutcomeA+_stageOutcomeB)>1u;
            NSString *primary=(clip>=55)?(big?@"b_On_tare2_big":@"b_On_tare2_small"):(big?@"b_On_tare_big":@"b_On_tare_small");
            NSString *fallback=big?@"b_On_tare_big":@"b_On_tare_small";
            uint32_t tn=[self findNode:&_actor name:[self characterNode:primary]];
            if(tn==UINT32_MAX)tn=[self findNode:&_actor name:[self characterNode:fallback]];
            if(tn!=UINT32_MAX)dc_model_hide_node(_actor.model,tn,0);
        }
    }
}
- (void)updateWatchAuxiliaryPlacement {
    if(_sceneType!=5||_watchPart<0||_watchPart>=7)return;
    dc_game_model *slot=(_watchPart==0&&_face.model)?&_face:&_actor;
    uint32_t node=_targetNodes[_watchPart];
    if(_watchPart==0&&node==UINT32_MAX){slot=&_actor;node=_actorHeadNode;}
    else if(_watchPart==3&&_outfitVariant<2&&_skirtTargetNodes[0]!=UINT32_MAX)node=_skirtTargetNodes[0];
    else if(_watchPart==4&&_outfitVariant<2&&_skirtTargetNodes[1]!=UINT32_MAX)node=_skirtTargetNodes[1];
    dc_matrix targetWorld;
    if(!slot->model||node==UINT32_MAX||dc_model_global(slot->model,node,&targetWorld)!=DC_OK)return;
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)
        _watchAuxiliary[auxiliary].world=targetWorld;
}
- (void)applyOutfitVariant:(uint32_t)variant {
    /* Original 0x5181f0-style outfit selection through hidden alternate
     * outfit meshes. Variant 1 shows the skirt set instead of the dress,
     * variant 2 removes the bra, variant 3 removes the panties; any other
     * variant restores the default visibility. */
    if(variant<2||!_loaded) {
        _watchNekoVibeVisible=NO;_watchToriVibeVisible=NO;_watchVibeSwitch=NO;
    }
    _watchTopStage=(variant>=2)?2u:(variant==1?1u:0u);
    _watchSkirtStage=(variant>=2)?1u:0u;
    _watchPantyStage=(variant>=3||_watchNekoVibeVisible||_watchToriVibeVisible)?1u:0u;
    [self applyBaseOutfitVisibility:variant];
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
    dc_matrix target;
    return _actorHeadNode!=UINT32_MAX &&
        dc_model_global(_actor.model,_actorHeadNode,&target)==DC_OK &&
        dc_matrix_multiply(&_faceBindInverse,&target,&_face.world)==DC_OK;
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
        @"b_On_seraH_O",@"b_On_seraH_U",@"b_On_eriH_O",@"b_On_eriH_U",@"b_On_shatuH",@"b_On_shatuH_U",@"b_On_nekuH_R",
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
        @"c_Nn_megane_ani",
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
        @"a_On_kuchsiru_o",@"a_On_namida",@"b_On_long",@"c_Nn_megane_ani"];
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
    float currentFloor=_actor.world.values[13]-_actorRootFloorOffset,floorY;
    if(![self surfaceYAtX:next->x z:next->z nearY:currentFloor result:&floorY] || fabsf(floorY-currentFloor)>2.f)return NO;
    _player=*next;_playerSaveDirty=YES;
    _actor.world.values[12]=next->x;_actor.world.values[14]=next->z;
    _actor.world.values[13]=floorY+_actorRootFloorOffset;
    return YES;
}

- (uint32_t)placementNodeFromPLST:(NSData *)data model:(dc_game_model *)slot {
    if(!data || data.length<9 || !slot->xx) return UINT32_MAX;
    const uint8_t *bytes=data.bytes;size_t cursor=4;
    /* The observed PLST record starts with a one-byte variant, then four
     * encoded name blocks and an eight-byte zero tail. */
    cursor+=1;
    uint32_t selected=UINT32_MAX;
    while(cursor+4<=data.length) {
        uint32_t length=0;memcpy(&length,bytes+cursor,sizeof(length));cursor+=4;
        if(!length)break;
        if(length>1024 || cursor+length>data.length) return UINT32_MAX;
        NSString *name=[self decodedName:bytes+cursor length:length];cursor+=length;
        uint32_t node=[self findNode:slot name:name];if(node!=UINT32_MAX)selected=node;
    }
    return selected;
}

- (NSData *)entry:(NSString *)name archive:(DCArchive *)archive error:(NSString **)error {
    for(uint32_t i=0;i<archive.entryCount;++i)
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame)
            return [archive readEntryAtIndex:i limit:128*1024*1024 error:nil];
    if(error)*error=[NSString stringWithFormat:@"Missing game resource %@",name];
    return nil;
}
- (NSData *)lightEntryForSelector:(uint32_t)selector archive:(DCArchive *)archive {
    NSString *suffix=(_sceneType==6?@"_02.xl":@"_01.xl");
    NSString *prefix=[NSString stringWithFormat:@"pp%02u",selector];
    for(uint32_t i=0;i<archive.entryCount;++i) {
        NSString *name=[archive asciiNameAtIndex:i];
        if(!name || ![name.lowercaseString hasPrefix:prefix.lowercaseString] ||
           ![name.lowercaseString hasSuffix:suffix.lowercaseString]) continue;
        return [archive readEntryAtIndex:i limit:128*1024 error:nil];
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
    _lightData=data;_lightInfo=info;_mapLight=light;return YES;
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
    _mapVariantLightData=data;_mapVariantLightInfo=info;_mapVariantLight=light;return YES;
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
    NSString *stage = [NSString stringWithFormat:@"%c", _characterPrefix];
    NSString *name = [NSString stringWithFormat:@"m_Nn_yuka_%@_%@", prefix, stage];
    uint32_t node=[self findNode:slot name:name];
    if(node!=UINT32_MAX)return node;
    if(_sceneType==6 && (_mapSelector==0 || _mapSelector==1)) {
        uint32_t hNode=[self findNode:slot name:@"m_Nn_yuka_5_a"];
        if(hNode!=UINT32_MAX)return hNode;
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
- (void)loadPlayerState {
    NSString *path=[_directory stringByAppendingPathComponent:@"save/player.state"];
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
    _actor.world.values[12]=_player.x;_actor.world.values[14]=_player.z;
    _actor.world.values[13]=floor+_actorRootFloorOffset;
    _resumedPlayer=YES;
}
- (BOOL)savePlayerState {
    if(!_playerSaveDirty||_editMode)return YES;
    NSMutableData *data=[NSMutableData dataWithLength:DC_GAME_PLAYER_SAVE_BYTES];
    if(dc_game_player_save(&_player,data.mutableBytes,data.length)!=DC_OK)return NO;
    NSString *path=[_directory stringByAppendingPathComponent:@"save/player.state"];
    NSData *existing=[NSData dataWithContentsOfFile:path];
    NSMutableData *combined=[NSMutableData dataWithData:data];
    if(existing.length>DC_GAME_PLAYER_SAVE_BYTES)
        [combined appendBytes:(const uint8_t *)existing.bytes+DC_GAME_PLAYER_SAVE_BYTES length:existing.length-DC_GAME_PLAYER_SAVE_BYTES];
    NSString *directory=[_directory stringByAppendingPathComponent:@"save"];[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
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
    dc_camera_orbit orbit=[self activeCameraOrbit];dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices camera;
    dc_viewport viewport={0,0,1024,768,0,1};
    if(dc_camera_build(&orbit,&lens,&camera)!=DC_OK)return -1;
    dc_model *models[2]={_actor.model,_face.model};
    float minX=1024.f,minY=768.f,maxX=0,maxY=0;BOOL found=NO;
    for(unsigned m=0;m<2;++m) {
        if(!models[m])continue;
        dc_xx_info info;if(dc_model_get_info(models[m],&info)!=DC_OK)continue;
        for(uint32_t meshIndex=0;meshIndex<info.submeshes;++meshIndex) {
            uint32_t visible=0;dc_xx_submesh mesh;size_t count=0;
            if(dc_model_mesh(models[m],meshIndex,&mesh)!=DC_OK||
               dc_model_mesh_visible(models[m],meshIndex,&visible)!=DC_OK||!visible)continue;
            if(dc_model_project_clipped(models[m],meshIndex,&camera.view_projection,&viewport,0xffffffff,NULL,0,&count)!=DC_OK||!count)continue;
            dc_sprite_vertex *vertices=calloc(count,sizeof(*vertices));if(!vertices)continue;
            if(dc_model_project_clipped(models[m],meshIndex,&camera.view_projection,&viewport,0xffffffff,vertices,count,&count)==DC_OK)
                for(size_t i=0;i<count;++i){minX=MIN(minX,vertices[i].x);minY=MIN(minY,vertices[i].y);maxX=MAX(maxX,vertices[i].x);maxY=MAX(maxY,vertices[i].y);found=YES;}
            free(vertices);
        }
    }
    if(!found||px<minX||px>maxX||py<minY||py>maxY)return -1;
    static const float kTargetRadius[7]={180.f,150.f,150.f,225.f,225.f,150.f,150.f};
    float targetSX[7],targetSY[7],targetW[7];
    BOOL targetValid[7]={NO};
    for(unsigned t=0;t<7;++t) {
        dc_game_model *slot=(t==0&&_face.model)?&_face:&_actor;
        uint32_t node=_targetNodes[t];
        if(t==0&&node==UINT32_MAX){slot=&_actor;node=_actorHeadNode;}
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
        targetSX[t]=(clip[0]*rhw+1.f)*512.f;
        targetSY[t]=(1.f-clip[1]*rhw)*384.f;
        targetW[t]=clip[3];
        targetValid[t]=isfinite(targetSX[t])&&isfinite(targetSY[t]);
    }
    BOOL backView=(targetValid[3]&&targetValid[4]&&targetW[4]<targetW[3]);
    int32_t bestTarget=-1;float bestMetric=FLT_MAX;
    for(unsigned t=0;t<7;++t) {
        if(!targetValid[t])continue;
        if(backView&&(t==1||t==2||t==3))continue;
        if(!backView&&t==4)continue;
        float dx=px-targetSX[t],dy=py-targetSY[t];
        float r=kTargetRadius[t];
        float metric=(dx*dx+dy*dy)/(r*r);
        if(metric<bestMetric){bestMetric=metric;bestTarget=(int32_t)t;}
    }
    if(bestTarget>=0)return bestTarget;
    float heightRange=fmaxf(1.f,maxY-minY);int32_t index=(int32_t)floorf((py-minY)/heightRange*7.f);
    if(index<0)index=0;if(index>6)index=6;return index;
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
            {15,10},{22,10},{23,10},{24,26},{25,26},
            {40,41},{41,40},{42,43},{43,42},{48,49},{49,50},{50,49},
            {44,39},{51,39},{52,39},{54,55}
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
    [self applyInitialVisibility];
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
    [self loadMapVariantLightForSelector:_mapSelector archive:mapArchive error:nil];
    if(lightArchive) [self loadLightForSelector:_mapSelector archive:lightArchive error:nil];
    for(uint32_t mesh=0;mesh<_actor.info.submeshes;++mesh) {
        uint32_t space=DC_MODEL_SPACE_LOCAL;
        if(dc_model_vertex_space(_actor.model,mesh,&space)!=DC_OK) { if(error)*error=@"Actor skin profile query failed";return nil; }
        if(space==DC_MODEL_SPACE_WORLD)++_actorSkinMeshCount;
    }
    uint32_t anchor=[self findAnchor:&_map];
    dc_game_map_presentation presentation;
    if(dc_game_map_presentation_profile(_mapSelector,&presentation)==DC_OK)
        _anchorName=[NSString stringWithUTF8String:presentation.anchor];
    dc_matrix mapWorld=gameIdentity();
    if(anchor==UINT32_MAX||dc_model_tick(_map.model,0,0,&mapWorld)!=DC_OK||
       dc_model_global(_map.model,anchor,&_actorWorld)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Map %u actor placement anchor is unavailable",_mapSelector];
        return nil;
    }
    _cameraBase=gameIdentity();
    _cameraPreset=0;
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
    if(!camData || dc_camera_read_preset(camData.bytes,camData.length,0,&orbit)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Map %u camera %@ is unavailable",_mapSelector,preferred];
        return nil;
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
    dc_game_model *models[]={&_map,&_actor,&_face,&_autoCamera,&_cameraTarget,&_watchAuxiliary[0],&_watchAuxiliary[1]};
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
    dc_game_model *models[]={&_map,&_actor,&_face,&_autoCamera,&_cameraTarget,&_watchAuxiliary[0],&_watchAuxiliary[1]};
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
- (void)dealloc { [self savePlayerState];free(_surfaces);[self detachSceneUI];[self detachModel:&_map];[self detachModel:&_actor];[self detachModel:&_face];[self detachModel:&_autoCamera];[self detachModel:&_cameraTarget];[self detachModel:&_watchAuxiliary[0]];[self detachModel:&_watchAuxiliary[1]]; }

- (void)detachSceneUI {
    if(_renderer) {
        for(NSNumber *handle in _sceneUITextures.allValues)dc_vk_sprite_remove_texture(_renderer,handle.unsignedLongLongValue);
        for(NSNumber *handle in _rpp15Textures.allValues)dc_vk_sprite_remove_texture(_renderer,handle.unsignedLongLongValue);
        if(_whiteTexture){dc_vk_sprite_remove_texture(_renderer,_whiteTexture);_whiteTexture=0;}
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
    BOOL virginBlood=(!bypass&&_sceneType==6&&_storyStage==0&&_stageProgress==0&&!_editMode&&curClip>=4u);
    BOOL wetNeko=NO;
    if(!bypass) {
        if(_sceneType==4)wetNeko=(_vibeNekoUsed||_watchNekoVibeVisible||curClip==11u||curClip==13u);
        else if(_sceneType==5)wetNeko=(_vibeNekoUsed||_watchNekoVibeVisible||_stageOutcomeA>=1u||_watchClimaxElapsedMs>0u);
        else if(_sceneType==6)wetNeko=(curClip>=4u);
    }
    BOOL wetBou=(!bypass&&_sceneType==6&&curClip>=4u);
    BOOL inPos2=(curClip>=33u&&curClip<=57u);
    uint8_t splatter=(!bypass&&_sceneType==6)?MIN(2u,_externalClimaxLevel):0u;
    uint32_t mask=(_hairVisible?1u:0u)|(virginBlood?2u:0u)|(wetNeko?4u:0u)|(wetBou?8u:0u)|(inPos2?16u:0u)|(bypass?32u:0u)|((uint32_t)splatter<<6)|((_outfitVariant&3u)<<8);
    if(mask==_lastDynamicTexMask)return;
    _lastDynamicTexMask=mask;
    for(uint32_t i=0;i<_actor.textureCount;++i)_actor.textures[i]=_actor.baseTextures[i];
    if(_face.textures&&_face.baseTextures) {
        for(uint32_t i=0;i<_face.textureCount;++i)_face.textures[i]=_face.baseTextures[i];
    }
    if(bypass)return;
    if(_hairVisible) {
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
        if(_outfitVariant==0u) {
            [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_41.bmp",_characterPrefix]
                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_41.bmp",_characterPrefix,clothCh]];
        }
        if(_outfitVariant<2u) {
            [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_42.bmp",_characterPrefix]
                             withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_42.bmp",_characterPrefix,clothCh]];
            if(_characterPrefix!='a') {
                [self replaceActorTextureNamed:[NSString stringWithFormat:@"%ct00_00_46.tga",_characterPrefix]
                                 withRPP15Name:[NSString stringWithFormat:@"%c%c00_00_46.tga",_characterPrefix,clothCh]];
            }
        }
        if(_outfitVariant<3u) {
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
    _sceneUIDraws=0;if(_sceneType<4||_sceneType>6)return nil;
    float scale=viewport.width/1024.f;
    NSArray<NSString *> *icons=@[@"chara",@"fuku",@"cam",@"sys"];
    for(unsigned row=1;row<=4;++row) {
        if(row==2&&!_stageProgress&&!_editMode&&!(_sceneType==6&&_naturalGameplayRoute))continue;
        if(row==1&&_sceneType==5&&!_stageProgress&&!_editMode&&_naturalGameplayRoute)continue;
        float u0,u1;if(dc_scene_icon_uv(_storyStage,row,&u0,&u1)!=DC_OK)return @"Scene icon atlas selection failed";
        dc_sprite_pose p={.width=96*scale,.height=96*scale,.x=viewport.x+920*scale,.y=viewport.y+(328+112*(row-1))*scale,
            .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u0=u0,.u1=u1,.v1=1};
        for(unsigned state=0;state<2;++state) {
            if(state&&_mainIconHover!=(int32_t)row)continue;
            NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icons[row-1],state?@"N":@"S"];
            NSString *error=[self appendSceneUISprite:name pose:p draws:draws count:count storage:storage];if(error)return error;++_sceneUIDraws;
        }
    }
    if((_sceneType==5||_sceneType==6)&&[self sceneUITexture:@"kaikan_base.ema" error:nil]) {
        dc_sprite_pose basePose={.width=24*scale,.height=176*scale,.x=viewport.x+8*scale,.y=viewport.y+296*scale,
            .origin_x=0.f,.origin_y=1.f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
        NSString *error=[self appendSceneUISprite:@"kaikan_base.ema" pose:basePose draws:draws count:count storage:storage];
        if(error)return error;
        ++_sceneUIDraws;
        NSString *barName=_storyStage==2?@"kaikan_a.ema":(_storyStage==0?@"kaikan_b.ema":@"kaikan_c.ema");
        if([self sceneUITexture:barName error:nil]) {
            float gauge=(_sceneType==5)?_watchTouchGauge:_nightExcitement;
            float barScaleY=(fminf(100.f,fmaxf(0.f,gauge))+1.f)*0.01f;
            dc_sprite_pose barPose={.width=24*scale,.height=168*scale,.x=viewport.x+8*scale,.y=viewport.y+288*scale,
                .origin_x=0.f,.origin_y=1.f,.scale_x=1,.scale_y=barScaleY,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
            error=[self appendSceneUISprite:barName pose:barPose draws:draws count:count storage:storage];
            if(error)return error;
            ++_sceneUIDraws;
        }
    }
    BOOL captureActive=(_captureGameplayFrame&&!_capturedGameplayFrame)||_requestedRenderCapture!=nil;
    if(!_contextOpen&&!captureActive&&_hoverTargetHit>=0&&_cursorIndex>=0&&[self sceneUITexture:@"D_cir.ema" error:nil]) {
        dc_sprite_pose cirPose={.width=64*scale,.height=64*scale,.x=viewport.x+_cursorX*scale,.y=viewport.y+_cursorY*scale,
            .origin_x=.5f,.origin_y=.5f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
        NSString *error=[self appendSceneUISprite:@"D_cir.ema" pose:cirPose draws:draws count:count storage:storage];
        if(error)return error;
        ++_sceneUIDraws;
    }
    _sceneUIIconDraws=_sceneUIDraws;
    if(_contextOpen)for(unsigned i=0;i<_contextMenu.count;++i) {
        dc_scene_context_item item=_contextMenu.items[i];if(item.resource_id<0)continue;
        dc_sprite_pose p={.width=240*scale,.height=32*scale,.x=viewport.x+item.x*scale,.y=viewport.y+item.y*scale,.origin_x=.9f,.origin_y=.5f,
            .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
        for(unsigned state=0;state<2;++state) {
            if(state&&_contextMenu.hover!=(int32_t)i)continue;
            NSString *spriteName=nil;
            if(_contextMenu.icon==4&&_editMode&&i>0) {
                spriteName=[NSString stringWithFormat:@"M_z%03d%c.ema",item.resource_id,state?'N':'S'];
            } else {
                uint32_t resourceSceneType=(_contextMenu.icon>=2&&_sceneType>=4&&_sceneType<=6)?4:_sceneType;
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
    if(slot==&_face&&_faceBlushActive&&material.texture_names[1].length>1) {
        texSlot=1;
    } else if(slot==&_actor&&_materialCycleSlot>0&&material.texture_names[2].length>1&&material.texture_names[3].length>1) {
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
    if(_voiceMouthPhase>0.01f) {
        controls.mouth_phase=fminf(controls.mouth_max,_voiceMouthPhase);
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
- (NSString *)append:(dc_game_model *)slot camera:(const dc_camera_matrices *)camera
    viewport:(const dc_viewport *)viewport draws:(dc_vk_geometry_item *)draws count:(size_t *)count storage:(NSMutableArray *)storage triangles:(uint32_t *)triangles {
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
        if(slot==&_actor&&renderState.transparent_queue&&(_sceneType==5||_sceneType==6)) {
            dc_xx_material xxMat;
            if(dc_xx_material_at(slot->xx,mesh.material,&xxMat)==DC_OK) {
                NSString *matName=[self decodedName:(const uint8_t *)slot->xxData.bytes+xxMat.name.offset length:xxMat.name.length];
                if([matName hasSuffix:@"_Mn_mata_siru"]) {
                    float gauge=(_sceneType==5)?_watchTouchGauge:_nightExcitement;
                    BOOL postClimax=(_sceneType==5)?(_watchClimaxElapsedMs>0u||(_lastClothingClip>=160u&&_lastClothingClip<=193u)):
                        ((_lastClothingClip>=24u&&_lastClothingClip<=32u)||(_lastClothingClip>=55u&&_lastClothingClip<=58u));
                    float alpha=postClimax?1.0f:fminf(1.0f,(fmaxf(0.0f,gauge)+1.0f)*0.01f);
                    material.components[3]*=alpha;
                }
            }
        }
        if(renderState.hidden||material.components[3]<=0)continue;
        uint8_t depth=renderState.transparent_queue?DC_VK_DEPTH_AUTO_TRANSLUCENT:DC_VK_DEPTH_AUTO;
        uint8_t cull=renderState.two_sided?DC_VK_CULL_NONE:DC_VK_FRONT_NEGATIVE_AREA;
        uint32_t texture=[self textureFor:slot mesh:&mesh];if(slot->info.textures>0&&texture==UINT32_MAX){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game material texture not found";}
        uintptr_t textureHandle=(slot->info.textures>0&&texture<slot->info.textures)?slot->textures[texture]:[self whiteTexture];
        if(!textureHandle){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game material texture handle unavailable";}
        size_t vertexCount=0;
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
- (NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput
    width:(uint32_t)width height:(uint32_t)height {
    if(!_loaded)return @"Game scene is not loaded";
    if(!_renderer)return @"Game scene renderer is detached";
    if(_needsResumeAtNextTick){_needsResumeAtNextTick=NO;if(_tickInitialized)[self resumeAtTick:tick];}
    BOOL gameplayScene=(_sceneType==4);
    BOOL cameraScene=(_sceneType>=4&&_sceneType<=6);
    BOOL pcHome=(pcInput.keys[0xc7]&1)!=0,pcEnd=(pcInput.keys[0xcf]&1)!=0;
    BOOL pcPageUp=(pcInput.keys[0xc9]&1)!=0,pcPageDown=(pcInput.keys[0xd1]&1)!=0;
    BOOL pcNum8=(pcInput.keys[0x48]&1)!=0,pcNum4=(pcInput.keys[0x4b]&1)!=0;
    BOOL pcNum2=(pcInput.keys[0x50]&1)!=0,pcNum6=(pcInput.keys[0x4d]&1)!=0;
    BOOL pcArrowUp=(pcInput.keys[0xc8]&1)!=0,pcArrowLeft=(pcInput.keys[0xcb]&1)!=0;
    BOOL pcArrowDown=(pcInput.keys[0xd0]&1)!=0,pcArrowRight=(pcInput.keys[0xcd]&1)!=0;
    if(pcInput.keys[0x2e]==3)[self requestRenderCapture:@"gameplay-capture.png"];
    if(cameraScene&&pcInput.keys[1]==3&&!_pendingSystemAction&&!_characterAction.exit_pending&&!_characterAction.transition_pending&&
       (!_motionStateInitialized||!_motionState.transition_pending)){
        _contextOpen=NO;_watchDragging=NO;_nightDragging=NO;
        _pendingSystemAction=5;
        if(!self.transitionScene||[self.transitionScene requestTransition:3 tick:tick]!=DC_OK)
            return @"Original dummy-screen transition failed";
    }
    if(cameraScene&&(pcInput.keys[0x3b]==3||(pcInput.keys[0x3c]==3&&!_editMode))&&!_pendingSystemAction&&
       !_characterAction.exit_pending&&!_characterAction.transition_pending&&(!_motionStateInitialized||!_motionState.transition_pending)){
        _contextOpen=NO;_watchDragging=NO;_nightDragging=NO;
        _pendingSystemAction=pcInput.keys[0x3b]==3?3:4;
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
    BOOL touchExercise=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"];
    if(cameraScene) {
        for(unsigned i=0;i<3;++i) {
            if(pcInput.keys[2+i]==3) {
                _mapLayerVisible[i]=!_mapLayerVisible[i];
                NSString *mapError=[self applyMapLayerVisibility];
                if(mapError)return mapError;
            }
        }
        if(_sceneType==5&&pcInput.keys[5]==3) {
            _watchAuxUserHidden=!_watchAuxUserHidden;
        }
        if(pcInput.keys[0x2f]==3) {
            _secondaryVisible=!_secondaryVisible;++_secondaryVisibilityChanges;
#if DEBUG
            if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
                [self requestRenderCapture:_secondaryVisible?@"gameplay-secondary-visible-native.png":@"gameplay-secondary-hidden-native.png"];
#endif
        }
        if(_editMode&&!touchExercise&&!_pendingSystemAction&&!_characterAction.exit_pending&&!_characterAction.transition_pending) {
            if(pcInput.keys[0x35]==3)[self toggleEditPauseOrResetSpeed];
            if(pcInput.keys[0x2b]==3)[self cycleEditSpeedMode];
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
        int32_t actorHit=((_sceneType==5||_sceneType==6)&&!_contextOpen&&!iconRegion&&!(_secondaryVisible&&inside)&&!pcCtrl&&!_characterAction.exit_pending&&!_characterAction.transition_pending)?[self motionHitIndexAtX:x y:y width:width height:height]:-1;
        dc_animation_state scene6Anim={0};
        if(_sceneType==6&&_actor.model) {
            dc_model_get_animation(_actor.model,&scene6Anim);
            if(scene6Anim.current!=26)_nightQuestionAsked=NO;
            if(_contextOpen&&(_contextMenu.icon==1||_contextMenu.icon==2)&&
               ((scene6Anim.current>=27&&scene6Anim.current<=32)||
                (scene6Anim.current>=56&&scene6Anim.current<=57)||
                scene6Anim.current==54))
                _contextOpen=NO;
        }
        BOOL scene6InPos=(scene6Anim.current>=10&&scene6Anim.current<=23)||(scene6Anim.current>=39&&scene6Anim.current<=53);
        BOOL scene6Interactive=(scene6InPos||_nightDragging||((scene6Anim.current==1||scene6Anim.current==26)&&actorHit>=0));
        if(!held&&!pcInput.wheel)_pointerCameraOwner=0;
        if(!_pointerCameraOwner&&!_contextOpen&&(press||pcInput.wheel)) {
            /* Scene 4 left-drag in the main viewport rotates the primary camera
             * (00513690). Scene 5/6 left presses on an active character target
             * belong to the actor-motion callback unless Ctrl is held (00492854). */
            if(_secondaryVisible&&inside)
                _pointerCameraOwner=2;
            else if(iconRegion&&(pcInput.mouse[0]||pcInput.mouse[1]))
                _pointerCameraOwner=1;
            else if(_sceneType==5&&!pcCtrl&&!pcInput.wheel&&
                    ((pcInput.mouse[0]&&!pcInput.mouse[1]&&(actorHit>=0||_watchPart>=0||_watchDragging))||
                     (pcInput.mouse[1]==3&&!pcInput.mouse[0]&&_watchPart>=0)))
                _pointerCameraOwner=0;
            else if(_sceneType==6&&!pcCtrl&&!pcInput.mouse[1]&&
                    ((!pcInput.wheel&&pcInput.mouse[0]&&scene6Interactive)||(pcInput.wheel&&scene6InPos)))
                _pointerCameraOwner=0;
            else
                _pointerCameraOwner=3;
        }
        if(_pointerCameraOwner==2&&!_contextOpen&&(held||pcInput.wheel)) {
            secondaryOwnsPointer=YES;
            if(_secondaryCameraMode!=2) {
                dc_camera_pointer_input motion={pcInput.dx,pcInput.dy,pcInput.wheel,
                    pcInput.mouse[0],pcInput.mouse[1],pcInput.mouse[2],(pcInput.keys[0x3b]&1)!=0};
                dc_camera_orbit next;
                if(dc_camera_secondary_pointer(&_secondaryCamera,&_secondaryLimits,&motion,&next)!=DC_OK)return @"Original secondary camera pointer update failed";
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
            if(dc_camera_secondary_pointer(&current,&_secondaryLimits,&motion,&next)!=DC_OK)
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
        static const uint32_t kWatchState1EntryClips[7]={50,56,62,68,74,80,86};
        static const uint32_t kWatchRetractClips[7]={51,57,63,69,75,81,87};
        static const uint32_t kWatchDragEntryClips[7]={100,108,116,124,132,140,148};
        static const uint32_t kWatchDragLoopClips[7]={101,109,117,125,133,141,149};
        static const uint32_t kWatchReleaseClips[7]={103,111,119,127,135,143,147};
        static const uint32_t kWatchClimaxClips[7]={160,165,170,175,180,185,189};
        static const uint32_t kWatchClimaxEndClips[7]={164,169,174,179,184,188,192};
        dc_animation_state anim={0};
        if(dc_model_get_animation(_actor.model,&anim)==DC_OK)
            _motionState.clip=anim.current;
        BOOL inState1Idle=(anim.current==1||anim.current==9||anim.current==15||anim.current==21||anim.current==27||anim.current==33||anim.current==39);
        if(_watchPart<0&&inState1Idle) {
            if(_naturalGameplayRoute&&!touchExercise)
                _actorPlaybackSpeed=_watchVibeSwitch?1.65f:((_watchNekoVibeVisible||_watchToriVibeVisible)?1.25f:1.0f);
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
            if(_watchPendingExitAfterClimax) {
                _watchPendingExitAfterClimax=NO;
                _pendingEffectSlot=28u;_hasPendingEffect=YES;
                _characterAction.exit_pending=1;_exitSoundStartTick=tick;
            }
        }
        float inputScale=fminf((float)width/1024.f,(float)height/768.f);
        float mx=((x+1)*.5f*width-(width-1024*inputScale)*.5f)/inputScale;
        float my=((1-y)*.5f*height-(height-768*inputScale)*.5f)/inputScale;
        BOOL inside=mx>=0&&mx<=352&&my>=504&&my<=768;
        BOOL iconRegion=mx>=880&&my>=300&&my<=768;
        int32_t hit=(_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1]&&!iconRegion&&!(_secondaryVisible&&inside))?[self motionHitIndexAtX:x y:y width:width height:height]:-1;
        if(pcInput.mouse[1]==3&&!pcInput.mouse[0]&&_watchPart>=0&&_watchPart<7&&!iconRegion&&!(_secondaryVisible&&inside)) {
            uint32_t retractClip=kWatchRetractClips[_watchPart];
            dc_model_set_chain(_actor.model,retractClip,(int32_t)kWatchState1IdleClips[_watchPart]);
            _motionState.clip=retractClip;_motionState.phase=1;
            _watchPart=-1;_watchDragging=NO;_watchUndressStep=0.f;
            _actorPlaybackSpeed=(_naturalGameplayRoute&&!touchExercise)?(_watchVibeSwitch?1.65f:((_watchNekoVibeVisible||_watchToriVibeVisible)?1.25f:1.0f)):1.0f;
            for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
                dc_model_hide_node(_watchAuxiliary[auxiliary].model,0,1);
            if(dc_model_request(_actor.model,retractClip,tick)!=DC_OK)return @"Original watch retract animation request failed";
            ++_characterAnimationStarts;++_characterActionCount;
            _pendingEffectSlot=2u;_hasPendingEffect=YES;
        } else if(pcInput.mouse[0]==3&&_pointerCameraOwner==0&&hit>=0&&hit<7&&(_watchPart<0||(!_watchDragging&&hit!=_watchPart))) {
            uint32_t entryClip=(_motionState.clip==1||_motionState.clip>=230)?((uint32_t)hit+2u):kWatchState1EntryClips[hit];
            _watchPart=hit;_motionState.phase=2;_watchDragging=NO;_watchUndressStep=0.f;
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
             * progressive clothing displacement stage (0049a440 -> 0049ae60). */
            BOOL advanced=NO;
            if((hit==1||hit==2)&&_watchTopStage<2){++_watchTopStage;advanced=YES;}
            else if(hit==3){if(_watchSkirtStage<1){_watchSkirtStage=1;advanced=YES;}else if(_watchPantyStage<1){_watchPantyStage=1;advanced=YES;}}
            else if(hit==4){if(_watchSkirtStage<2){_watchSkirtStage=2;advanced=YES;}else if(_watchPantyStage<1){_watchPantyStage=1;advanced=YES;}}
            else if(hit==5||hit==6){if(_watchSkirtStage<1){_watchSkirtStage=1;advanced=YES;}else if(_watchPantyStage<1){_watchPantyStage=1;advanced=YES;}}
            ++_characterActionCount;
            _pendingEffectSlot=advanced?2u:3u;_hasPendingEffect=YES;
            [self queueCyclicReactionVoiceForScene:5 climax:NO];
        } else {
            float dragAmount=(_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1]&&!iconRegion&&!(_secondaryVisible&&inside))?hypotf((float)pcInput.dx,(float)pcInput.dy):0.f;
            BOOL watchCanDrag=_watchPart>=0&&_watchPart<7&&_pointerCameraOwner==0&&((pcInput.mouse[0]&1)!=0);
            if(watchCanDrag&&dragAmount>0.f) {
                _actorPlaybackSpeed=fminf(2.4f,1.0f+dragAmount*0.045f);
                _watchTouchGauge=fminf(100.f,_watchTouchGauge+dragAmount*0.35f);
                _watchFeedbackStep+=dragAmount;
                _watchUndressStep+=dragAmount;
                if(_watchUndressStep>=85.f) {
                    _watchUndressStep=0.f;
                    if((_watchPart==1||_watchPart==2)&&_watchTopStage<2)++_watchTopStage;
                    else if(_watchPart==3){if(_watchSkirtStage<1)_watchSkirtStage=1;else if(_watchPantyStage<1)_watchPantyStage=1;}
                    else if(_watchPart==4){if(_watchSkirtStage<2)_watchSkirtStage=2;else if(_watchPantyStage<1)_watchPantyStage=1;}
                    else if(_watchPart==5||_watchPart==6){if(_watchSkirtStage<1)_watchSkirtStage=1;else if(_watchPantyStage<1)_watchPantyStage=1;}
                }
                _motionState.metric=fminf(10000.f,_motionState.metric+dragAmount);
                _motionState.average_motion=.8f*_motionState.average_motion+.2f*dragAmount;
                if(_motionState.sample_count<UINT32_MAX)++_motionState.sample_count;
                if(!_watchDragging||(_motionState.clip!=kWatchDragEntryClips[_watchPart]&&_motionState.clip!=kWatchDragLoopClips[_watchPart])) {
                    _watchDragging=YES;
                    uint32_t dragClip=kWatchDragEntryClips[_watchPart];
                    _motionState.clip=dragClip;
                    if(dc_model_request(_actor.model,dragClip,tick)!=DC_OK)return @"Original watch drag animation request failed";
                    ++_characterAnimationStarts;
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
                    _watchDragging=NO;_watchUndressStep=0.f;_actorPlaybackSpeed=1.0f;
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
                _watchDragging=NO;_actorPlaybackSpeed=1.0f;
                if(_watchPart>=0&&_watchPart<7) {
                    uint32_t relClip=kWatchReleaseClips[_watchPart];
                    _motionState.clip=relClip;
                    dc_model_request(_actor.model,relClip,tick);
                }
            } else if(_watchDragging&&dragAmount==0.f) {
                _actorPlaybackSpeed=0.5f;
            }
        }
    } else if(_sceneType==6&&_motionStateInitialized&&!_contextOpen&&
              !_characterAction.exit_pending&&!_characterAction.transition_pending) {
        dc_animation_state animation={0};
        if(dc_model_get_animation(_actor.model,&animation)==DC_OK&&animation.current<=0xffu)
            _motionState.clip=animation.current;
        uint32_t clip=_motionState.clip;
        int32_t hit=(_pointerCameraOwner==0&&!pcCtrl&&!pcInput.mouse[1])?[self motionHitIndexAtX:x y:y width:width height:height]:-1;
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
            _nightExcitement=0.f;_nightDragging=NO;_actorPlaybackSpeed=1.0f;
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
            float dragAmount=(!pcCtrl&&!pcInput.mouse[1])?hypotf((float)pcInput.dx,(float)pcInput.dy):0.f;
            float wheelImpulse=(!pcCtrl&&!pcInput.mouse[1]&&pcInput.wheel!=0)?fabsf((float)pcInput.wheel)*12.f:0.f;
            float thrustAmount=(((pcInput.mouse[0]&1)!=0)?dragAmount:0.f)+wheelImpulse;
            if(thrustAmount>0.f) {
                if((pcInput.mouse[0]&1)!=0)_nightDragging=YES;
                _actorPlaybackSpeed=fminf(2.4f,1.0f+thrustAmount*0.045f);
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
                    _nightExcitement=0.f;_nightDragging=NO;_actorPlaybackSpeed=1.0f;
                    if(inPos2&&_naturalGameplayRoute&&!touchExercise) {
                        if(_motionState.outcome_a<10000)++_motionState.outcome_a;
                        _stageOutcomeA=_motionState.outcome_a;
                        _motionState.clip=53u;_motionState.phase=1;
                        dc_model_set_chain(_actor.model,53u,10u);
                        if(dc_model_request(_actor.model,53u,tick)!=DC_OK)return @"Original night position return animation request failed";
                        ++_characterAnimationStarts;
                        _pendingEffectSlot=2u;_hasPendingEffect=YES;
                        [self queueCyclicReactionVoiceForScene:6 climax:NO];
                    } else {
                        if(inPos2&&_motionState.outcome_b==0){_motionState.outcome_b=1;_stageOutcomeB=1;}
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
                }
            } else if(_nightDragging&&!(pcInput.mouse[0]&1)) {
                _nightDragging=NO;_actorPlaybackSpeed=1.0f;
                uint32_t stopClip=inPos2?((_naturalGameplayRoute&&clip>=48u)?51u:44u):((_naturalGameplayRoute&&clip>=19u)?22u:15u);
                _motionState.clip=stopClip;
                dc_model_request(_actor.model,stopClip,tick);
            } else if(_nightDragging&&dragAmount==0.f) {
                _actorPlaybackSpeed=0.5f;
            }
        }
    }
    if(cameraScene) {
        BOOL held=(pcInput.mouse[0]&1)||(pcInput.mouse[1]&1)||(pcInput.mouse[2]&1);
        if(!_contextOpen&&((_sceneType==5&&_watchPart>=0&&_watchDragging&&(pcInput.mouse[0]&1))||
                           (_sceneType==6&&_nightDragging&&(pcInput.mouse[0]&1)))) {
            _cursorIndex=-1;
        } else if(!_contextOpen&&(_pointerCameraOwner==2||_pointerCameraOwner==3)&&held) {
            if(((pcInput.mouse[0]&1)&&(pcInput.mouse[1]&1))||(pcInput.mouse[2]&1)||((pcInput.keys[0x3b]&1)!=0))
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
                    (_watchPart>=0||_watchDragging||
                     (curMenuAnim.current!=1&&curMenuAnim.current!=9&&curMenuAnim.current!=15&&
                      curMenuAnim.current!=21&&curMenuAnim.current!=27&&curMenuAnim.current!=33&&
                      curMenuAnim.current!=39&&curMenuAnim.current!=245)))
                charaDisabled=YES;
            else if(_sceneType==6&&!touchExercise&&_naturalGameplayRoute&&
                    (_nightDragging||
                     (curMenuAnim.current!=1&&
                      curMenuAnim.current!=26&&
                      curMenuAnim.current!=39&&
                      curMenuAnim.current!=55)))
                charaDisabled=YES;
            buttons[1].disabled=charaDisabled?1:0;
            BOOL clothDisabled=!(_stageProgress||_editMode||(_sceneType==6&&_naturalGameplayRoute));
            if(!clothDisabled&&!touchExercise) {
                if(_sceneType==6&&curMenuAnim.current==31)
                    clothDisabled=YES;
                else if(_naturalGameplayRoute) {
                    if(_sceneType==4&&(_characterAction.delay_pending||(curMenuAnim.current!=1&&curMenuAnim.current!=11&&curMenuAnim.current!=13)))
                        clothDisabled=YES;
                    else if(_sceneType==5&&(_watchPart>=0||_watchDragging||
                            (curMenuAnim.current!=1&&curMenuAnim.current!=9&&curMenuAnim.current!=15&&
                             curMenuAnim.current!=21&&curMenuAnim.current!=27&&curMenuAnim.current!=33&&
                             curMenuAnim.current!=39)))
                        clothDisabled=YES;
                    else if(_sceneType==6&&_nightDragging)
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
                uint32_t contextSceneType=(_mainIconHover>=3&&_sceneType>=4&&_sceneType<=6)?4:_sceneType;
                dc_scene_context_input input={.scene_type=contextSceneType,.icon=(uint32_t)_mainIconHover,.stage_progress=_mainIconHover==1?0:(_editMode?2u:MIN(_stageProgress,2u)),
                    .animation=animation.current,.camera_mode=_primaryCameraMode,.secondary_camera_mode=_secondaryCameraMode,.x=px,.y=py};
                dc_status status=dc_scene_context_build(&input,&_contextMenu);
                if(status!=DC_OK&&status!=DC_NOT_FOUND)return @"Scene context profile failed";
                float unit=105.f*.3333333432674408f;
                const float dx[7]={0,unit,unit+unit,105,unit+unit,unit,0};
                const float dy[7]={-105,-(unit+unit),-unit,0,unit,unit+unit,105};
                if(_mainIconHover==1&&_sceneType==4&&!touchExercise&&
                   ((_stageProgress>0||_editMode)||(status==DC_OK&&_contextMenu.count==0))) {
                    BOOL freeMode=(_stageProgress>0||_editMode);
                    _contextMenu=(dc_scene_context){.icon=1,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1,.count=freeMode?6u:2u};
                    for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                    if(freeMode) {
                        BOOL bottomExposed=(_outfitVariant>=2);
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
                        BOOL vibeAllowed=(!_naturalGameplayRoute||_outfitVariant>=2||_watchSkirtStage>=1);
                        BOOL insertAllowed=vibeAllowed&&(!_naturalGameplayRoute||animation.current!=33);
                        BOOL anyVibe=(_watchNekoVibeVisible||_watchToriVibeVisible);
                        _contextMenu.count=5u;
                        const int32_t ids[5]={
                            (insertAllowed&&(!_naturalGameplayRoute||!_watchNekoVibeVisible))?1:-1,
                            (insertAllowed&&(!_naturalGameplayRoute||!_watchToriVibeVisible))?2:-1,
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
                } else if(_mainIconHover==2&&(_stageProgress||_editMode||(_sceneType==6&&_naturalGameplayRoute))&&!touchExercise) {
                    static const int32_t kAccessoryResourceIds[6]={18,21,20,17,19,16};
                    int32_t accId=kAccessoryResourceIds[(_storyStage%3u)*2u+(_accessoryHidden?1u:0u)];
                    if(_sceneType==5&&_stageProgress==1&&!_editMode) {
                        /* 005342b0 lines 329-339: Scene 5 at progress=1 only
                         * exposes the 1-item accessory toggle at slot 6. */
                        _contextMenu=(dc_scene_context){.icon=2,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1,.count=1u};
                        for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                        _contextMenu.items[0]=(dc_scene_context_item){accId,6,px-dx[6],py+dy[6]};
                        status=DC_OK;
                    } else if(_sceneType==6&&!_stageProgress&&!_editMode) {
                        /* 005342b0 case 6 (line 545): Story-mode Scene 6 exposes
                         * the 4 clothing items without the accessory item. */
                        _contextMenu=(dc_scene_context){.icon=2,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1,.count=4u};
                        for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                        for(unsigned i=0;i<4;++i)_contextMenu.items[i]=(dc_scene_context_item){(int32_t)(i+1),i,px-dx[i],py+dy[i]};
                        status=DC_OK;
                    } else if(_sceneType==5||_sceneType==6||status!=DC_OK||!_contextMenu.count) {
                        _contextMenu=(dc_scene_context){.icon=2,.opening_right=(pcInput.mouse[1]==3)?1u:0u,.hover=-1,.count=5u};
                        for(unsigned i=0;i<7;++i)_contextMenu.items[i].resource_id=-1;
                        for(unsigned i=0;i<4;++i)_contextMenu.items[i]=(dc_scene_context_item){(int32_t)(i+1),i,px-dx[i],py+dy[i]};
                        _contextMenu.items[4]=(dc_scene_context_item){accId,6,px-dx[6],py+dy[6]};
                        status=DC_OK;
                    }
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
    float cameraX=controller.rx/32767.f,cameraY=controller.ry/32767.f;
    if(pcNum4)cameraX-=1.f;if(pcNum6)cameraX+=1.f;
    if(pcNum8)cameraY-=1.f;if(pcNum2)cameraY+=1.f;
    float heightDelta=(pcPageUp?1.f:0.f)-(pcPageDown?1.f:0.f);
    if(padDelta>0 && (cameraX!=0 || cameraY!=0 || heightDelta!=0))_controllerCameraAdvanced=YES;
    if(controller.buttons&DC_PAD_L)cameraX-=1;
    if(controller.buttons&DC_PAD_R)cameraX+=1;
    _padCameraYaw=remainderf(_padCameraYaw+cameraX*padDelta*1.5f,6.2831853f);
    _padCameraPitch=fmaxf(-.7f,fminf(.7f,_padCameraPitch+cameraY*padDelta));
    _padCameraHeight=fmaxf(_secondaryLimits.low-_cameraHeight,fminf(_secondaryLimits.high-_cameraHeight,_padCameraHeight+heightDelta*padDelta*5.0f));
    float zoom=((controller.buttons&DC_PAD_ZR)?1.f:0.f)-((controller.buttons&DC_PAD_ZL)?1.f:0.f);
    if(pcHome)zoom+=1.f;if(pcEnd)zoom-=1.f;
    if(!secondaryOwnsPointer){if(pcInput.wheel>0)zoom+=1.f;else if(pcInput.wheel<0)zoom-=1.f;}
    _padCameraZoom=fmaxf(-.7f,fminf(1.f,_padCameraZoom+zoom*padDelta));
    float panX=(pcArrowRight?1.f:0.f)-(pcArrowLeft?1.f:0.f);
    float panZ=(pcArrowDown?1.f:0.f)-(pcArrowUp?1.f:0.f);
    float yaw=_cameraYaw+_padCameraYaw,cy=cosf(yaw),sy=sinf(yaw);
    _padCameraPanX=fmaxf(-50.f,fminf(50.f,_padCameraPanX+(panX*cy+panZ*sy)*padDelta*2.0f));
    _padCameraPanZ=fmaxf(-50.f,fminf(50.f,_padCameraPanZ+(-panX*sy+panZ*cy)*padDelta*2.0f));
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
    if(_sceneType==5||_sceneType==6) {
        [self syncDynamicClothingForPart:_watchPart clip:curAnim.current];
        float gauge=(_sceneType==5)?_watchTouchGauge:_nightExcitement;
        if(gauge>0.f&&_actor.model) {
            uint32_t mataNode=[self findNode:&_actor name:[self characterNode:@"a_On_mata_siru"]];
            if(mataNode!=UINT32_MAX)dc_model_hide_node(_actor.model,mataNode,0);
        }
    }
    BOOL captureActive=(_captureGameplayFrame&&!_capturedGameplayFrame)||_requestedRenderCapture!=nil;
    BOOL bypassDynamicTex=captureActive||!_naturalGameplayRoute||touchExercise;
    [self syncDynamicActorTexturesForClip:curAnim.current bypass:bypassDynamicTex];
    if(bypassDynamicTex) {
        _materialCycleSlot=0;_faceBlushActive=NO;
    } else {
        BOOL shouldCycle=NO;
        if(_sceneType==4)shouldCycle=_watchVibeSwitch;
        else if(_sceneType==5)shouldCycle=YES;
        else if(_sceneType==6)shouldCycle=(curAnim.current!=1u&&curAnim.current!=2u);
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
            _faceBlushActive=(curAnim.current==57u&&_stageOutcomeB!=0u)||
                             (curAnim.current>=24u&&curAnim.current<=32u)||
                             (curAnim.current>=56u&&curAnim.current<=58u)||
                             _voiceBlushActive;
        } else {
            _faceBlushActive=NO;
        }
    }
    static const float kEditSpeedScales[4]={1.f,2.f,4.f,8.f};
    float editScale=_editMode?(_editPaused?0.f:kEditSpeedScales[_editSpeedMode&3u]):1.f;
    uint32_t mapDelta=(uint32_t)lrintf((float)delta*editScale);
    uint32_t actorDelta=(uint32_t)lrintf((float)delta*editScale*fmaxf(0.25f,fminf(2.5f,_actorPlaybackSpeed>0.f?_actorPlaybackSpeed:1.0f)));
    if(dc_model_tick(_map.model,mapDelta,tick,&_map.world)!=DC_OK||
       dc_model_tick(_actor.model,actorDelta,tick,&_actor.world)!=DC_OK)return @"Game model tick failed";
    if(_face.model) {
        if(![self updateFaceAttachment])return @"Game face anchor lookup failed";
        if(!(_editMode&&_editPaused))[self updateFaceEyeBlinkAtTick:tick];
        if(dc_model_tick(_face.model,0,tick,&_face.world)!=DC_OK)return @"Game face tick failed";
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
    size_t auxiliaryMeshes=_watchAuxiliary[0].model?_watchAuxiliary[0].info.submeshes:0;
    auxiliaryMeshes+=_watchAuxiliary[1].model?_watchAuxiliary[1].info.submeshes:0;
    size_t targetMeshes=_cameraTarget.model?_cameraTarget.info.submeshes:0;
    size_t geometryCapacity=(_map.info.submeshes+_actor.info.submeshes+_face.info.submeshes+auxiliaryMeshes+targetMeshes)*(_secondaryVisible?2:1);
    size_t capacity=geometryCapacity+32+self.transitionScene.transitionMeshCapacity;
    dc_vk_geometry_item *draws=calloc(capacity,sizeof(*draws));if(!draws)return @"Game draw allocation failed";
    __attribute__((objc_precise_lifetime)) NSMutableArray *storage=[NSMutableArray array];size_t count=0;_visibleMapTriangles=_visibleActorTriangles=0;
    NSString *failure=[self append:&_map camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleMapTriangles];
    size_t mapDrawCount=count;
    if(!failure)failure=[self append:&_actor camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure && delta && _actorSkinMeshCount)_actorSkinAdvanced=YES;
    if(!failure && _face.model)failure=[self append:&_face camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(!failure&&!_watchAuxUserHidden&&_watchAuxiliary[auxiliary].model)
        failure=[self append:&_watchAuxiliary[auxiliary] camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure&&cameraScene&&_cameraTargetVisible&&!bypassDynamicTex&&_primaryCameraTargetActive&&_primaryCameraMode!=2&&_cameraTarget.model) {
        _cameraTarget.world=gameIdentity();
        _cameraTarget.world.values[12]=orbit.base.values[12];
        _cameraTarget.world.values[13]=orbit.base.values[13]+orbit.height;
        _cameraTarget.world.values[14]=orbit.base.values[14];
        if(dc_model_tick(_cameraTarget.model,0,tick,&_cameraTarget.world)==DC_OK) {
            uint32_t targetTriangles=0;
            failure=[self append:&_cameraTarget camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&targetTriangles];
        }
    }
    size_t primarySceneCount=count,secondaryStart=count,secondaryMapCount=0,secondarySceneCount=0;
    if(!failure&&_secondaryVisible) {
        uint32_t secondaryMapTriangles=0,secondaryActorTriangles=0;
        failure=[self append:&_map camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryMapTriangles];
        secondaryMapCount=count-secondaryStart;
        if(!failure)failure=[self append:&_actor camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryActorTriangles];
        if(!failure&&_face.model)failure=[self append:&_face camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryActorTriangles];
        for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(!failure&&!_watchAuxUserHidden&&_watchAuxiliary[auxiliary].model)
            failure=[self append:&_watchAuxiliary[auxiliary] camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryActorTriangles];
        if(!failure&&cameraScene&&_cameraTargetVisible&&!bypassDynamicTex&&_secondaryCameraTargetActive&&_secondaryCameraMode!=2&&_cameraTarget.model) {
            _cameraTarget.world=gameIdentity();
            _cameraTarget.world.values[12]=secondaryOrbit.base.values[12];
            _cameraTarget.world.values[13]=secondaryOrbit.base.values[13]+secondaryOrbit.height;
            _cameraTarget.world.values[14]=secondaryOrbit.base.values[14];
            if(dc_model_tick(_cameraTarget.model,0,tick,&_cameraTarget.world)==DC_OK) {
                uint32_t targetTriangles=0;
                failure=[self append:&_cameraTarget camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&targetTriangles];
            }
        }
        secondarySceneCount=count-secondaryStart;
    }
    size_t sceneDrawCount=count;
    if(!failure)failure=[self appendSceneUI:draws count:&count storage:storage viewport:viewport];
    if(!failure&&(_characterAction.transition_pending||(_motionStateInitialized&&_motionState.transition_pending)||_pendingSystemAction!=0)) {
        failure=[self.transitionScene appendTransitionAtTick:tick viewport:viewport draws:draws capacity:capacity count:&count storage:storage];
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
