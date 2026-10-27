#import "DCGameScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <ImageIO/ImageIO.h>
#include "dc_camera.h"
#include "dc_eyeneck.h"
#include "dc_gameplay.h"
#include "dc_scene_ui.h"
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
    dc_game_model _map,_actor,_autoCamera;
    dc_game_model _face,_watchAuxiliary[2];
    dc_matrix _cameraBase,_actorWorld;
    float _cameraOriginX,_cameraOriginZ,_actorOriginX,_actorOriginY,_actorOriginZ;
    float _cameraDistance,_cameraHeight,_cameraPitch,_cameraYaw;
    float _padCameraYaw,_padCameraPitch,_padCameraZoom;
    float _padCameraPanX,_padCameraPanZ;
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
    float _actorRootFloorOffset;
    BOOL _captureGameplayFrame,_capturedGameplayFrame;
    BOOL _framePresented,_resumedPlayer;
    NSString *_anchorName,*_cameraSource,*_requestedRenderCapture;
    NSDictionary *_lastRenderCapture;
    uint32_t _lastTick; BOOL _tickInitialized;
    float _lastInputX,_lastInputY; BOOL _inputInitialized;
    dc_menu_state _gameMenu; BOOL _gameMenuInitialized,_previousGameMenuTouch;
    float _walkMinX,_walkMaxX,_walkMinZ,_walkMaxZ;
    dc_game_player _player;
    BOOL _playerSaveDirty,_manualSaveCompleted;
    dc_game_interaction_state _interactionState;
    DCArchive *_sceneUIArchive;
    NSMutableDictionary<NSString *,NSNumber *> *_sceneUITextures;
    dc_scene_context _contextMenu;
    BOOL _contextOpen;
    dc_scene_character_state _characterAction;
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
    uint32_t _pendingSystemAction;
    uint8_t _backgroundColor[4];
    BOOL _editMode;
    BOOL _gameFinished;
    NSString *_pendingVoiceName;
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
- (uint32_t)storyStage { return _storyStage; }
- (uint32_t)sceneKind { return _sceneKind; }
- (uint32_t)sceneType { return _sceneType; }
- (BOOL)interactiveScene { return _sceneType==4; }
- (BOOL)secondaryViewVisible { return _secondaryVisible; }
- (void)setSecondaryViewVisible:(BOOL)visible { _secondaryVisible=visible&&_sceneType==4; }
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
- (NSString *)updateCharacterWithExitSoundBusy:(BOOL)busy tick:(uint32_t)tick {
    /* Called after the preceding frame's effect request has been started.
     * Busy is the actual slot28 player, never a guessed duration. */
    uint32_t delta=_characterClockInitialized?tick-_characterLastTick:0;
    _characterClockInitialized=YES;_characterLastTick=tick;
    if(_characterAction.exit_pending&&busy)_exitSoundBusyObserved=YES;
    dc_scene_character_event event;
    if(dc_scene_character_step(&_characterAction,delta,busy,&event)!=DC_OK)return @"Character action update failed";
    if(event.request_transition)_exitSoundWaitMs=tick-_exitSoundStartTick;
    dc_animation_state animation={0};dc_model_get_animation(_actor.model,&animation);
    if(_characterAnimationStarts&&animation.current==1&&!_characterReturnedIdle) {
        _characterReturnedIdle=YES;
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
- (void)resumeAtTick:(uint32_t)tick {
    uint32_t elapsed=_tickInitialized?tick-_lastTick:0;
    dc_model_shift_clock(_map.model,elapsed);dc_model_shift_clock(_actor.model,elapsed);
    if(_face.model)dc_model_shift_clock(_face.model,elapsed);
    if(_autoCamera.model)dc_model_shift_clock(_autoCamera.model,elapsed);
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model)
        dc_model_shift_clock(_watchAuxiliary[auxiliary].model,elapsed);
    _lastTick=_characterLastTick=tick;_characterClockInitialized=YES;
    _exitSoundStartTick+=elapsed;_interactionStartTick+=elapsed;_interactionState.start_tick+=elapsed;
    _pointerCameraOwner=0;_inputInitialized=NO;_previousGameMenuTouch=NO;
}
- (NSString *)applyConfiguration:(const dc_config *)configuration {
    if(!configuration)return @"Missing scene configuration";
    uint32_t secondary=0;float wheel=4;
    dc_config_switch_value(configuration,4,&secondary);dc_config_slider_value(configuration,6,&wheel);
    _secondaryVisible=_sceneType==4&&secondary!=0;_secondaryLimits.wheel_step=wheel;
    for(unsigned i=0;i<3;++i){
        uint32_t visible;dc_config_switch_value(configuration,i,&visible);
        uint32_t node=[self findNode:&_map name:[NSString stringWithFormat:@"m_Nn_level%u",i+1]];
        if(node!=UINT32_MAX&&dc_model_hide_node(_map.model,node,!visible)!=DC_OK)return @"Configured map visibility failed";
        float channel;dc_config_slider_value(configuration,7+i,&channel);_backgroundColor[i]=(uint8_t)channel;
    }
    _backgroundColor[3]=255;
    uint32_t fourth=[self findNode:&_map name:@"m_Nn_level4"];
    if(fourth!=UINT32_MAX){
        uint32_t visible=0;
        if((_mapSelector==0&&_sceneType==4)||(_mapSelector==1&&_sceneType==5))dc_config_switch_value(configuration,2,&visible);
        dc_model_hide_node(_map.model,fourth,!visible);
    }
    return nil;
}
- (dc_camera_orbit)activeCameraOrbit {
    dc_camera_orbit orbit={.base=_cameraBase,.stored_distance=_cameraDistance*expf(_padCameraZoom),
        .height=_cameraHeight,.pitch=_cameraPitch+_padCameraPitch,.yaw=_cameraYaw+_padCameraYaw};
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
    _padCameraYaw=_padCameraPitch=_padCameraZoom=_padCameraPanX=_padCameraPanZ=0;
    _cameraAutoSelected=YES;
}
- (NSString *)applyContextSelection:(uint32_t)selection {
    if(_contextMenu.icon==1) {
        dc_scene_character_event event;
        dc_status result=dc_scene_character_select(&_characterAction,_sceneType,_stageProgress,selection,&event);
        if(result==DC_NOT_FOUND){++_pendingContextActions;return nil;}
        if(result!=DC_OK)return @"Original character menu action rejected";
        if(selection==1)_exitSoundStartTick=_lastTick;
        ++_characterActionCount;
        return [self applyCharacterEvent:event tick:_lastTick];
    }
    dc_scene_action_plan plan;
    dc_status status=dc_scene_action_build(_sceneType,_contextMenu.icon,selection,_primaryCameraMode,_secondaryCameraMode,&plan);
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
            return [self applyContextSelection:(uint32_t)event.selected];
        }
        ++_contextDismissals;
    }
    return nil;
}
- (void)consumeChapterEndAction { _chapterEndAction=0; }
- (NSString *)characterNode:(NSString *)name {
    return [name hasPrefix:@"a_"]?[NSString stringWithFormat:@"%c%@",_characterPrefix,[name substringFromIndex:1]]:name;
}
- (void)applyOutfitVariant:(uint32_t)variant {
    /* Original 0x5181f0-style outfit selection through hidden alternate
     * outfit meshes. Variant 1 shows the skirt set instead of the dress,
     * variant 2 removes the bra, variant 3 removes the panties; any other
     * variant restores the default visibility. */
    NSArray<NSString *> *dress=@[@"a_On_wanpiEHC",@"a_On_wanpiEHM",@"a_On_wanpiHHM",
        @"a_On_wanpiEHU",@"a_On_wanpiHHU",@"a_On_wanpiHHC"];
    NSArray<NSString *> *skirt=@[@"a_On_skartHF",@"a_On_skartHB",@"a_On_skartHA"];
    NSArray<NSString *> *bra=@[@"a_On_buraH"];
    NSArray<NSString *> *panty=@[@"a_On_pantuH",@"a_On_pantuH3",@"a_On_pantuH2"];
    for(NSString *name in dress){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,variant==1?1:0);}
    for(NSString *name in skirt){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,variant==1?0:1);}
    for(NSString *name in bra){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,variant==2?1:0);}
    for(NSString *name in panty){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,variant==3?1:0);}
    _storyPhase=0;_interactionCompleted=NO;_chapterEndAction=0;
}
- (void)setEditMode:(BOOL)editMode {
    _editMode=editMode;
    if(editMode){_storyPhase=0;_playerSaveDirty=NO;}
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
    // Original 0x5181f0 hides alternate outfits and facial effect meshes.
    NSArray<NSString *> *actorNames=@[@"a_On_wanpiHEC",@"a_On_wanpiEHM",@"a_On_wanpiHHM",
        @"a_On_wanpiEHU",@"a_On_wanpiHHU",@"a_On_wanpiEHC",@"a_On_wanpiHHC",
        @"a_On_skartHF",@"a_On_skartHB",@"a_On_skartHA",@"a_On_buraH",
        @"a_On_pantuH",@"a_On_pantuH3",@"a_On_pantuH2",@"a_On_sune_L",@"a_On_sune_R",
        @"a_On_neko_vive",@"a_On_tori_vive"];
    NSArray<NSString *> *faceNames=@[@"a_On_nekomimi",@"a_On_kuchsiru_F",@"a_On_kuchsiru_ita",
        @"a_On_kuchsiru_o",@"a_On_namida"];
    for(NSString *name in actorNames){uint32_t node=[self findNode:&_actor name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_actor.model,node,1);}
    for(NSString *name in faceNames){uint32_t node=[self findNode:&_face name:[self characterNode:name]];if(node!=UINT32_MAX)dc_model_hide_node(_face.model,node,1);}
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
    if(status!=DC_OK || slot->info.textures>64) { if(error)*error=@"Game model profile rejected"; return NO; }
    slot->textureCount=slot->info.textures;slot->textures=calloc(slot->textureCount,sizeof(uintptr_t));
    if(slot->textureCount && !slot->textures) { if(error)*error=@"Game texture handle allocation failed"; return NO; }
    for(uint32_t i=0;i<slot->textureCount;++i) {
        dc_image_info info;status=dc_xx_image_probe(slot->xx,i,&info);
        if(status!=DC_OK || info.rgba_bytes>64*1024*1024) { if(error)*error=@"Game texture profile rejected"; return NO; }
        NSMutableData *pixels=[NSMutableData dataWithLength:info.rgba_bytes];
        status=dc_xx_image_decode(slot->xx,i,pixels.mutableBytes,pixels.length,&info);
        if(status!=DC_OK) {
            if(error)*error=[NSString stringWithFormat:@"Game texture %u decode failed: status=%d",i,status];
            return NO;
        }
        status=dc_vk_sprite_upload(_renderer,info.width,info.height,pixels.bytes,pixels.length,&slot->textures[i]);
        if(status!=DC_OK) {
            if(error)*error=[NSString stringWithFormat:@"Game texture %u upload failed (%ux%u, %zu bytes): status=%d, %s",
                i,info.width,info.height,(size_t)pixels.length,status,dc_vk_sprite_error(_renderer)];
            return NO;
        }
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
    if(!_playerSaveDirty)return YES;
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
    _secondaryVisible=_sceneType==4;
    _secondaryLimits=(dc_camera_pointer_limits){100,5,20,-30,4};
    _backgroundColor[3]=255;
    _stageProgress=progress;_mainIconHover=-1;_lastContextSelection=-1;
    _sceneUITextures=[NSMutableDictionary dictionary];
    _storyStage=profile.stage>=0 ? (uint32_t)profile.stage : (stage<=2 ? stage : 0);
    if(dc_game_actor_prefix(_storyStage,&_characterPrefix)!=DC_OK){if(error)*error=@"Actor stage profile rejected";return nil;}
#if DEBUG
    _captureGameplayFrame=[NSProcessInfo.processInfo.environment[@"PORTLAB_CAPTURE_GAMEPLAY"] isEqualToString:@"1"];
#endif
    _cameraFallbacks=[NSMutableDictionary dictionary];
    _gameMenu=(dc_menu_state){.selected=-1,.hover=-1};
    _gameMenuInitialized=YES;
    _naturalGameplayRoute=![[[NSProcessInfo processInfo] environment][@"PORTLAB_EXERCISE_REAL_GAMEPLAY"] isEqualToString:@"1"];
    if(_sceneType==4) {
        _sceneUIArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:nil];
        if(!_sceneUIArchive){if(error)*error=@"Original scene UI archive unavailable";return nil;}
        for(NSString *icon in @[@"chara",@"fuku",@"cam",@"sys"])for(NSString *state in @[@"S",@"N"]) {
            NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icon,state];
            if(![self sceneUITexture:name error:error])return nil;
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
               ![self openModel:&_watchAuxiliary[auxiliary] staticOnly:NO error:error])return nil;
            if(dc_model_request(_watchAuxiliary[auxiliary].model,0,0)!=DC_OK){if(error)*error=@"Watch auxiliary animation request failed";return nil;}
        }
    }
    if(_face.xxData && _face.xaData && ![self openModel:&_face staticOnly:YES error:error])return nil;
    if(_sceneType==4) {
        DCArchive *cameraArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_17.pp"]] error:&reason];
        if(!cameraArchive){if(error)*error=@"Original automatic camera archive unavailable";return nil;}
        _autoCamera.xxData=[self entry:@"auto_cam.xx" archive:cameraArchive error:error];
        _autoCamera.xaData=[self entry:@"auto_cam.xa" archive:cameraArchive error:error];
        if(!_autoCamera.xxData||!_autoCamera.xaData||![self openModel:&_autoCamera staticOnly:NO error:error])return nil;
        /* 00522ff0 leaves the auto_cam controller on its original clip0.
         * Clip1 is empty in this asset and would freeze the camera. */
        if(dc_model_request(_autoCamera.model,0,0)!=DC_OK){if(error)*error=@"Original automatic camera animation unavailable";return nil;}
    }
    NSString *morphError=nil;
    if(_actor.model && _actor.xaInfo.morph_tracks &&
       ![self buildMorphCaches:&_actor error:&morphError]) {
        if(error)*error=morphError ?: @"Game actor morph initialization failed";return nil;
    }
    if(_face.model && ![self buildMorphCaches:&_face error:&morphError]) { if(error)*error=morphError ?: @"Game morph cache initialization failed";return nil; }
    if(dc_model_request(_actor.model,1,0)!=DC_OK) { if(error)*error=@"Game actor animation request failed"; return nil; }
    _actorHeadNode=[self placementNodeFromPLST:actorPlacement model:&_actor];
    if(_actorHeadNode==UINT32_MAX)_actorHeadNode=[self findNode:&_actor name:[self characterNode:@"a_Nz_kubi2"]];
    if(_actorHeadNode==UINT32_MAX)_actorHeadNode=[self findNode:&_actor name:[self characterNode:@"a_Kp_kubi2"]];
    // PLST attaches sourceBind * inverse(targetBind) to targetAnimatedWorld.
    // All face meshes descend from the source node, so compensate its model
    // world with the full actor target bind inverse before applying animation.
    dc_model *bindModel=NULL;dc_matrix identity=gameIdentity(),targetBind;
    dc_status bindStatus=dc_model_open_static(_actor.xxData.bytes,_actor.xxData.length,&bindModel);
    if(bindStatus==DC_OK)bindStatus=dc_model_tick(bindModel,0,0,&identity);
    if(bindStatus==DC_OK)bindStatus=dc_model_global(bindModel,_actorHeadNode,&targetBind);
    if(bindStatus==DC_OK)bindStatus=dc_matrix_inverse_affine(&targetBind,&_faceBindInverse);
    dc_model_close(bindModel);
    if(bindStatus!=DC_OK){if(error)*error=@"Face bind-pose attachment failed";return nil;}
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
    if(_renderer && slot->textures)for(uint32_t i=0;i<slot->textureCount;++i)if(slot->textures[i])dc_vk_sprite_remove_texture(_renderer,slot->textures[i]);
    freeMorphCaches(slot);
    free(slot->textures);slot->textures=NULL;slot->textureCount=0;
    if(slot->model)dc_model_close(slot->model);if(slot->xx)dc_xx_close(slot->xx);
    slot->model=NULL;slot->xx=NULL;
}
- (void)detachRenderer {
    /* All draws are blocking and serialized by the view's render queue.
     * Release GPU handles while their renderer is still alive, including
     * partially initialized models; dealloc can then free the CPU data. */
    dc_game_model *models[]={&_map,&_actor,&_face,&_autoCamera,&_watchAuxiliary[0],&_watchAuxiliary[1]};
    for(size_t m=0;m<sizeof(models)/sizeof(models[0]);++m) {
        dc_game_model *slot=models[m];
        if(slot->textures)for(uint32_t i=0;i<slot->textureCount;++i) {
            if(_renderer && slot->textures[i])dc_vk_sprite_remove_texture(_renderer,slot->textures[i]);
            slot->textures[i]=0;
        }
    }
    [self detachSceneUI];_renderer=NULL;
}
- (void)dealloc { [self savePlayerState];free(_surfaces);[self detachSceneUI];[self detachModel:&_map];[self detachModel:&_actor];[self detachModel:&_face];[self detachModel:&_autoCamera];[self detachModel:&_watchAuxiliary[0]];[self detachModel:&_watchAuxiliary[1]]; }

- (void)detachSceneUI {
    if(_renderer)for(NSNumber *handle in _sceneUITextures.allValues)dc_vk_sprite_remove_texture(_renderer,handle.unsignedLongLongValue);
    [_sceneUITextures removeAllObjects];
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
        if(row==2&&!_stageProgress)continue;
        float u0,u1;if(dc_scene_icon_uv(_storyStage,row,&u0,&u1)!=DC_OK)return @"Scene icon atlas selection failed";
        dc_sprite_pose p={.width=96*scale,.height=96*scale,.x=viewport.x+920*scale,.y=viewport.y+(328+112*(row-1))*scale,
            .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u0=u0,.u1=u1,.v1=1};
        for(unsigned state=0;state<2;++state) {
            if(state&&_mainIconHover!=(int32_t)row)continue;
            NSString *name=[NSString stringWithFormat:@"P_%@_%@.ema",icons[row-1],state?@"N":@"S"];
            NSString *error=[self appendSceneUISprite:name pose:p draws:draws count:count storage:storage];if(error)return error;++_sceneUIDraws;
        }
    }
    _sceneUIIconDraws=_sceneUIDraws;
    if(_contextOpen)for(unsigned i=0;i<_contextMenu.count;++i) {
        dc_scene_context_item item=_contextMenu.items[i];if(item.resource_id<0)continue;
        dc_sprite_pose p={.width=240*scale,.height=32*scale,.x=viewport.x+item.x*scale,.y=viewport.y+item.y*scale,.origin_x=.9f,.origin_y=.5f,
            .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
        for(unsigned state=0;state<2;++state) {
            if(state&&_contextMenu.hover!=(int32_t)i)continue;
            char resource[32];if(dc_scene_context_resource(_sceneType,_contextMenu.icon,item.resource_id,state,resource,sizeof(resource))!=DC_OK)return @"Scene context resource profile failed";
            NSString *error=[self appendSceneUISprite:[NSString stringWithUTF8String:resource] pose:p draws:draws count:count storage:storage];if(error)return error;++_sceneUIDraws;
        }
    }
    return nil;
}

- (uint32_t)textureFor:(dc_game_model *)slot mesh:(const dc_xx_submesh *)mesh {
    dc_xx_material material;if(dc_xx_material_at(slot->xx,mesh->material,&material)!=DC_OK)return UINT32_MAX;
    for(uint32_t i=0;i<slot->info.textures;++i) {
        dc_xx_texture texture;if(dc_xx_texture_at(slot->xx,i,&texture)!=DC_OK)continue;
        const uint8_t *a=(const uint8_t *)slot->xxData.bytes+material.texture_names[0].offset;
        const uint8_t *b=(const uint8_t *)slot->xxData.bytes+texture.name.offset;size_t an=0,bn=0;
        while(an<material.texture_names[0].length&&a[an]!=255)++an;while(bn<texture.name.length&&b[bn]!=255)++bn;
        if(an==bn&&an<material.texture_names[0].length&&bn<texture.name.length&&!memcmp(a,b,an))return i;
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
    return YES;
}

- (BOOL)applyMorphsToModel:(dc_game_model *)slot frame:(float)frame
    buffers:(dc_mesh_vertex **)buffers counts:(const uint32_t *)counts error:(NSString **)error {
    if(!slot->morph)return YES;
    dc_morph_mesh_buffer *meshBuffers=calloc(slot->info.submeshes?slot->info.submeshes:1,sizeof(*meshBuffers));
    if(!meshBuffers){if(error)*error=@"Game morph buffer descriptors failed";return NO;}
    for(uint32_t i=0;i<slot->info.submeshes;++i) {
        meshBuffers[i]=(dc_morph_mesh_buffer){.vertices=buffers[i],.count=counts[i]};
    }
    dc_status status=dc_morph_apply(slot->morph,frame,meshBuffers,slot->info.submeshes);
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
            if(!morphVertices[mesh] || dc_model_load_vertices(slot->model,mesh,morphVertices[mesh],meshView.vertex_count)!=DC_OK) {
                for(uint32_t j=0;j<=mesh;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph vertex load failed";
            }
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
        if(renderState.hidden||material.components[3]<=0)continue;
        uint8_t depth=renderState.transparent_queue?DC_VK_DEPTH_AUTO_TRANSLUCENT:DC_VK_DEPTH_AUTO;
        uint8_t cull=renderState.two_sided?DC_VK_CULL_NONE:DC_VK_FRONT_NEGATIVE_AREA;
        uint32_t texture=[self textureFor:slot mesh:&mesh];if(texture==UINT32_MAX){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game material texture not found";}
        size_t vertexCount=0;
        if(morphVertices) {
            uint16_t *indices=calloc(mesh.index_count?mesh.index_count:1,sizeof(*indices));dc_matrix mvp=camera->view_projection;uint32_t space=0;
            if(!indices || dc_xx_load_mesh_indices(slot->xx,i,indices,mesh.index_count)!=DC_OK || dc_model_vertex_space(slot->model,i,&space)!=DC_OK) { free(indices);for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh projection setup failed"; }
            if(space==DC_MODEL_SPACE_LOCAL) { dc_matrix global;if(dc_model_global(slot->model,mesh.node,&global)!=DC_OK || dc_matrix_multiply(&global,&camera->view_projection,&mvp)!=DC_OK) { free(indices);for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph node transform failed"; } }
            status=dc_mesh_clip_project(morphVertices[i],morphCounts[i],indices,mesh.index_count,&mvp,viewport,gameColor(&material),NULL,0,&vertexCount);if(status!=DC_OK){free(indices);for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh clip query failed";}
            if(!vertexCount){free(indices);continue;}
            NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];status=dc_mesh_clip_project(morphVertices[i],morphCounts[i],indices,mesh.index_count,&mvp,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);free(indices);if(status!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh projection failed";}
            [storage addObject:vertices];draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=slot->textures[texture],.blend_mode=renderState.blend_mode,.point_filter=renderState.point_filter,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};*triangles+=(uint32_t)(vertexCount/3);continue;
        }
        status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),NULL,0,&vertexCount);if(status!=DC_OK){return @"Game mesh clip query failed";}if(!vertexCount)continue;
        NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);if(status!=DC_OK)return @"Game mesh projection failed";
        [storage addObject:vertices];
        draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=slot->textures[texture],.blend_mode=renderState.blend_mode,.point_filter=renderState.point_filter,.depth_mode=depth,.cull_mode=cull,.priority=renderState.priority};
        *triangles+=(uint32_t)(vertexCount/3);
    }
    if(morphVertices){for(uint32_t i=0;i<slot->info.submeshes;++i)free(morphVertices[i]);free(morphVertices);free(morphCounts);}
    return nil;
}
- (NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput
    width:(uint32_t)width height:(uint32_t)height {
    if(!_loaded)return @"Game scene is not loaded";
    BOOL gameplayScene=(_sceneType==4);
    BOOL cameraScene=(_sceneType>=4&&_sceneType<=6);
    BOOL pcHome=(pcInput.keys[0xc7]&1)!=0,pcEnd=(pcInput.keys[0xcf]&1)!=0;
    BOOL pcPageUp=(pcInput.keys[0xc9]&1)!=0,pcPageDown=(pcInput.keys[0xd1]&1)!=0;
    BOOL pcNum8=(pcInput.keys[0x48]&1)!=0,pcNum4=(pcInput.keys[0x4b]&1)!=0;
    BOOL pcNum2=(pcInput.keys[0x50]&1)!=0,pcNum6=(pcInput.keys[0x4d]&1)!=0;
    BOOL pcArrowUp=(pcInput.keys[0xc8]&1)!=0,pcArrowLeft=(pcInput.keys[0xcb]&1)!=0;
    BOOL pcArrowDown=(pcInput.keys[0xd0]&1)!=0,pcArrowRight=(pcInput.keys[0xcd]&1)!=0;
    if(pcInput.keys[0x2e]==3)[self requestRenderCapture:@"gameplay-capture.png"];
    if(cameraScene&&(pcInput.keys[0x3b]==3||pcInput.keys[0x3c]==3)&&!_pendingSystemAction){
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
    if(controller.pressed&DC_PAD_Y){_padCameraYaw=0;_padCameraPitch=0;_padCameraZoom=0;}
    /* Context-menu dismissal never advances the chapter. */
    if(gameplayScene && (controller.pressed&DC_PAD_B)&&_storyPhase==1) {
        _storyPhase=0;_interactionCompleted=NO;_interactionState.completed=0;
        _chapterEndAction=0;
    }
    /* Non-gameplay callbacks have separate state machines. Do not invent
     * tap-to-skip behavior for watch/night/ending chapters. */
    BOOL secondaryOwnsPointer=NO;
    BOOL primaryOwnsPointer=NO;
    if(cameraScene) {
        if(pcInput.keys[0x2f]==3) {
            _secondaryVisible=!_secondaryVisible;++_secondaryVisibilityChanges;
#if DEBUG
            if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_TOUCH_CONTROLS"] isEqualToString:@"1"])
                [self requestRenderCapture:_secondaryVisible?@"gameplay-secondary-visible-native.png":@"gameplay-secondary-hidden-native.png"];
#endif
        }
        float inputScale=fminf((float)width/1024.f,(float)height/768.f);
        float mx=((x+1)*.5f*width-(width-1024*inputScale)*.5f)/inputScale;
        float my=((1-y)*.5f*height-(height-768*inputScale)*.5f)/inputScale;
        BOOL held=(pcInput.mouse[0]&1)||(pcInput.mouse[1]&1)||(pcInput.mouse[2]&1);
        BOOL inside=mx>=0&&mx<=352&&my>=504&&my<=768;
        BOOL press=pcInput.mouse[0]==3||pcInput.mouse[1]==3||pcInput.mouse[2]==3;
        BOOL iconRegion=mx>=880&&my>=300&&my<=768;
        if(!held&&!pcInput.wheel)_pointerCameraOwner=0;
        if(!_pointerCameraOwner&&!_contextOpen&&(press||pcInput.wheel))
            _pointerCameraOwner=_secondaryVisible&&inside?2:((pcInput.mouse[1]&&iconRegion)?1:3);
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
    }
    if(cameraScene&&!secondaryOwnsPointer&&!primaryOwnsPointer&&!_characterAction.exit_pending&&!_characterAction.transition_pending) {
        float scale=fminf((float)width/1024.f,(float)height/768.f);
        float px=((x+1)*.5f*width-(width-1024*scale)*.5f)/scale;
        float py=((1-y)*.5f*height-(height-768*scale)*.5f)/scale;
        uint32_t left=pcInput.pointer_active||pcInput.mouse[0]?pcInput.mouse[0]:(touching?(_previousGameMenuTouch?1:3):(_previousGameMenuTouch?2:0));
        if(_contextOpen) {
            NSString *error=[self stepContextAtX:px y:py left:left right:pcInput.mouse[1]];if(error)return error;
        } else {
            dc_menu_button buttons[DC_GAME_MENU_COUNT];dc_game_menu_profile(buttons,DC_GAME_MENU_COUNT);
            buttons[2].disabled=_stageProgress?0:1;
            int32_t result=-1;
            if(dc_menu_step(&_gameMenu,buttons,DC_GAME_MENU_COUNT,(int32_t)lrintf(px),(int32_t)lrintf(py),1,0,&result)!=DC_OK)return @"Scene icon hover failed";
            if(left!=0&&dc_menu_step(&_gameMenu,buttons,DC_GAME_MENU_COUNT,(int32_t)lrintf(px),(int32_t)lrintf(py),1,left,&result)!=DC_OK)
                return @"Scene icon input failed";
            _mainIconHover=result==-1?-1:_gameMenu.hover;
            if(result==1&&_mainIconHover>=1&&_mainIconHover<=4){
                ++_acceptedMenuEvents;_lastAcceptedMenuRow=(uint32_t)_mainIconHover;
                if(_sceneType==4&&_mapSelector==0&&_mainIconHover==1&&!_pendingVoiceName)
                    _pendingVoiceName=@"ast001_01.wav";
            }
            if(pcInput.mouse[1]==3&&_mainIconHover>=1&&_mainIconHover<=4) {
                dc_animation_state animation={0};dc_model_get_animation(_actor.model,&animation);
                dc_scene_context_input input={.scene_type=_sceneType,.icon=(uint32_t)_mainIconHover,.stage_progress=_stageProgress,
                    .animation=animation.current,.camera_mode=_primaryCameraMode,.secondary_camera_mode=_secondaryCameraMode,.x=px,.y=py};
                dc_status status=dc_scene_context_build(&input,&_contextMenu);
                if(status!=DC_OK&&status!=DC_NOT_FOUND)return @"Scene context profile failed";
                if(status==DC_OK&&_contextMenu.count){
                    _contextOpen=YES;++_contextOpens;
                    /* Original update dispatches the newly opened menu in
                     * the same frame, including simultaneous mouse buttons. */
                    NSString *error=[self stepContextAtX:px y:py left:left right:pcInput.mouse[1]];if(error)return error;
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
    if(_primaryCameraMode!=2) {
    if(controller.pressed&DC_PAD_R3){_padCameraYaw=0;_padCameraPitch=0;_padCameraZoom=0;}
    float cameraX=controller.rx/32767.f,cameraY=controller.ry/32767.f;
    if(pcNum4)cameraX-=1.f;if(pcNum6)cameraX+=1.f;
    if(pcNum8||pcPageUp)cameraY-=1.f;if(pcNum2||pcPageDown)cameraY+=1.f;
    if(padDelta>0 && (cameraX!=0 || cameraY!=0))_controllerCameraAdvanced=YES;
    if(controller.buttons&DC_PAD_L)cameraX-=1;
    if(controller.buttons&DC_PAD_R)cameraX+=1;
    _padCameraYaw=remainderf(_padCameraYaw+cameraX*padDelta*1.5f,6.2831853f);
    _padCameraPitch=fmaxf(-.7f,fminf(.7f,_padCameraPitch+cameraY*padDelta));
    float zoom=((controller.buttons&DC_PAD_ZR)?1.f:0.f)-((controller.buttons&DC_PAD_ZL)?1.f:0.f);
    if(pcHome)zoom+=1.f;if(pcEnd)zoom-=1.f;
    if(!secondaryOwnsPointer){if(pcInput.wheel>0)zoom+=1.f;else if(pcInput.wheel<0)zoom-=1.f;}
    _padCameraZoom=fmaxf(-.7f,fminf(1.f,_padCameraZoom+zoom*padDelta));
    float panX=(pcArrowRight?1.f:0.f)-(pcArrowLeft?1.f:0.f);
    float panZ=(pcArrowDown?1.f:0.f)-(pcArrowUp?1.f:0.f);
    _padCameraPanX+=panX*padDelta*2.0f;_padCameraPanZ+=panZ*padDelta*2.0f;
    }
    /* Advance each model exactly once before selecting the rendered camera.
     * The original automatic view uses this frame's animated nodes. */
    if(dc_model_tick(_map.model,delta,tick,&_map.world)!=DC_OK||
       dc_model_tick(_actor.model,delta,tick,&_actor.world)!=DC_OK)return @"Game model tick failed";
    if(_face.model) {
        if(![self updateFaceAttachment])return @"Game face anchor lookup failed";
        if(dc_model_tick(_face.model,0,tick,&_face.world)!=DC_OK)return @"Game face tick failed";
    }
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(_watchAuxiliary[auxiliary].model) {
        if(dc_model_tick(_watchAuxiliary[auxiliary].model,delta,tick,&_watchAuxiliary[auxiliary].world)!=DC_OK)
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
    if(_sceneType==6&&_primaryCameraMode==0) {
        uint32_t nightCameraNode=[self findNode:&_actor name:[self characterNode:@"s_Nn_kamera_S"]];
        dc_matrix nightCameraWorld;
        if(nightCameraNode!=UINT32_MAX&&dc_model_global(_actor.model,nightCameraNode,&nightCameraWorld)==DC_OK)
            orbit=(dc_camera_orbit){.base=nightCameraWorld};
    }
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
    size_t geometryCapacity=(_map.info.submeshes+_actor.info.submeshes+_face.info.submeshes+auxiliaryMeshes)*(_secondaryVisible?2:1);
    size_t capacity=geometryCapacity+22+self.transitionScene.transitionMeshCapacity;
    dc_vk_geometry_item *draws=calloc(capacity,sizeof(*draws));if(!draws)return @"Game draw allocation failed";
    __attribute__((objc_precise_lifetime)) NSMutableArray *storage=[NSMutableArray array];size_t count=0;_visibleMapTriangles=_visibleActorTriangles=0;
    NSString *failure=[self append:&_map camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleMapTriangles];
    size_t mapDrawCount=count;
    if(!failure)failure=[self append:&_actor camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure && delta && _actorSkinMeshCount)_actorSkinAdvanced=YES;
    if(!failure && _face.model)failure=[self append:&_face camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(!failure&&_watchAuxiliary[auxiliary].model)
        failure=[self append:&_watchAuxiliary[auxiliary] camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    size_t primarySceneCount=count,secondaryStart=count,secondaryMapCount=0,secondarySceneCount=0;
    if(!failure&&_secondaryVisible) {
        uint32_t secondaryMapTriangles=0,secondaryActorTriangles=0;
        failure=[self append:&_map camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryMapTriangles];
        secondaryMapCount=count-secondaryStart;
        if(!failure)failure=[self append:&_actor camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryActorTriangles];
        if(!failure&&_face.model)failure=[self append:&_face camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryActorTriangles];
        for(unsigned auxiliary=0;auxiliary<2;++auxiliary)if(!failure&&_watchAuxiliary[auxiliary].model)
            failure=[self append:&_watchAuxiliary[auxiliary] camera:&secondaryCamera viewport:&_secondaryViewport draws:draws count:&count storage:storage triangles:&secondaryActorTriangles];
        secondarySceneCount=count-secondaryStart;
    }
    size_t sceneDrawCount=count;
    if(!failure)failure=[self appendSceneUI:draws count:&count storage:storage viewport:viewport];
    if(!failure&&_characterAction.transition_pending) {
        failure=[self.transitionScene appendTransitionAtTick:tick viewport:viewport draws:draws capacity:capacity count:&count storage:storage];
        uint32_t ready=0;
        if(!failure&&[self.transitionScene queryTransitionReady:&ready]!=DC_OK)failure=@"Character exit transition query failed";
        /* Only the initial progress-zero type-4 callback is admitted here.
         * Evolved progress and special ending routing require separate ports. */
        if(!failure&&ready&&_sceneType==4&&_stageProgress==0)_chapterEndAction=2;
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
