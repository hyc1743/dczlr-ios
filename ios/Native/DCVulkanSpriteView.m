#import "DCVulkanSpriteView.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
#include "dc_vk_sprite.h"
#include "dc_sprite_spv.h"
#include "dc_animation.h"
#include "dc_xa.h"
#include "dc_xx.h"
#include "dc_diagnostic_xx.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import "DCGameAudio.h"
#import "DCIntroScene.h"
#import "DCGameScene.h"
#import "DCConfigScene.h"
#import "DCSaveScene.h"
#import "DCDummyScene.h"
#import "DCEndingScene.h"
#import "DCGamepadView.h"
#include "dc_menu.h"
#include "dc_save.h"
#include "dc_gameplay.h"
#include "dc_pc_touch.h"
#include "dc_story.h"
#include "dc_flow.h"
#include <math.h>
#include <string.h>

static const char dcRenderQueueKey;
static const uint32_t dcFlowPersistHeaderBytes = 13u;

static void dc_write_word_le(uint8_t *out, uint32_t bits) {
    for (uint32_t i = 0; i < 4; ++i) out[i] = (uint8_t)(bits >> (8 * i));
}

static void dc_write_float_le(uint8_t *out, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    dc_write_word_le(out, bits);
}

static uint16_t dc_flow_read16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void dc_flow_write16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xffu);
    p[1] = (uint8_t)((v >> 8) & 0xffu);
}

static void dc_flow_add16(uint8_t *p, uint32_t delta) {
    uint32_t v = (uint32_t)dc_flow_read16(p) + delta;
    dc_flow_write16(p, (uint16_t)(v > 10000u ? 10000u : v));
}

static uint32_t dc_flow_read32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void dc_flow_update_stage_badges(uint8_t *p, uint8_t stage, int32_t *outNewBadge) {
    if (p[0x23] == 2) {
        if (outNewBadge) *outNewBadge = -1;
        return;
    }
    uint32_t fastest = dc_flow_read32(p + 0x30);
    uint8_t earned[9] = {0};
    if (p[3] == 0 && fastest > 0u && fastest <= 90000u && stage != 1u) earned[0] = 1;
    if (p[4] == 0 && dc_flow_read16(p + 0x14) >= 2u && stage != 0u) earned[1] = 1;
    if (p[5] == 0 && (uint32_t)dc_flow_read16(p + 0x16) + (uint32_t)dc_flow_read16(p + 0x18) >= 2u) earned[2] = 1;
    if (p[6] == 0 && dc_flow_read16(p + 0x1a) >= 5u) earned[3] = 1;
    if (p[7] == 0 && dc_flow_read16(p + 0x1c) >= 3u) earned[4] = 1;
    if (p[8] == 0 && dc_flow_read16(p + 0x10) >= 5u) earned[5] = 1;
    if (p[9] == 0 && dc_flow_read16(p + 0x2c) >= 1u) earned[6] = 1;
    if (p[10] == 0 && dc_flow_read16(p + 0x1e) >= 2u) earned[7] = 1;
    if (p[11] == 0 && dc_flow_read16(p + 0x20) >= 2u) earned[8] = 1;
    int32_t firstNew = -1;
    for (unsigned i = 0; i < 9; ++i) {
        if (earned[i] != 0) {
            firstNew = (int32_t)i;
            p[3 + i] = 1;
            break;
        }
    }
    uint8_t count = 0;
    for (unsigned i = 0; i < 9; ++i) {
        if (p[3 + i] != 0) ++count;
    }
    p[2] = count;
    if (count == 9 && p[0x23] == 1) p[0x23] = 2;
    if (outNewBadge) *outNewBadge = firstNew;
}

static BOOL dc_pc_key_held(const dc_pc_frame *input, uint32_t scan) {
    return input && scan < DC_PC_KEY_COUNT && (input->keys[scan] & 1u) != 0;
}
static BOOL dc_pc_key_pressed(const dc_pc_frame *input, uint32_t scan) {
    return input && scan < DC_PC_KEY_COUNT && input->keys[scan] == 3;
}
static void dc_merge_pc_actions(dc_pc_frame input, dc_pad_frame *controller) {
    if (!controller) return;
    /* Alt+F4 leaves gameplay through the safe title transition on iOS and
     * never terminates the app. ESC (scan 1) is handled per-scene as the
     * original boss-key screen (DCDummyScene). */
    if (dc_pc_key_held(&input,0x38) && dc_pc_key_pressed(&input,0x3e)) {
        controller->buttons |= DC_PAD_MINUS;controller->pressed |= DC_PAD_MINUS;
    }
    /* Mouse buttons keep their original pointer/menu semantics. A right
     * click over a game button must not become a global pad Cancel command. */
}

@implementation DCVulkanSpriteView {
    dc_vk_sprite *_renderer;
    uintptr_t _texture;
    DCStartupScene *_startupScene;
    DCGameAudio *_gameAudio;
    DCIntroScene *_introScene;
    DCGameScene *_gameScene;
    DCConfigScene *_configScene;
    DCSaveScene *_saveScene;
    DCDummyScene *_dummyScene;
    uint32_t _dummyOwner;
    DCEndingScene *_endingScene;
    uint32_t _endingSceneTypeOverride;
    int32_t _pendingBadgeStage,_pendingBadgeIndex;
    NSMutableData *_numericState;
    NSData *_configuration;
    uint32_t _systemOwnerType,_systemOwnerChapter;
    BOOL _secondaryViewDisabledSetting;
    dc_title_state _titleState;
    BOOL _titleStateInitialized;
    dc_story_state _story;
    BOOL _storyInitialized;
    dc_flow_state _flowState;
    BOOL _flowInitialized;
    BOOL _resumeNextScene;
    dc_menu_state _titleMenu;
    BOOL _titleMenuInitialized,_previousTitleTouch;
    BOOL _previousGameplayTouch;
    BOOL _suppressGameplayTouch;
    BOOL _titleUnlocksLoaded,_editUnlocked,_extraUnlocked;
    uintptr_t _titleTextures[9];
    uint32_t _width, _height;
    uint32_t _titleWidths[9], _titleHeights[9];
    BOOL _titleSceneLoaded;
    BOOL _extraSceneLoaded;
    uintptr_t _extraTextures[5];
    dc_menu_state _extraMenus[3];
    BOOL _galleryMode;
    BOOL _galleryViewingCG;
    BOOL _galleryWaiting;
    uint32_t _galleryAction;
    uint32_t _galleryIndex;
    uintptr_t _galleryTexture;
    BOOL _pregnancyChoiceLoaded;
    BOOL _pregnancyChoiceActive;
    BOOL _pregnancyChoiceWaiting;
    BOOL _pregnancyChoiceTransitionRequested;
    uint32_t _pregnancyChoiceAction;
    int32_t _pregnancyChoiceHover;
    int32_t _pregnancyChoiceControllerRow;
    dc_menu_state _pregnancyChoiceMenu;
    uintptr_t _pregnancyChoiceTextures[4];
    DCVulkanSpriteScene _presentedScene;
    NSInteger _selectedTitleOption;
    int32_t _controllerTitleRow;
    CFTimeInterval _lastStartupScan;
    CFTimeInterval _lastTitleScan;
    NSString *_deviceName;
    uint64_t _presentedFrames;
    dc_animation_state _diagnosticAnimation;
    dc_animation_clip _diagnosticClip;
    dc_animation_timing _diagnosticTiming;
    dc_material_key _diagnosticMaterialKeys[2];
    dc_material_value _diagnosticMaterial, _diagnosticBaseline;
    dc_pose_key _diagnosticPoseKeys[2];
    dc_matrix _diagnosticPose;
    uint32_t _lastDiagnosticTick;
    BOOL _diagnosticTickInitialized;
    BOOL _diagnosticAnimationAdvanced;
    BOOL _diagnosticMaterialAdvanced;
    BOOL _diagnosticPoseAdvanced;
    dispatch_queue_t _renderQueue;
    atomic_bool _suspended;
    atomic_bool _needsRecoveryAfterResume;
    NSString *_gameplayContext,*_renderProbeStatus;
#if DEBUG
    uint32_t _probeCase,_probeFrame;
    NSMutableDictionary<NSString *,NSDictionary *> *_probeCaptures;
    NSString *_probeWorkerStatus;
#endif
}
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAMetalLayer *layer = (CAMetalLayer *)self.layer;
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        self.opaque = YES;
        _deviceName = @"";
        _selectedTitleOption = -1;
        _pendingBadgeStage = -1;
        _pendingBadgeIndex = -1;
        atomic_init(&_suspended, false);
        atomic_init(&_needsRecoveryAfterResume, false);
        _renderQueue = dispatch_queue_create("org.example.portlab.vulkan-render", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_renderQueue, &dcRenderQueueKey, (void *)&dcRenderQueueKey, NULL);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (void)applicationWillResignActive:(NSNotification *)notification { [self setActive:NO]; }
- (void)applicationDidEnterBackground:(NSNotification *)notification { [self setActive:NO]; }
- (void)applicationDidBecomeActive:(NSNotification *)notification { [self setActive:YES]; }
- (NSString *)deviceName { return _deviceName; }
- (uint64_t)presentedFrames { return _presentedFrames; }
- (DCVulkanSpriteScene)presentedScene { return _presentedScene; }
- (BOOL)controllerMovementAdvanced { return _gameScene.controllerMovementAdvanced; }
- (BOOL)controllerCameraAdvanced { return _gameScene.controllerCameraAdvanced; }
- (BOOL)gameplaySaveCompleted { return _gameScene.manualSaveCompleted; }
- (NSString *)gameplayContext { return _gameplayContext?:@""; }
- (NSString *)renderProbeStatus { return _renderProbeStatus?:@""; }
- (void)pauseActiveScenesAndAudio {
    if (_renderer) dc_vk_sprite_wait_idle(_renderer);
    [_gameAudio pause];
    [_introScene pause];
    [_configScene pause];
    [_saveScene pause];
    [_dummyScene pause];
    [_endingScene pause];
    [_startupScene pause];
    [_gameScene pause];
    _previousTitleTouch = NO;
    _previousGameplayTouch = NO;
    _suppressGameplayTouch = YES;
    _diagnosticTickInitialized = NO;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}
- (void)setActive:(BOOL)active {
    bool shouldSuspend = !active;
    bool prev = atomic_exchange(&_suspended, shouldSuspend);
    if (prev == shouldSuspend) return;
    if (shouldSuspend) {
        dispatch_async(_renderQueue, ^{
            [self pauseActiveScenesAndAudio];
        });
    } else {
        atomic_store(&_needsRecoveryAfterResume, true);
        dispatch_async(_renderQueue, ^{
            [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
            [AVAudioSession.sharedInstance setActive:YES error:nil];
            self->_previousTitleTouch = NO;
            self->_previousGameplayTouch = NO;
            self->_suppressGameplayTouch = YES;
        });
    }
}
- (void)releaseRenderer {
    atomic_store(&_suspended, true);
    dispatch_async(_renderQueue, ^{
        [self pauseActiveScenesAndAudio];
        [self detachRendererOnly];
    });
}
- (BOOL)tryLoadTitleSceneFromDirectory:(NSString *)directory {
    if (_titleSceneLoaded || directory.length == 0) return _titleSceneLoaded;
    if (CACurrentMediaTime() - _lastTitleScan < 1) return NO;
    _lastTitleScan = CACurrentMediaTime();
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"k_defo.ema", @"Title_base.ema", @"Title_start.ema",
        @"Title_load.ema", @"Title_edit.ema", @"Title_extra.ema", @"Title_end.ema",
        @"Title_edit_mono.ema", @"Title_extra_mono.ema"]; });
    NSString *path = [directory stringByAppendingPathComponent:@"RPP_02.pp"];
    NSError *error = nil;
    DCArchive *archive = [[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!archive) return NO;
    uint32_t indices[9];
    for (uint32_t target = 0; target < 9; ++target) {
        indices[target] = UINT32_MAX;
        for (uint32_t i = 0; i < archive.entryCount; ++i) {
            if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:names[target]] == NSOrderedSame) {
                indices[target] = i;
                break;
            }
        }
        if (indices[target] == UINT32_MAX) return NO;
    }
    uintptr_t handles[9] = {0};
    uint32_t widths[9] = {0}, heights[9] = {0};
    const uint32_t logicalWidths[9]={64,1024,256,256,256,256,256,256,256};
    const uint32_t logicalHeights[9]={64,768,48,48,48,48,48,48,48};
    for (uint32_t i = 0; i < 9; ++i) {
        DCDecodedImage *image = [archive decodeImageAtIndex:indices[i] inputLimit:8 * 1024 * 1024
            outputLimit:64 * 1024 * 1024 error:&error];
        if (!image || dc_vk_sprite_upload(_renderer, image.width, image.height, image.rgba.bytes,
                image.rgba.length, &handles[i]) != DC_OK) {
            for (uint32_t j = 0; j < i; ++j) dc_vk_sprite_remove_texture(_renderer, handles[j]);
            return NO;
        }
        /* Original title setup supplies logical sprite sizes separately
         * from the image payload dimensions, including patched textures. */
        widths[i] = logicalWidths[i];
        heights[i] = logicalHeights[i];
    }
    memcpy(_titleTextures, handles, sizeof(handles));
    memcpy(_titleWidths, widths, sizeof(widths));
    memcpy(_titleHeights, heights, sizeof(heights));
    _titleSceneLoaded = YES;
    return YES;
}
- (BOOL)tryLoadPregnancyPromptFromDirectory:(NSString *)directory {
    if (_pregnancyChoiceLoaded || !_renderer || directory.length == 0) return _pregnancyChoiceLoaded;
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"k_defo.ema", @"baby_base.ema", @"cau_yes.ema", @"cau_no.ema"]; });
    NSString *path = [directory stringByAppendingPathComponent:@"RPP_02.pp"];
    NSError *error = nil;
    DCArchive *archive = [[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!archive) return NO;
    uint32_t indices[4];
    for (uint32_t target = 0; target < 4; ++target) {
        indices[target] = UINT32_MAX;
        for (uint32_t i = 0; i < archive.entryCount; ++i) {
            if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:names[target]] == NSOrderedSame) {
                indices[target] = i;
                break;
            }
        }
        if (indices[target] == UINT32_MAX) return NO;
    }
    uintptr_t handles[4] = {0};
    for (uint32_t i = 0; i < 4; ++i) {
        DCDecodedImage *image = [archive decodeImageAtIndex:indices[i] inputLimit:8 * 1024 * 1024
            outputLimit:64 * 1024 * 1024 error:&error];
        if (!image || dc_vk_sprite_upload(_renderer, image.width, image.height, image.rgba.bytes,
                image.rgba.length, &handles[i]) != DC_OK) {
            for (uint32_t j = 0; j < i; ++j) dc_vk_sprite_remove_texture(_renderer, handles[j]);
            return NO;
        }
    }
    memcpy(_pregnancyChoiceTextures, handles, sizeof(handles));
    _pregnancyChoiceLoaded = YES;
    return YES;
}
- (NSString *)enterPregnancyChoiceFromDirectory:(NSString *)directory {
    _flowState.meta.scene_type = 13;
    [_gameAudio stopGameplayAudio];
    [_introScene detachRenderer]; _introScene = nil;
    [_gameScene detachRenderer]; _gameScene = nil;
    [_endingScene detachRenderer]; _endingScene = nil;
    _endingSceneTypeOverride = 0;
    if (_renderer && [self tryLoadPregnancyPromptFromDirectory:directory]) {
        _pregnancyChoiceActive = YES;
        _pregnancyChoiceWaiting = YES;
        _pregnancyChoiceTransitionRequested = NO;
        _pregnancyChoiceAction = 0;
        _pregnancyChoiceHover = -1;
        _pregnancyChoiceControllerRow = 0;
        _pregnancyChoiceMenu = (dc_menu_state){.hover = -1, .selected = -1};
        _previousGameplayTouch = NO;
        _suppressGameplayTouch = YES;
        [self syncStoryFromFlow];
        if (!_numericState) _numericState = [NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
        memcpy(_numericState.mutableBytes, _flowState.raw, MIN(_numericState.length, sizeof(_flowState.raw)));
        [self saveStoryToDirectory:directory];
        return nil;
    }
    dc_flow_result promptResult;
    dc_flow_prompt_route(&_flowState, 0, &promptResult);
    [self syncStoryFromFlow];
    if (!_numericState) _numericState = [NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
    memcpy(_numericState.mutableBytes, _flowState.raw, MIN(_numericState.length, sizeof(_flowState.raw)));
    [self saveStoryToDirectory:directory];
    return [self enterStoryChapter:_flowState.meta.chapter directory:directory];
}
- (NSString *)startGameSceneFromDirectory:(NSString *)directory {
    if(_gameScene)return nil;
    if(_gameAudio){
        [_gameAudio stopGameplayAudio];
        NSString *audioError=[_gameAudio prepareGameplayAudio];
        if(audioError)return audioError;
    }
    NSString *gameError=nil;
    BOOL resume=_resumeNextScene;_resumeNextScene=NO;
    _gameScene=[[DCGameScene alloc] initWithDirectory:directory renderer:_renderer chapter:_story.chapter
        mapSelector:_story.map stage:_story.stage stageProgress:_story.stage<DC_STORY_STAGES?_story.stages[_story.stage].progress:0
        sceneTypeOverride:_endingSceneTypeOverride resumeSavedPlayer:resume error:&gameError];
    if(!_gameScene)return gameError ?: @"Story scene initialization failed";
    _gameScene.transitionScene=_startupScene;
    if(_startupScene&&[_startupScene requestTransition:1 tick:0]!=DC_OK)return @"Story scene transition reset failed";
    [self ensureFlowState];
    if(_flowInitialized) {
        _flowState.meta.previous_type=_flowState.meta.scene_type;
        _flowState.meta.scene_type=(uint8_t)_gameScene.sceneType;
        _flowState.meta.chapter=(uint8_t)_story.chapter;
        _flowState.meta.map=(uint8_t)_story.map;_flowState.meta.stage=(uint8_t)_story.stage;
        [self syncFlowFlagsFromStory];
    }
    if(!_configuration)[self loadConfigurationFromDirectory:directory];
    if(_configuration)[_gameScene applyConfiguration:(const dc_config *)_configuration.bytes];
    _gameScene.secondaryViewVisible=!_secondaryViewDisabledSetting;
    _previousGameplayTouch=NO;
    _suppressGameplayTouch=YES;
    return nil;
}
- (NSString *)loadConfigurationFromDirectory:(NSString *)directory {
    NSString *path=[directory stringByAppendingPathComponent:@"gcd.cfg"];
    NSData *data=[NSData dataWithContentsOfFile:path];
    dc_config state;
    if(data.length>=DC_CONFIG_BYTES && dc_config_decode(data.bytes,data.length,&state)==DC_OK)
        _configuration=[NSData dataWithBytes:&state length:sizeof(state)];
    else {
        dc_config_default(&state);_configuration=[NSData dataWithBytes:&state length:sizeof(state)];
    }
    uint32_t secondary=1;
    if(dc_config_switch_value(&state,4,&secondary)==DC_OK)_secondaryViewDisabledSetting=(secondary==0);
    return nil;
}
- (NSString *)enterConfigSceneFromDirectory:(NSString *)directory {
    if(!_configuration)[self loadConfigurationFromDirectory:directory];
    uint32_t ownerType=_gameScene?(_gameScene.editMode?12:_gameScene.sceneType):(_introScene?3:(_endingScene?2:(_systemOwnerType?_systemOwnerType:1)));
    uint32_t ownerChapter=_introScene?_introScene.chapter:(_endingScene?24:(_systemOwnerType?_systemOwnerChapter:_story.chapter));
    NSString *error=nil;
    _configScene=[[DCConfigScene alloc] initWithDirectory:directory renderer:_renderer configuration:_configuration transition:_startupScene error:&error];
    if(!_configScene)return error?:@"Configuration page initialization failed";
    _systemOwnerType=ownerType;_systemOwnerChapter=ownerChapter;
    [_gameAudio suspendForSystemPage];
    return nil;
}
- (NSString *)enterSaveSceneFromDirectory:(NSString *)directory {
    uint32_t ownerType=_gameScene?(_gameScene.editMode?12:_gameScene.sceneType):(_introScene?3:(_endingScene?2:(_systemOwnerType?_systemOwnerType:1)));
    uint32_t ownerChapter=_introScene?_introScene.chapter:(_endingScene?24:(_systemOwnerType?_systemOwnerChapter:_story.chapter));
    NSString *error=nil;
    _saveScene=[[DCSaveScene alloc] initWithDirectory:directory renderer:_renderer transition:_startupScene
        ownerSceneType:ownerType chapter:ownerChapter error:&error];
    if(!_saveScene)return error?:@"Save page initialization failed";
    _systemOwnerType=ownerType;_systemOwnerChapter=ownerChapter;
    [_gameAudio suspendForSystemPage];
    return nil;
}
- (NSString *)enterDummySceneFromDirectory:(NSString *)directory owner:(uint32_t)owner {
    NSString *error=nil;
    _dummyScene=[[DCDummyScene alloc] initWithDirectory:directory renderer:_renderer transition:_startupScene error:&error];
    if(!_dummyScene)return error?:@"Dummy screen initialization failed";
    _dummyOwner=owner;
    return nil;
}
- (void)returnToTitleScene {
    [_gameAudio stopGameplayAudio];
    [_gameAudio stopExtraMusic];
    [_configScene detachRenderer];_configScene=nil;
    [_saveScene detachRenderer];_saveScene=nil;
    [_dummyScene detachRenderer];_dummyScene=nil;_dummyOwner=0;
    [_gameScene detachRenderer];_gameScene=nil;
    [_introScene detachRenderer];_introScene=nil;
    [_endingScene detachRenderer];_endingScene=nil;_endingSceneTypeOverride=0;
    _pendingBadgeStage=-1;_pendingBadgeIndex=-1;
    _systemOwnerType=0;_systemOwnerChapter=0;
    _titleStateInitialized=NO;_titleMenuInitialized=NO;_titleUnlocksLoaded=NO;
    _galleryMode=NO;_galleryViewingCG=NO;_galleryWaiting=NO;_galleryAction=0;
    if(_galleryTexture&&_renderer){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}
    _pregnancyChoiceActive=NO;_pregnancyChoiceWaiting=NO;_pregnancyChoiceTransitionRequested=NO;_pregnancyChoiceAction=0;
    _previousTitleTouch=NO;_previousGameplayTouch=NO;_suppressGameplayTouch=NO;
}
- (NSString *)handleIntroAuxiliaryFromDirectory:(NSString *)directory {
    uint32_t destination=_introScene.auxiliaryDestination;
    if(!destination)return nil;
    [_introScene consumeAuxiliaryDestination];
    if(destination==2)return [self enterConfigSceneFromDirectory:directory];
    if(destination==7)return [self enterSaveSceneFromDirectory:directory];
    if(destination==5)return [self enterDummySceneFromDirectory:directory owner:3];
    if(destination==6){
        [self returnToTitleScene];
        return nil;
    }
    return @"Unsupported original script system destination";
}
- (void)syncNumericState {
    if(!_numericState){_numericState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];dc_game_state_init(_numericState.mutableBytes,_numericState.length);}
    uint8_t *p=_numericState.mutableBytes;
    for(unsigned i=0;i<DC_STORY_STAGES;++i){size_t base=(size_t)i*0x2198;p[base+0]=(uint8_t)_story.stages[i].flag_a;p[base+1]=(uint8_t)_story.stages[i].flag_b;p[base+0x23]=(uint8_t)_story.stages[i].progress;}
}
- (NSString *)writeOriginalSaveSlot:(uint32_t)slot directory:(NSString *)directory {
    [self ensureFlowState];
    [self syncNumericState];
    if(_flowInitialized)memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
    dc_save_slot_meta meta=_flowInitialized?_flowState.meta:(dc_save_slot_meta){(uint8_t)_story.chapter,(uint8_t)(_gameScene?_gameScene.sceneType:1),
        (uint8_t)(_gameScene?_gameScene.sceneType:1),(uint8_t)_story.map,(uint8_t)_story.stage,0,0,0};
    meta.chapter=(uint8_t)(_introScene?_introScene.chapter:_story.chapter);meta.map=(uint8_t)_story.map;meta.stage=(uint8_t)_story.stage;
    if(_gameScene){meta.scene_type=(uint8_t)_gameScene.sceneType;meta.script_frame=254;}
    else if(_introScene){meta.scene_type=3;meta.script_frame=(uint8_t)MIN(_introScene.frame,253u);}
    else if(_systemOwnerType==2){meta.chapter=24;meta.scene_type=2;meta.script_frame=254;}
    char name[16];if(dc_save_slot_name(slot,name,sizeof(name))!=DC_OK)return @"Original save slot number rejected";
    NSMutableData *encoded=[NSMutableData dataWithLength:DC_SAVE_SLOT_BYTES];
    if(dc_save_slot_encode(_numericState.bytes,_numericState.length,&meta,encoded.mutableBytes,encoded.length)!=DC_OK)return @"Original save state encoding failed";
    NSString *saveDirectory=[directory stringByAppendingPathComponent:@"save"];
    [[NSFileManager defaultManager] createDirectoryAtPath:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    if(![encoded writeToFile:[saveDirectory stringByAppendingPathComponent:[NSString stringWithUTF8String:name]] options:NSDataWritingAtomic error:nil])return @"Original save slot write failed";
    [self saveStoryToDirectory:directory];
    _titleUnlocksLoaded=NO;
    return nil;
}
- (NSString *)resumeSystemOwnerAtTick:(uint32_t)tick directory:(NSString *)directory {
    uint32_t ownerType=_systemOwnerType;
    _systemOwnerType=0;
    if(_startupScene&&[_startupScene requestTransition:1 tick:tick]!=DC_OK)return @"System owner transition reset failed";
    if(_gameScene){[_gameScene resumeAtTick:tick];}
    else if(_introScene){[_introScene resumeFromAuxiliaryAtTick:tick];}
    else if(_endingScene){[_endingScene resumeFromTemporaryScreen];}
    else if(ownerType==2&&directory.length){
        NSString *endingError=[self enterStoryChapter:24 directory:directory];
        if(endingError)return endingError;
    } else if(ownerType==1){
        _titleStateInitialized=NO;_titleMenuInitialized=NO;_titleUnlocksLoaded=NO;
    }
    if(![_gameAudio resumeAfterSystemPage])return @"System audio resume failed";
    [_configScene detachRenderer];_configScene=nil;[_saveScene detachRenderer];_saveScene=nil;
    _previousGameplayTouch=NO;_previousTitleTouch=NO;return nil;
}
- (NSString *)loadSelectedOriginalSlot:(NSData *)slot directory:(NSString *)directory tick:(uint32_t)tick {
    if(!slot || slot.length<DC_SAVE_SLOT_BYTES)return @"Original load slot is unavailable";
    NSMutableData *state=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];dc_save_slot_meta meta={0};
    if(dc_save_slot_decode(slot.bytes,slot.length,state.mutableBytes,state.length,&meta)!=DC_OK)return @"Original load slot decode failed";
    const uint8_t *p=state.bytes;_numericState=state;
    memset(&_flowState,0,sizeof(_flowState));memcpy(_flowState.raw,state.bytes,MIN(state.length,sizeof(_flowState.raw)));_flowState.meta=meta;_flowInitialized=YES;
    _story.chapter=meta.chapter;_story.map=meta.map;_story.stage=meta.stage;_story.unlocked=(meta.chapter>=24)?1:0;_storyInitialized=YES;
    for(unsigned i=0;i<DC_STORY_STAGES;++i){size_t base=(size_t)i*0x2198;_story.stages[i].flag_a=p[base];_story.stages[i].flag_b=p[base+1];_story.stages[i].progress=p[base+0x23];}
    _systemOwnerType=0;
    _titleUnlocksLoaded=NO;
    [_saveScene detachRenderer];_saveScene=nil;
    [_introScene detachRenderer];_introScene=nil;
    [_gameScene detachRenderer];_gameScene=nil;
    [_endingScene detachRenderer];_endingScene=nil;
    _pendingBadgeStage=-1;_pendingBadgeIndex=-1;
    _pregnancyChoiceActive=NO;_pregnancyChoiceWaiting=NO;_pregnancyChoiceTransitionRequested=NO;_pregnancyChoiceAction=0;
    [_gameAudio stopTitleMusic];
    [_gameAudio stopGameplayAudio];
    if(meta.scene_type==13) {
        [self saveStoryToDirectory:directory];
        return [self enterPregnancyChoiceFromDirectory:directory];
    }
    BOOL isGameplaySave=(meta.scene_type>=4 && meta.scene_type<=7);
    if(!isGameplaySave) {
        NSString *playerPath=[directory stringByAppendingPathComponent:@"save/player.state"];
        [[NSFileManager defaultManager] removeItemAtPath:playerPath error:nil];
    }
    if(meta.chapter==24 && isGameplaySave && meta.map<=8 && meta.stage<=2) {
        _endingSceneTypeOverride=(meta.scene_type==7)?6:meta.scene_type;
        _resumeNextScene=YES;
        [self saveStoryToDirectory:directory];
        NSString *gameError=[self startGameSceneFromDirectory:directory];
        _endingSceneTypeOverride=0;
        if(gameError)return gameError;
        if(_gameScene)[_gameScene resumeAtTick:tick];
        return nil;
    }
    _resumeNextScene=isGameplaySave;
    NSString *error=[self enterStoryChapter:_story.chapter directory:directory];
    if(error)return error;
    if(_introScene&&meta.scene_type==3&&meta.script_frame>0&&meta.script_frame<254){
        NSString *introError=nil;
        DCIntroScene *resumed=[[DCIntroScene alloc] initWithDirectory:directory startChapter:_story.chapter
            numericState:_numericState savedFrame:meta.script_frame error:&introError];
        if(resumed){
            if(_configuration)[resumed applyConfiguration:_configuration];
            [_introScene detachRenderer];
            _introScene=resumed;
            [_introScene resumeAtTick:tick];
        }
    } else if(_introScene) {
        [_introScene resumeAtTick:tick];
    }
    if(_gameScene)[_gameScene resumeAtTick:tick];
    return nil;
}
- (NSString *)handleGameplayTransitionFromDirectory:(NSString *)directory {
    if(!_gameScene || !_gameScene.chapterEndAction)return nil;
    uint32_t action=_gameScene.chapterEndAction;
    if(action==2) {
        uint32_t wasChapter=_story.chapter;
        [self ensureFlowState];
        uint8_t aoiProgressBefore=_flowInitialized?_flowState.raw[0x23]:(uint8_t)_story.stages[0].progress;
        _pendingBadgeStage=-1;_pendingBadgeIndex=-1;
        if(wasChapter==24 && _flowInitialized && _gameScene.storyStage<DC_FLOW_STAGES) {
            uint8_t *stagePtr=_flowState.raw+(size_t)_gameScene.storyStage*DC_FLOW_STAGE_BYTES;
            if(_gameScene.sceneType==5 && _gameScene.watchClimaxElapsedMs>0) {
                uint32_t prevFastest=dc_flow_read32(stagePtr+0x30);
                if(prevFastest==0 || _gameScene.watchClimaxElapsedMs<prevFastest)
                    dc_write_word_le(stagePtr+0x30,_gameScene.watchClimaxElapsedMs);
            }
            if(stagePtr[0x23]!=2) {
                if(_gameScene.vibeNekoUsed)dc_flow_add16(stagePtr+0x16,1);
                if(_gameScene.vibeToriUsed)dc_flow_add16(stagePtr+0x18,1);
                if(_gameScene.accessoryToggled)dc_flow_add16(stagePtr+0x1c,1);
                if(_gameScene.outfitVariant==3)dc_flow_add16(stagePtr+0x2c,1);
            }
        }
        if(_story.chapter==24 && _gameScene.storyStage<DC_STORY_STAGES) {
            BOOL completed=(_gameScene.stageOutcomeA>0||_gameScene.stageOutcomeB>0||_gameScene.interactionCompleted);
            BOOL exerciseStory=[NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_STORY"] isEqualToString:@"1"];
            uint32_t stagesToUpdate[3]={_gameScene.storyStage,
                _flowInitialized?_flowState.meta.selector0:255u,
                _flowInitialized?_flowState.meta.selector1:255u};
            for(unsigned idx=0;idx<3;++idx) {
                uint32_t s=stagesToUpdate[idx];
                if(s>=DC_STORY_STAGES)continue;
                if(idx==0) {
                    if(_gameScene.stageOutcomeA>0)_story.stages[s].flag_a=1;
                    if(_gameScene.stageOutcomeB>0)_story.stages[s].flag_b=1;
                }
                if(exerciseStory && completed && _story.stages[s].progress<2)_story.stages[s].progress=2;
            }
            [self syncFlowFlagsFromStory];
            _titleUnlocksLoaded=NO;
        }
        if(wasChapter==24 && _flowInitialized && _gameScene.sceneType==6) {
            uint8_t savedStage=_flowState.meta.stage;
            uint32_t nightStages[3]={_gameScene.storyStage,_flowState.meta.selector0,_flowState.meta.selector1};
            uint32_t pos2Inc=MAX((uint32_t)_gameScene.stageOutcomeB,_gameScene.pos2SelectedCount);
            BOOL climaxed=(_gameScene.stageOutcomeA>0||_gameScene.stageOutcomeB>0);
            for(unsigned idx=0;idx<3;++idx) {
                uint32_t s=nightStages[idx];
                if(s>=DC_FLOW_STAGES)continue;
                _flowState.meta.stage=(uint8_t)s;
                dc_flow_night_commit(&_flowState,(uint32_t)MAX(0,_gameScene.stageOutcomeA),(uint32_t)MAX(0,_gameScene.stageOutcomeB));
                uint8_t *p=_flowState.raw+(size_t)s*DC_FLOW_STAGE_BYTES;
                if(p[0x23]!=2) {
                    if(s==0 && p[0x2a]==0 && p[0x22]<4 &&
                       (_flowState.raw[DC_FLOW_STAGE_BYTES+0x22]>3 || _flowState.raw[2*DC_FLOW_STAGE_BYTES+0x22]>3)) {
                        p[0x2a]=1;
                    }
                    if(_flowState.meta.script_frame==6 && p[0x29]==0)p[0x29]=1;
                    if(pos2Inc>0)dc_flow_add16(p+0x14,pos2Inc);
                    if(climaxed)dc_flow_add16(p+0x1a,1);
                    if(climaxed && _flowState.meta.map!=4 && _flowState.meta.map!=8 && _flowState.meta.map!=255)
                        dc_flow_add16(p+0x20,1);
                    int32_t newBadge=-1;
                    dc_flow_update_stage_badges(p,(uint8_t)s,&newBadge);
                    if(newBadge>=0 && _pendingBadgeIndex<0){_pendingBadgeStage=(int32_t)s;_pendingBadgeIndex=newBadge;}
                }
                if(p[0x22]==4 && (p[0x38]==0 || p[0x38]==1))p[0x38]=2;
                else if(p[0x22]==3 && p[0x38]==0)p[0x38]=1;
            }
            _flowState.meta.stage=savedStage;
            if(!_numericState)_numericState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
            memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
        }
        if(_story.chapter==24 && _gameScene.sceneType==6) {
            if(_flowInitialized) {
                uint32_t nightStages[3]={_gameScene.storyStage,_flowState.meta.selector0,_flowState.meta.selector1};
                for(unsigned idx=0;idx<3;++idx) {
                    uint32_t s=nightStages[idx];
                    if(s>=DC_FLOW_STAGES)continue;
                    uint8_t *p=_flowState.raw+(size_t)s*DC_FLOW_STAGE_BYTES;
                    if(_gameScene.flowLevel>1 && p[0]==0)p[0]=1;
                    if(_gameScene.flowFlagB && p[1]==0)p[1]=1;
                }
                if(_flowState.meta.selector0>=DC_FLOW_STAGES && _gameScene.storyStage<DC_FLOW_STAGES) {
                    uint8_t *p=_flowState.raw+(size_t)_gameScene.storyStage*DC_FLOW_STAGE_BYTES;
                    if(p[0x34]==0){p[0x34]=1;p[0x35]=5;p[0x36]=10;p[0x37]=6;}
                }
                BOOL aoiClimaxed=(_gameScene.stageOutcomeA>0||_gameScene.stageOutcomeB>0);
                BOOL isSingleAoi=(_gameScene.storyStage==0 && _flowState.meta.selector0>=DC_FLOW_STAGES);
                uint8_t aoiCycle=_flowState.raw[0x22];
                uint8_t manakaCycle=_flowState.raw[DC_FLOW_STAGE_BYTES+0x22];
                uint8_t yukoCycle=_flowState.raw[2*DC_FLOW_STAGE_BYTES+0x22];
                /* 00523890 lines 190-204 & 616-646: Aoi 2P Free-Mode Night Scene
                 * triggers Chapter 26 (14.txt) when Aoi is not yet at progress 2,
                 * reaches climax, and either Aoi is at cycle stage 3 or another
                 * heroine is visibly pregnant (>3) while Aoi is <4. */
                if(isSingleAoi && aoiClimaxed && aoiProgressBefore!=2 &&
                   (aoiCycle==3 || (aoiCycle<4 && (manakaCycle>3 || yukoCycle>3)))) {
                    _flowState.meta.chapter=26;
                    [self syncStoryFromFlow];
                } else {
                    uint32_t sched=0;
                    if(dc_flow_scheduler(&_flowState,&sched)==DC_OK) {
                        if(sched==1) {
                            return [self enterPregnancyChoiceFromDirectory:directory];
                        } else if(sched==2) {
                            _flowState.meta.chapter=25;
                        } else {
                            _flowState.meta.chapter=24;
                        }
                        [self syncStoryFromFlow];
                    }
                }
                if(!_numericState)_numericState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
                memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
            }
            [self saveStoryToDirectory:directory];
            return [self enterStoryChapter:_story.chapter directory:directory];
        }
        if(_flowInitialized && _gameScene.sceneType>=4 && _gameScene.sceneType<=6) {
            dc_flow_exit_metrics metrics={
                .level=_gameScene.flowLevel,
                .flag_b=_gameScene.flowFlagB,
                .count=_gameScene.flowCount,
                .outcome_a=_gameScene.stageOutcomeA,
                .outcome_b=_gameScene.stageOutcomeB};
            dc_flow_result flowResult;
            if(dc_flow_scene_exit(&_flowState,&metrics,&flowResult)==DC_OK) {
                if(wasChapter==24 && _gameScene.storyStage<DC_FLOW_STAGES) {
                    int32_t newBadge=-1;
                    dc_flow_update_stage_badges(_flowState.raw+(size_t)_gameScene.storyStage*DC_FLOW_STAGE_BYTES,(uint8_t)_gameScene.storyStage,&newBadge);
                    if(newBadge>=0 && _pendingBadgeIndex<0){_pendingBadgeStage=(int32_t)_gameScene.storyStage;_pendingBadgeIndex=newBadge;}
                }
                if(flowResult.destination_type==13) {
                    return [self enterPregnancyChoiceFromDirectory:directory];
                } else if(wasChapter<24 && flowResult.scheduler==0 && _flowState.meta.chapter==24) {
                    _flowState.meta.chapter=(uint8_t)(wasChapter+1);
                }
                [self syncStoryFromFlow];
                if(!_numericState)_numericState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
                memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
                [self saveStoryToDirectory:directory];
                return [self enterStoryChapter:_flowState.meta.chapter directory:directory];
            }
        }
        dc_story_outcomes outcomes={0};
        outcomes.a[_gameScene.storyStage]=_gameScene.stageOutcomeA;
        outcomes.b[_gameScene.storyStage]=_gameScene.stageOutcomeB;
        dc_story_plan plan;
        if(dc_story_advance(&_story,&outcomes,&plan)!=DC_OK)return @"Story chapter advance failed";
        _story=plan.next;_storyInitialized=YES;
        [self saveStoryToDirectory:directory];
        return [self enterStoryChapter:_story.chapter directory:directory];
    } else if(action==3) {
        [_gameScene consumeChapterEndAction];
        return [self enterConfigSceneFromDirectory:directory];
    } else if(action==4) {
        [_gameScene consumeChapterEndAction];
        return [self enterSaveSceneFromDirectory:directory];
    } else if(action==5) {
        [_gameScene consumeChapterEndAction];
        [_gameAudio suspendForSystemPage];
        return [self enterDummySceneFromDirectory:directory owner:6];
    } else if(action==6) {
        /* Edit presentation finished: return to the title. */
        [self returnToTitleScene];
        return nil;
    }
    [_gameScene consumeChapterEndAction];
    return nil;
}
- (NSString *)playPendingGameplayVoice {
    NSString *name=[_gameScene takePendingVoiceName];
    if (!name) return nil;
    if (!_gameAudio || ![_gameAudio playGameplayVoiceNamed:name])
        return [NSString stringWithFormat:@"Gameplay voice %@ did not start",name];
    return nil;
}
- (NSString *)playPendingGameplayEffect {
    uint32_t slot=[_gameScene takePendingEffectSlot];
    if(slot==UINT32_MAX)return nil;
    if(!_gameAudio||![_gameAudio playGameplaySlot:slot])
        return [NSString stringWithFormat:@"Original gameplay effect slot %u did not start",slot];
    return nil;
}
- (void)resetStory {
    _story=(dc_story_state){.chapter=0,.map=0xff,.stage=0xff};
    _story.stages[1].flag_a=1;
    _storyInitialized=YES;
    _flowInitialized=NO;
    _pendingBadgeStage=-1;_pendingBadgeIndex=-1;
    [self ensureFlowState];
    _numericState=nil;
    [self syncNumericState];
}
- (void)syncFlowFlagsFromStory {
    if(!_flowInitialized)return;
    for(unsigned i=0;i<DC_FLOW_STAGES;++i) {
        size_t base=(size_t)i*DC_FLOW_STAGE_BYTES;
        _flowState.raw[base+0]=(uint8_t)_story.stages[i].flag_a;
        _flowState.raw[base+1]=(uint8_t)_story.stages[i].flag_b;
        _flowState.raw[base+0x23]=(uint8_t)_story.stages[i].progress;
    }
}
- (void)syncStoryFromFlow {
    if(!_flowInitialized)return;
    _story.chapter=_flowState.meta.chapter;_story.map=_flowState.meta.map;_story.stage=_flowState.meta.stage;
    for(unsigned i=0;i<DC_FLOW_STAGES;++i) {
        size_t base=(size_t)i*DC_FLOW_STAGE_BYTES;
        _story.stages[i].flag_a=_flowState.raw[base+0]!=0;
        _story.stages[i].flag_b=_flowState.raw[base+1]!=0;
        _story.stages[i].progress=_flowState.raw[base+0x23];
    }
    _story.unlocked=(_flowState.meta.chapter>=24)?1:0;_storyInitialized=YES;
}
- (void)saveFlowStateToDirectory:(NSString *)directory {
    if(!_flowInitialized)return;
    NSMutableData *record=[NSMutableData dataWithLength:dcFlowPersistHeaderBytes+DC_GAME_STATE_BYTES];
    memcpy(record.mutableBytes,"PLFL",4);((uint8_t *)record.mutableBytes)[4]=1;
    memcpy((uint8_t *)record.mutableBytes+5,&_flowState.meta,sizeof(_flowState.meta));
    memcpy((uint8_t *)record.mutableBytes+dcFlowPersistHeaderBytes,_flowState.raw,DC_GAME_STATE_BYTES);
    NSString *saveDirectory=[directory stringByAppendingPathComponent:@"save"];
    [[NSFileManager defaultManager] createDirectoryAtPath:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [record writeToFile:[saveDirectory stringByAppendingPathComponent:@"flow.state"] options:NSDataWritingAtomic error:nil];
}
- (void)loadFlowStateFromDirectory:(NSString *)directory {
    NSData *record=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"save/flow.state"]];
    if(record.length<dcFlowPersistHeaderBytes+DC_GAME_STATE_BYTES||memcmp(record.bytes,"PLFL",4)!=0||((const uint8_t *)record.bytes)[4]!=1)return;
    memcpy(&_flowState.meta,(const uint8_t *)record.bytes+5,sizeof(_flowState.meta));
    memcpy(_flowState.raw,(const uint8_t *)record.bytes+dcFlowPersistHeaderBytes,DC_GAME_STATE_BYTES);_flowInitialized=YES;
}
- (void)ensureFlowState {
    if(_flowInitialized)return;
    dc_save_slot_meta meta={(uint8_t)_story.chapter,3,3,(uint8_t)_story.map,(uint8_t)_story.stage,255,255,254};
    if(dc_flow_state_init(&_flowState,&meta)==DC_OK) {
        _flowInitialized=YES;[self syncFlowFlagsFromStory];
    }
}
- (void)updateFlowMetaForChapter:(uint32_t)chapter profile:(const dc_story_chapter *)profile {
    [self ensureFlowState];if(!_flowInitialized||!profile)return;
    _flowState.meta.previous_type=_flowState.meta.scene_type;
    _flowState.meta.chapter=(uint8_t)chapter;
    _flowState.meta.scene_type=(uint8_t)profile->scene_type;
    _flowState.meta.map=(uint8_t)(profile->map>=0?profile->map:_story.map);
    _flowState.meta.stage=(uint8_t)(profile->stage>=0?profile->stage:_story.stage);
    _flowState.meta.selector0=255;_flowState.meta.selector1=255;_flowState.meta.script_frame=254;
    [self syncFlowFlagsFromStory];
}
- (void)loadStoryFromDirectory:(NSString *)directory {
    NSString *path=[directory stringByAppendingPathComponent:@"save/player.state"];
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(data.length>=DC_GAME_PLAYER_SAVE_BYTES+DC_STORY_SAVE_BYTES) {
        dc_story_state loaded;
        if(dc_story_load((const uint8_t *)data.bytes+DC_GAME_PLAYER_SAVE_BYTES,data.length-DC_GAME_PLAYER_SAVE_BYTES,&loaded)==DC_OK) {
            _story=loaded;_storyInitialized=YES;[self loadFlowStateFromDirectory:directory];
            if(_flowInitialized)[self syncStoryFromFlow];
            return;
        }
    }
    [self loadFlowStateFromDirectory:directory];
    if(_flowInitialized){[self syncStoryFromFlow];return;}
    /* Legacy position-only saves resume the first gameplay chapter. */
    [self resetStory];
    _story.chapter=3;_story.map=0;_story.stage=2;_storyInitialized=YES;
}
- (void)saveStoryToDirectory:(NSString *)directory {
    if(!_storyInitialized)return;
    NSString *path=[directory stringByAppendingPathComponent:@"save/player.state"];
    NSData *player=[NSData dataWithContentsOfFile:path];
    NSMutableData *record=[NSMutableData dataWithLength:DC_STORY_SAVE_BYTES];
    if(dc_story_save(&_story,record.mutableBytes,record.length)!=DC_OK)return;
    NSMutableData *combined=[NSMutableData dataWithLength:DC_GAME_PLAYER_SAVE_BYTES];
    if(player.length>=DC_GAME_PLAYER_SAVE_BYTES)
        memcpy(combined.mutableBytes,player.bytes,DC_GAME_PLAYER_SAVE_BYTES);
    [combined appendData:record];
    NSString *saveDirectory=[directory stringByAppendingPathComponent:@"save"];
    [[NSFileManager defaultManager] createDirectoryAtPath:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [combined writeToFile:path options:NSDataWritingAtomic error:nil];
    [self saveFlowStateToDirectory:directory];
}
- (NSString *)enterStoryChapter:(uint32_t)chapter directory:(NSString *)directory {
    dc_story_chapter profile;
    if(dc_story_chapter_profile(chapter,&profile)!=DC_OK)return @"Story chapter profile rejected";
    _story.chapter=chapter;
    if(profile.map>=0)_story.map=(uint32_t)profile.map;
    if(profile.stage>=0)_story.stage=(uint32_t)profile.stage;
    if(chapter==24) {
        _story.unlocked=1;
        for(unsigned i=0;i<DC_STORY_STAGES;++i)
            if(_story.stages[i].progress<1)_story.stages[i].progress=1;
        _titleUnlocksLoaded=NO;
    }
    _storyInitialized=YES;
    [self updateFlowMetaForChapter:chapter profile:&profile];
    [self saveStoryToDirectory:directory];
    /* Consume the completed script before installing its destination. Keeping
     * it here would re-enter this chapter on every subsequent draw. */
    [_gameAudio stopGameplayAudio];
    [_introScene detachRenderer];
    _introScene=nil;
    [_gameScene detachRenderer];
    _gameScene=nil;
    [_endingScene detachRenderer];
    _endingScene=nil;
    _endingSceneTypeOverride=0;
    if(profile.script>=0) {
        _resumeNextScene=NO;
        [self syncNumericState];
        if(_flowInitialized)memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
        NSString *introError=nil;
        _introScene=[[DCIntroScene alloc] initWithDirectory:directory startChapter:chapter
            numericState:_numericState savedFrame:0 error:&introError];
        if(!_introScene)return introError ?: @"Mid-story script entry failed";
        if(!_configuration)[self loadConfigurationFromDirectory:directory];
        if(_configuration)[_introScene applyConfiguration:_configuration];
        if(_startupScene&&[_startupScene requestTransition:1 tick:0]!=DC_OK)return @"Mid-story script transition reset failed";
    } else if(profile.scene==DC_STORY_SCENE_ENDING) {
        NSString *endingError=nil;
        _endingScene=[[DCEndingScene alloc] initWithDirectory:directory renderer:_renderer transition:_startupScene
            story:&_story error:&endingError];
        if(!_endingScene)return endingError?:@"Ending selector initialization failed";
        [_endingScene setPendingBadgeStage:_pendingBadgeStage badgeIndex:_pendingBadgeIndex];
        _pendingBadgeStage=-1;_pendingBadgeIndex=-1;
        _previousGameplayTouch=NO;_suppressGameplayTouch=YES;
    } else {
        NSString *gameError=[self startGameSceneFromDirectory:directory];
        if(gameError)return gameError;
        _previousGameplayTouch=NO;
        _suppressGameplayTouch=YES;
    }
    return nil;
}
- (BOOL)tryLoadExtraGalleryFromDirectory:(NSString *)directory {
    if (_extraSceneLoaded || !_renderer || directory.length == 0) return _extraSceneLoaded;
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"extra_base.ema", @"extra_Hcg.ema", @"extra_cg.ema", @"hanyo_gameend.ema", @"hanyo_title.ema"];
    });
    NSString *path = [directory stringByAppendingPathComponent:@"RPP_02.pp"];
    NSError *error = nil;
    DCArchive *archive = [[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!archive) return NO;
    uint32_t indices[5];
    for (uint32_t target = 0; target < 5; ++target) {
        indices[target] = UINT32_MAX;
        for (uint32_t i = 0; i < archive.entryCount; ++i) {
            if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:names[target]] == NSOrderedSame) {
                indices[target] = i;
                break;
            }
        }
        if (indices[target] == UINT32_MAX) return NO;
    }
    uintptr_t handles[5] = {0};
    for (uint32_t i = 0; i < 5; ++i) {
        DCDecodedImage *image = [archive decodeImageAtIndex:indices[i] inputLimit:8 * 1024 * 1024
            outputLimit:64 * 1024 * 1024 error:&error];
        if (!image || dc_vk_sprite_upload(_renderer, image.width, image.height, image.rgba.bytes,
                image.rgba.length, &handles[i]) != DC_OK) {
            for (uint32_t j = 0; j < i; ++j) dc_vk_sprite_remove_texture(_renderer, handles[j]);
            return NO;
        }
    }
    memcpy(_extraTextures, handles, sizeof(handles));
    _extraSceneLoaded = YES;
    return YES;
}
- (void)loadGalleryImageFromDirectory:(NSString *)directory {
    if(_galleryTexture){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}
    NSError *reason=nil;
    static NSString *const kExtraCGNames[17]={
        @"cg07.ema",@"cg08.ema",@"cg13.ema",@"cg14.ema",@"cg16.ema",@"cg17.ema",
        @"cg01.ema",@"cg02.ema",@"cg03.ema",@"cg04.ema",@"cg06.ema",@"cg09.ema",
        @"cg10.ema",@"cg11.ema",@"cg12.ema",@"cg15.ema",@"cg18.ema"
    };
    DCArchive *rpp02=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if(rpp02 && rpp02.entryCount) {
        NSString *cgName=kExtraCGNames[_galleryIndex%17u];
        for(uint32_t i=0;i<rpp02.entryCount;++i) {
            if([[rpp02 asciiNameAtIndex:i] caseInsensitiveCompare:cgName]!=NSOrderedSame)continue;
            DCDecodedImage *image=[rpp02 decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];
            if(image) {
                dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&_galleryTexture);
                return;
            }
            break;
        }
    }
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"rpsp_00.pp"]] error:&reason];
    if(!archive || !archive.entryCount)return;
    for(uint32_t attempt=0;attempt<2;++attempt) {
        NSString *name=[NSString stringWithFormat:@"M_c%03uN.ema",1+_galleryIndex];
        for(uint32_t i=0;i<archive.entryCount;++i) {
            if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]!=NSOrderedSame)continue;
            DCDecodedImage *image=[archive decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];
            if(!image)return;
            dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&_galleryTexture);
            return;
        }
        _galleryIndex=0;
    }
}
- (void)detachRendererOnly {
    [_gameScene detachRenderer];
    [_introScene detachRenderer];
    [_configScene detachRenderer];
    [_saveScene detachRenderer];
    [_dummyScene detachRenderer];
    [_endingScene detachRenderer];
    [_startupScene detachRenderer];
    dc_vk_sprite_destroy(_renderer);
    _renderer = NULL;
    _texture = 0;
    memset(_titleTextures, 0, sizeof(_titleTextures));
    memset(_titleWidths, 0, sizeof(_titleWidths));
    memset(_titleHeights, 0, sizeof(_titleHeights));
    _titleSceneLoaded = NO;
    memset(_extraTextures, 0, sizeof(_extraTextures));
    _extraSceneLoaded = NO;
    memset(_pregnancyChoiceTextures, 0, sizeof(_pregnancyChoiceTextures));
    _pregnancyChoiceLoaded = NO;
    _galleryTexture = 0;
    _lastTitleScan = 0;
    _width = _height = 0;
}
- (void)destroyRenderer {
    [self detachRendererOnly];
    _galleryMode=NO;_galleryViewingCG=NO;_galleryWaiting=NO;_galleryAction=0;_galleryIndex=0;
    _pregnancyChoiceActive=NO;_pregnancyChoiceWaiting=NO;_pregnancyChoiceTransitionRequested=NO;_pregnancyChoiceAction=0;
    _gameScene = nil;
    _configScene=nil;_saveScene=nil;_numericState=nil;_configuration=nil;
    _dummyScene=nil;_dummyOwner=0;_endingScene=nil;_endingSceneTypeOverride=0;
    _previousGameplayTouch = NO;
    _suppressGameplayTouch = NO;
    _presentedScene = DCVulkanSpriteSceneDiagnostic;
    _diagnosticTickInitialized = NO;
    _diagnosticAnimationAdvanced = NO;
    _diagnosticMaterialAdvanced = NO;
    _diagnosticPoseAdvanced = NO;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (dispatch_get_specific(&dcRenderQueueKey)) [self destroyRenderer];
    else dispatch_sync(_renderQueue, ^{ [self destroyRenderer]; });
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(ceil(self.bounds.size.width * scale), ceil(self.bounds.size.height * scale));
}
#if DEBUG
- (NSString *)drawRenderProbeFromDirectory:(NSString *)directory {
    static const uint32_t chapters[]={3,5,7,14,21};
    const size_t cases=sizeof(chapters)/sizeof(chapters[0]);
    if(_probeCase>=cases)return nil;
    if(!_probeCaptures)_probeCaptures=[NSMutableDictionary dictionary];
    if(_probeFrame==0||!_gameScene) {
        _probeFrame=0;[self resetStory];_resumeNextScene=NO;
        NSString *error=[self enterStoryChapter:chapters[_probeCase] directory:directory];
        if(error)return error;
    }
    NSString *sample=nil;
    if(_probeFrame==0)sample=@"idle";
    else if(_probeFrame==16)sample=@"interaction";
    else if(_probeFrame==38)sample=@"restored";
    if(sample)[_gameScene requestRenderCapture:[NSString stringWithFormat:@"render-c%02u-%@.png",chapters[_probeCase],sample]];
    dc_pad_frame controller={0};
    if(_probeFrame==8)controller.buttons=controller.pressed=DC_PAD_A;
    // A deterministic render checkpoint, separate from the visible-touch
    // playability test. Slow GPU readback cannot skip the interaction sample.
    NSString *error=[_gameScene drawAtTick:_probeFrame*33 inputX:0 inputY:0 touching:NO
        controller:controller pcInput:(dc_pc_frame){0} width:_width height:_height];
    if(error)return error;
    NSDictionary *capture=_gameScene.lastRenderCapture;
    NSString *file=capture[@"file"];
    if(sample&&file) {
        NSMutableDictionary *record=[capture mutableCopy];
        record[@"sample"]=sample;
        _probeCaptures[file]=record;
        _probeWorkerStatus=[NSString stringWithFormat:@"chapter=%@ map=%@ sample=%@ pixels=%@ file=%@",
            record[@"chapter"],record[@"map"],record[@"sample"],record[@"actor_visible_pixels"],file];
    }
    _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
    if(++_probeFrame>42) {
        ++_probeCase;_probeFrame=0;
        if(_probeCase==cases) {
            NSDictionary *report=@{@"kind":@"deterministic_render_checkpoints",
                @"playability_certification":@NO,@"captures":_probeCaptures.allValues};
            NSError *reason=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&reason];
            NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            if(!data||![data writeToURL:[documents URLByAppendingPathComponent:@"render-probe.json"] options:NSDataWritingAtomic error:&reason])
                return reason.localizedDescription?:@"Render probe report could not be saved";
            _probeWorkerStatus=@"completed captures=15";
        }
    }
    return nil;
}
#endif
- (NSString *)drawAtX:(float)x y:(float)y time:(double)time
                layer:(CAMetalLayer *)layer width:(uint32_t)width height:(uint32_t)height
         dataDirectory:(NSString *)directory touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput {
    // Coordinates, buttons, all keys and motion arrive in one immutable frame.
    if (pcInput.pointer_active) {
        x=pcInput.x*2-1; y=1-pcInput.y*2;
        touching=(pcInput.mouse[0]&1)!=0;
    } else {
        if (!touching && (pcInput.active || pcInput.mouse[0] || pcInput.mouse[1] || pcInput.mouse[2] || pcInput.wheel || (x==0.0f && y==0.0f))) {
            x=pcInput.x*2-1; y=1-pcInput.y*2;
        }
        if (pcInput.mouse[0]&1u) {
            /* A virtual Z/left-click is still a game tap even when no physical
             * pointer is connected. Touchscreen coordinates remain authoritative
             * for simultaneous finger input. */
            touching=YES;
        }
    }
    dc_merge_pc_actions(pcInput,&controller);
    if (!width || !height) return @"CAMetalLayer has empty drawable size";
    if (_renderer && (_width != width || _height != height)) [self detachRendererOnly];
    if (!_renderer) {
        dc_vk_sprite_config config = {.width = width, .height = height, .max_textures = 1024, .initial_filter = 2,
            .vertex_spirv = dc_sprite_vert_spv, .vertex_spirv_bytes = sizeof(dc_sprite_vert_spv),
            .fragment_spirv = dc_sprite_frag_spv, .fragment_spirv_bytes = sizeof(dc_sprite_frag_spv),
            .metal_layer = (__bridge void *)layer};
        char error[512];
        if (dc_vk_sprite_create(&config, &_renderer, error, sizeof(error)) != DC_OK)
            return [NSString stringWithUTF8String:error];
        dc_xx *model = NULL;
        dc_image_info imageInfo;
        uint8_t checker[16];
        dc_status fixtureStatus = dc_xx_open(dc_diagnostic_xx, sizeof(dc_diagnostic_xx), &model);
        if (fixtureStatus == DC_OK)
            fixtureStatus = dc_xx_image_decode(model, 0, checker, sizeof(checker), &imageInfo);
        dc_xx_close(model);
        if (fixtureStatus != DC_OK || imageInfo.width != 2 || imageInfo.height != 2) {
            [self destroyRenderer];
            return [NSString stringWithFormat:@"Native XX fixture rejected: %d", fixtureStatus];
        }
        if (dc_vk_sprite_upload(_renderer, imageInfo.width, imageInfo.height, checker, sizeof(checker), &_texture) != DC_OK) {
            NSString *message = [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
            [self detachRendererOnly];
            return message;
        }
        dc_vk_sprite_info info;
        dc_vk_sprite_get_info(_renderer, &info);
        _deviceName = [NSString stringWithUTF8String:info.device_name];
        _width = width; _height = height;
        if (_startupScene) {
            NSString *startupError = [_startupScene attachRenderer:_renderer];
            if (startupError) return startupError;
        }
        if (_gameScene) {
            NSString *gameError = [_gameScene attachRenderer:_renderer];
            if (gameError) return gameError;
        }
        if (_configScene) {
            NSString *configError = [_configScene attachRenderer:_renderer];
            if (configError) return configError;
        }
        if (_saveScene) {
            NSString *saveError = [_saveScene attachRenderer:_renderer];
            if (saveError) return saveError;
        }
        if (_dummyScene) {
            NSString *dummyError = [_dummyScene attachRenderer:_renderer];
            if (dummyError) return dummyError;
        }
        if (_endingScene) {
            NSString *endingError = [_endingScene attachRenderer:_renderer];
            if (endingError) return endingError;
        }
    }
    if (!_startupScene && directory.length && CACurrentMediaTime() - _lastStartupScan >= 1) {
        _lastStartupScan = CACurrentMediaTime();
        NSFileManager *files = NSFileManager.defaultManager;
        if ([files fileExistsAtPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] &&
            [files fileExistsAtPath:[directory stringByAppendingPathComponent:@"RPP_17.pp"]]) {
            NSString *error = nil;
            _startupScene = [[DCStartupScene alloc] initWithDirectory:directory renderer:_renderer error:&error];
            if (!_startupScene) return error ?: @"Startup resources could not be loaded";
        }
    }
#if DEBUG
    if([NSProcessInfo.processInfo.environment[@"PORTLAB_RENDER_PROBE"] isEqualToString:@"1"]&&directory.length)
        return [self drawRenderProbeFromDirectory:directory];
#endif
    if (_startupScene && !_startupScene.finished) {
        double milliseconds = time * 1000.0;
        if (!isfinite(milliseconds) || milliseconds < 0) return @"Invalid startup animation time";
        uint32_t tick = (uint32_t)fmod(milliseconds, 4294967296.0);
        BOOL startupTouch = touching || dc_gamepad_pointer_contact_active() ||
            (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS)) ||
            pcInput.keys[0x1c]==1 || pcInput.keys[0x1c]==3 || pcInput.keys[0x39]==1 || pcInput.keys[0x39]==3;
        NSString *error = [_startupScene drawAtTick:tick touching:startupTouch width:_width height:_height];
        if (error) return error;
        if (_startupScene.cardReady)
            _presentedScene = _startupScene.card == 1 ? DCVulkanSpriteSceneStartupWarning : DCVulkanSpriteSceneStartupCard;
        else _presentedScene = DCVulkanSpriteSceneStartupTransition;
        ++_presentedFrames;
        return nil;
    }
    BOOL titleReady = _startupScene.finished && [self tryLoadTitleSceneFromDirectory:directory];
    BOOL showTitle = titleReady && !_gameScene;
    if (_startupScene.finished && !titleReady) return @"Startup completed but title resources are unavailable";
    double sceneMilliseconds=time*1000.0;
    if(!isfinite(sceneMilliseconds) || sceneMilliseconds<0)return @"Invalid scene animation time";
    uint32_t sceneTick=(uint32_t)fmod(sceneMilliseconds,4294967296.0);
    if(_dummyScene) {
        NSString *failure=[_dummyScene drawAtTick:sceneTick pcInput:pcInput width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        if(_dummyScene.action){
            [_dummyScene detachRenderer];_dummyScene=nil;
            if(_dummyOwner==1)[_configScene resumeFromTemporaryScreen];
            else if(_dummyOwner==2)[_saveScene resumeFromTemporaryScreen];
            else if(_dummyOwner==3){
                if(_startupScene)[_startupScene requestTransition:4 tick:sceneTick];
                [_introScene resumeFromAuxiliaryAtTick:sceneTick];
            }
            else if(_dummyOwner==4){_titleStateInitialized=NO;_titleMenuInitialized=NO;_previousTitleTouch=NO;}
            else if(_dummyOwner==5){[_endingScene resumeFromTemporaryScreen];}
            else if(_dummyOwner==6){
                if(_startupScene)[_startupScene requestTransition:4 tick:sceneTick];
                [_gameScene resumeAtTick:sceneTick];
                [_gameAudio resumeAfterSystemPage];
            } else if(_dummyOwner==7){
                _pregnancyChoiceWaiting=YES;_pregnancyChoiceTransitionRequested=NO;_pregnancyChoiceAction=0;
                _previousGameplayTouch=NO;
            } else if(_dummyOwner==8){
                if(_startupScene)[_startupScene requestTransition:4 tick:sceneTick];
                [_gameAudio resumeAfterSystemPage];
                _galleryWaiting=YES;_galleryAction=0;_previousTitleTouch=NO;
            }
            _dummyOwner=0;
        }
        return nil;
    }
    if(_pregnancyChoiceActive) {
        if(![self tryLoadPregnancyPromptFromDirectory:directory]) {
            _pregnancyChoiceActive=NO;
            dc_flow_result promptResult;
            dc_flow_prompt_route(&_flowState,0,&promptResult);
            [self syncStoryFromFlow];
            if(!_numericState)_numericState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
            memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
            [self saveStoryToDirectory:directory];
            return [self enterStoryChapter:_flowState.meta.chapter directory:directory];
        }
        if(!_pregnancyChoiceTransitionRequested) {
            if(_startupScene && [_startupScene requestTransition:4 tick:sceneTick]!=DC_OK)
                return @"Pregnancy prompt entry transition failed";
            _pregnancyChoiceTransitionRequested=YES;
        }
        uint32_t transitionReady=1;
        if(_startupScene && [_startupScene queryTransitionReady:&transitionReady]!=DC_OK)
            return @"Pregnancy prompt transition query failed";
        if(_pregnancyChoiceWaiting) {
            if(_pregnancyChoiceAction==0 && transitionReady) {
                _pregnancyChoiceWaiting=NO;
            } else if(_pregnancyChoiceAction>0 && transitionReady && !_gameAudio.selectionBusy) {
                uint32_t choice=_pregnancyChoiceAction-1;
                _pregnancyChoiceActive=NO;_pregnancyChoiceWaiting=NO;_pregnancyChoiceTransitionRequested=NO;_pregnancyChoiceAction=0;
                dc_flow_result promptResult;
                if(dc_flow_prompt_route(&_flowState,choice,&promptResult)!=DC_OK)
                    return @"Pregnancy prompt routing failed";
                [self syncStoryFromFlow];
                if(!_numericState)_numericState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
                memcpy(_numericState.mutableBytes,_flowState.raw,MIN(_numericState.length,sizeof(_flowState.raw)));
                [self saveStoryToDirectory:directory];
                return [self enterStoryChapter:_flowState.meta.chapter directory:directory];
            }
        }
        float scale=fminf((float)_width/1024.0f,(float)_height/768.0f);
        float offsetX=((float)_width-1024.0f*scale)*0.5f;
        float offsetY=((float)_height-768.0f*scale)*0.5f;
        float screenX=(x+1.0f)*0.5f*_width;
        float screenY=(1.0f-y)*0.5f*_height;
        float gameX=(screenX-offsetX)/scale;
        float gameY=(screenY-offsetY)/scale;
        BOOL promptTouch=touching;
        if(_suppressGameplayTouch){promptTouch=NO;_suppressGameplayTouch=NO;}
        if(!_pregnancyChoiceWaiting) {
            if(pcInput.keys[1]==3) {
                if(_startupScene && [_startupScene requestTransition:3 tick:sceneTick]!=DC_OK)
                    return @"Pregnancy prompt dummy transition failed";
                return [self enterDummySceneFromDirectory:directory owner:7];
            }
            int32_t menuResult=-1,menuRow=-1;
            if(pcInput.active || promptTouch || _previousGameplayTouch) {
                dc_menu_button buttons[2]={
                    {.x=560,.y=400,.width=88,.height=48,.disabled=0},
                    {.x=712,.y=400,.width=88,.height=48,.disabled=0}
                };
                uint8_t input=pcInput.active?pcInput.mouse[0]:(promptTouch?(_previousGameplayTouch?1:3):(_previousGameplayTouch?2:0));
                if(input==3) {
                    int32_t hoverResult;
                    if(dc_menu_step(&_pregnancyChoiceMenu,buttons,2,(int32_t)gameX,(int32_t)gameY,1,0,&hoverResult)!=DC_OK)
                        return @"Pregnancy prompt hover failed";
                }
                int32_t result=-1;
                if(dc_menu_step(&_pregnancyChoiceMenu,buttons,2,(int32_t)gameX,(int32_t)gameY,1,input,&result)!=DC_OK)
                    return @"Pregnancy prompt menu step failed";
                _pregnancyChoiceHover=_pregnancyChoiceMenu.active?_pregnancyChoiceMenu.hover:-1;
                menuResult=result;menuRow=_pregnancyChoiceMenu.hover;
            }
            uint64_t prevPad=DC_PAD_LEFT|DC_PAD_UP|(UINT64_C(1)<<20)|(UINT64_C(1)<<17);
            uint64_t nextPad=DC_PAD_RIGHT|DC_PAD_DOWN|(UINT64_C(1)<<18)|(UINT64_C(1)<<19);
            if(controller.pressed&(prevPad|nextPad|DC_PAD_A|DC_PAD_PLUS)) {
                if(controller.pressed&(prevPad|nextPad))
                    _pregnancyChoiceControllerRow=(_pregnancyChoiceControllerRow+1)%2;
                _pregnancyChoiceHover=_pregnancyChoiceControllerRow;
                menuRow=_pregnancyChoiceControllerRow;
                menuResult=(controller.pressed&(DC_PAD_A|DC_PAD_PLUS))?1:3;
            }
            if([NSProcessInfo.processInfo.environment[@"PORTLAB_EXERCISE_STORY"] isEqualToString:@"1"] && promptTouch && !_previousGameplayTouch && menuResult!=1) {
                _pregnancyChoiceHover=0;menuRow=0;menuResult=1;
            }
            if(menuResult==1 && (menuRow==0 || menuRow==1)) {
                if(_gameAudio && ![_gameAudio playMenuSelection])return @"Pregnancy prompt selection audio failed";
                if(_startupScene && [_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)
                    return @"Pregnancy prompt exit transition failed";
                _pregnancyChoiceAction=(uint32_t)(menuRow+1);
                _pregnancyChoiceWaiting=YES;
            }
        }
        _previousGameplayTouch=promptTouch;
        dc_vk_sprite_item promptDraws[4]={0};
        size_t promptDrawCount=0;
        promptDraws[promptDrawCount++]=(dc_vk_sprite_item){
            .texture=_pregnancyChoiceTextures[1],.blend_mode=3,
            .pose={.width=1024.0f*scale,.height=768.0f*scale,.x=offsetX,.y=offsetY,.z=0.5f,
                   .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1}
        };
        if(_pregnancyChoiceHover==0 || _pregnancyChoiceHover==1) {
            float btnX=(_pregnancyChoiceHover==0)?560.0f:712.0f;
            promptDraws[promptDrawCount++]=(dc_vk_sprite_item){
                .texture=_pregnancyChoiceTextures[2+(uint32_t)_pregnancyChoiceHover],.blend_mode=3,
                .pose={.width=88.0f*scale,.height=48.0f*scale,.x=offsetX+btnX*scale,.y=offsetY+400.0f*scale,.z=0.5f,
                       .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1}
            };
        }
        promptDraws[promptDrawCount++]=(dc_vk_sprite_item){
            .texture=_pregnancyChoiceTextures[0],.blend_mode=3,
            .pose={.width=64.0f*scale,.height=64.0f*scale,.x=offsetX+(gameX-6.4f)*scale,.y=offsetY+(gameY-6.4f)*scale,.z=0.5f,
                   .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1}
        };
        NSString *promptFailure=[_startupScene drawSprites:promptDraws count:promptDrawCount tick:sceneTick width:_width height:_height];
        if(promptFailure)return promptFailure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        return nil;
    }
    if(_configScene) {
        NSString *failure=[_configScene drawAtTick:sceneTick pcInput:pcInput width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        uint32_t action=_configScene.action;
        if(action) {
            if(_configScene.persistOnDeparture) {
                NSData *settings=_configScene.configuration;
                if(settings) {
                    _configuration=settings;
                    [settings writeToFile:[directory stringByAppendingPathComponent:@"gcd.cfg"] options:NSDataWritingAtomic error:nil];
                    uint32_t secondary=1;
                    if(settings.length>=sizeof(dc_config)&&dc_config_switch_value((const dc_config *)settings.bytes,4,&secondary)==DC_OK)
                        _secondaryViewDisabledSetting=(secondary==0);
                    if(_gameScene)[_gameScene applyConfiguration:(const dc_config *)settings.bytes];
                    if(_introScene)[_introScene applyConfiguration:settings];
                    [_gameAudio applyConfiguration:settings];
                }
            }
            if(action==1)return [self resumeSystemOwnerAtTick:sceneTick directory:directory];
            if(action==2||action==4){[self returnToTitleScene];return nil;}
            if(action==3){[_configScene detachRenderer];_configScene=nil;return [self enterSaveSceneFromDirectory:directory];}
            if(action==5)return [self enterDummySceneFromDirectory:directory owner:1];
        }
        return nil;
    }
    if(_saveScene) {
        NSString *failure=[_saveScene drawAtTick:sceneTick pcInput:pcInput width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        if(_saveScene.saveRequested) {
            NSString *saveError=[self writeOriginalSaveSlot:_saveScene.selectedSlot directory:directory];
            if(saveError)return saveError;[_saveScene consumeSaveRequest];
        }
        uint32_t action=_saveScene.action;
        if(action) {
            if(action==1)return [self resumeSystemOwnerAtTick:sceneTick directory:directory];
            if(action==2||action==4){[self returnToTitleScene];return nil;}
            if(action==3){[_saveScene detachRenderer];_saveScene=nil;return [self enterConfigSceneFromDirectory:directory];}
            if(action==5)return [self loadSelectedOriginalSlot:_saveScene.selectedSlotData directory:directory tick:sceneTick];
            if(action==6)return [self enterDummySceneFromDirectory:directory owner:2];
        }
        return nil;
    }
    if(_endingScene) {
        NSString *failure=[_endingScene drawAtTick:sceneTick pcInput:pcInput width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        if(_endingScene.action==2||_endingScene.action==4){
            [self returnToTitleScene];
        } else if(_endingScene.action==3||_endingScene.action==5){
            uint32_t action=_endingScene.action;
            [_endingScene pause];
            NSString *pageError=action==3?[self enterConfigSceneFromDirectory:directory]:
                [self enterSaveSceneFromDirectory:directory];
            if(pageError)return pageError;
        } else if(_endingScene.action==6){
            NSString *dummyError=[self enterDummySceneFromDirectory:directory owner:5];
            if(dummyError)return dummyError;
        } else if(_endingScene.routeReady){
            static const uint32_t maps[7]={0,1,3,4,5,7,8};
            uint32_t category=_endingScene.category;
            _story.map=maps[_endingScene.mapIndex];_story.chapter=24;
            uint32_t stage=_endingScene.firstStage<=2?_endingScene.firstStage:0;
            _story.stage=category==5?2:(2-stage);
            [self ensureFlowState];
            if(_flowInitialized) {
                _flowState.meta.chapter=24;
                _flowState.meta.scene_type=2;
                dc_flow_selection sel={
                    .category=category,
                    .map_index=_endingScene.mapIndex,
                    .stage_mask=_endingScene.stageMask,
                    .first=_endingScene.firstStage,
                    .second=_endingScene.secondStage};
                dc_flow_result routeResult;
                if(dc_flow_selector_route(&_flowState,&sel,&routeResult)==DC_OK) {
                    _story.map=_flowState.meta.map;
                    _story.stage=_flowState.meta.stage;
                }
            }
            _endingSceneTypeOverride=category==0?4:(category==1?5:6);
            [_endingScene detachRenderer];_endingScene=nil;
            [self saveStoryToDirectory:directory];
            NSString *gameError=[self startGameSceneFromDirectory:directory];
            if(gameError)return gameError;
            _endingSceneTypeOverride=0;
            _suppressGameplayTouch=YES;
        }
        return nil;
    }
    if(_gameScene && (controller.pressed&DC_PAD_MINUS)) {
        [self returnToTitleScene];
        showTitle=titleReady;
    }
    if(_introScene) {
        if(_introScene.completed) {
            if(_introScene) {
                uint32_t pending=_introScene.pendingChapter;
                if(pending>=DC_STORY_CHAPTERS) {
                    /* Script departed to title (e.g., bad ending 25/26 or quit). */
                    [self returnToTitleScene];
                    _presentedScene=DCVulkanSpriteSceneGameComplete;
                    ++_presentedFrames;
                    return nil;
                } else {
                    if(pending==24) {
                        /* Original end-of-script dispatcher: entering the ending
                           chapter unlocks all three stage progress flags. */
                        _story.unlocked=1;
                        for(uint32_t i=0;i<DC_STORY_STAGES;++i)
                            if(_story.stages[i].progress<1)_story.stages[i].progress=1;
                        _storyInitialized=YES;
                        _titleUnlocksLoaded=NO;
                        [self saveStoryToDirectory:directory];
                    }
                    NSString *enterError=[self enterStoryChapter:pending directory:directory];
                    if(enterError)return enterError;
                    if(_introScene) {
                        BOOL introTouch = touching || dc_gamepad_pointer_contact_active() ||
                            (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS)) ||
                            pcInput.keys[0x1c]==1 || pcInput.keys[0x1c]==3 || pcInput.keys[0xd0]==1 || pcInput.keys[0xd0]==3;
                        [_introScene setFastForward:((pcInput.keys[0x1d]&1)!=0 || (pcInput.keys[0x9d]&1)!=0)];
                        NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
                            touching:introTouch width:_width height:_height];
                        if(failure)return failure;
                        NSString *auxiliaryFailure=[self handleIntroAuxiliaryFromDirectory:directory];
                        if(auxiliaryFailure)return auxiliaryFailure;
                        if(!_introScene||_configScene||_saveScene||_dummyScene)return nil;
                        _presentedScene=DCVulkanSpriteSceneIntro;++_presentedFrames;return nil;
                    }
                    /* A scene chapter replaced the intro; draw it below. */
                }
            }
        }
        if(_introScene) {
        if(pcInput.keys[0x3b]==3)[_introScene requestAuxiliary:2 transition:_startupScene tick:sceneTick];
        else if(pcInput.keys[0x3c]==3||pcInput.keys[0x1f]==3)[_introScene requestAuxiliary:7 transition:_startupScene tick:sceneTick];
        else if(pcInput.keys[1]==3)[_introScene requestAuxiliary:5 transition:_startupScene tick:sceneTick];
        if(pcInput.keys[0x2f]==3||pcInput.keys[0x39]==3||pcInput.mouse[1]==3)[_introScene toggleWindowHidden];
        [_introScene setFastForward:((pcInput.keys[0x1d]&1)!=0 || (pcInput.keys[0x9d]&1)!=0)];
        BOOL introTouch = touching || dc_gamepad_pointer_contact_active() ||
            (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS)) ||
            pcInput.keys[0x1c]==1 || pcInput.keys[0x1c]==3 || pcInput.keys[0xd0]==1 || pcInput.keys[0xd0]==3;
        NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
            touching:introTouch width:_width height:_height];
        if(failure)return failure;
        NSString *auxiliaryFailure=[self handleIntroAuxiliaryFromDirectory:directory];
        if(auxiliaryFailure)return auxiliaryFailure;
        if(!_introScene||_configScene||_saveScene||_dummyScene)return nil;
        _presentedScene=DCVulkanSpriteSceneIntro;++_presentedFrames;return nil;
        }
    }
    /* A completed script may have installed a game scene during this draw. */
    showTitle=titleReady && !_gameScene;
    dc_vk_sprite_item draws[8] = {0};
    size_t drawCount = 0;
    BOOL animationMoved = NO;
    BOOL materialMoved = NO;
    BOOL poseMoved = NO;
    if (showTitle) {
        if (!_titleUnlocksLoaded) {
            _editUnlocked=NO;_extraUnlocked=NO;
            NSString *gameRoot=[directory stringByDeletingLastPathComponent];
            NSString *docsRoot=[gameRoot stringByDeletingLastPathComponent];
            NSMutableArray<NSString *> *saveDirs=[NSMutableArray array];
            for(NSString *candidate in @[
                [directory stringByAppendingPathComponent:@"save"] ?: @"",
                [gameRoot stringByAppendingPathComponent:@"save"] ?: @"",
                [gameRoot stringByAppendingPathComponent:@"saves"] ?: @"",
                [docsRoot stringByAppendingPathComponent:@"save"] ?: @"",
                [docsRoot stringByAppendingPathComponent:@"saves"] ?: @"",
                docsRoot ?: @""
            ]) {
                if(candidate.length && ![saveDirs containsObject:candidate])[saveDirs addObject:candidate];
            }
            for (NSString *saveDir in saveDirs) {
                for (uint32_t slot=0;slot<80;++slot) {
                    NSString *name=[NSString stringWithFormat:@"RP_%02u.sav",slot];
                    NSString *path=[saveDir stringByAppendingPathComponent:name];
                    if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
                    NSError *saveError=nil;
                    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:&saveError];
                    if(!attributes || [attributes[NSFileSize] unsignedLongLongValue]<DC_SAVE_RECORD_BYTES) continue;
                    NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:path];
                    if(!handle) continue;
                    NSData *data=[handle readDataUpToLength:DC_SAVE_RECORD_BYTES error:&saveError];
                    [handle closeFile];
                    if(!data || data.length<DC_SAVE_RECORD_BYTES) continue;
                    dc_save_unlocks unlocked;
                    if(dc_save_get_unlocks(data.bytes,data.length,&unlocked)!=DC_OK) continue;
                    _editUnlocked |= unlocked.edit!=0;_extraUnlocked |= unlocked.extra!=0;
                }
            }
            NSData *flowRecord=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"save/flow.state"]];
            if(flowRecord.length>=dcFlowPersistHeaderBytes+DC_SAVE_RECORD_BYTES &&
               memcmp(flowRecord.bytes,"PLFL",4)==0 && ((const uint8_t *)flowRecord.bytes)[4]==1) {
                const uint8_t *raw=(const uint8_t *)flowRecord.bytes+dcFlowPersistHeaderBytes;
                uint8_t a=raw[0x23],b=raw[0x21bb],c=raw[0x4353];
                BOOL allTwo=(a==2&&b==2&&c==2);
                _editUnlocked |= allTwo;
                _extraUnlocked |= (allTwo || a!=0 || b!=0 || c!=0);
            }
            if(_storyInitialized) {
                BOOL allTwo=(_story.stages[0].progress==2 && _story.stages[1].progress==2 && _story.stages[2].progress==2);
                BOOL anyProgress=(_story.unlocked!=0 || _story.stages[0].progress!=0 || _story.stages[1].progress!=0 || _story.stages[2].progress!=0);
                _editUnlocked |= allTwo;
                _extraUnlocked |= (allTwo || anyProgress);
            }
            _titleUnlocksLoaded=YES;
        }
        if(!_configuration)[self loadConfigurationFromDirectory:directory];
        if (!_gameAudio) {
            NSString *audioError=nil;
            _gameAudio=[[DCGameAudio alloc] initWithDirectory:directory error:&audioError];
            if(!_gameAudio)return audioError ?: @"Title audio resources are unavailable";
            if(_configuration)[_gameAudio applyConfiguration:_configuration];
        }
        NSString *audioError=_galleryMode?[_gameAudio startExtraMusic]:[_gameAudio startTitleMusic];
        if(audioError)return audioError;
        if(!_titleStateInitialized) {
            _titleState=(dc_title_state){.waiting=1,.hover=255};
            if([_startupScene requestTransition:4 tick:sceneTick]!=DC_OK)return @"Title entry transition failed";
            _titleStateInitialized=YES;
        }
        uint32_t transitionReady=0;
        if([_startupScene queryTransitionReady:&transitionReady]!=DC_OK)return @"Title transition query failed";
        /* The original title assets and hit regions use 1024x768 coordinates. */
        float scale = fminf((float)_width / 1024.0f, (float)_height / 768.0f);
        float offsetX = ((float)_width - 1024.0f * scale) * 0.5f;
        float offsetY = ((float)_height - 768.0f * scale) * 0.5f;
        int32_t menuResult=-1,menuRow=-1;
        BOOL acceptsInput=!_titleState.waiting || (_titleState.action==0 && transitionReady);
        BOOL prevTitleTouch=_previousTitleTouch;
        if (acceptsInput && !_galleryMode && (pcInput.active || touching || prevTitleTouch)) {
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            if (!_titleMenuInitialized) {
                _titleMenu=(dc_menu_state){.hover=-1,.selected=-1};
                _titleMenuInitialized=YES;
            }
            dc_menu_button buttons[5]={0};
            for(uint32_t i=0;i<5;++i)buttons[i]=(dc_menu_button){.x=702,.y=400+72*i,.width=256,.height=48,
                .disabled=(i==2&&!_editUnlocked)||(i==3&&!_extraUnlocked)};
            uint8_t input=pcInput.active?pcInput.mouse[0]:(touching ? (prevTitleTouch?1:3) : (prevTitleTouch?2:0));
            // The original menu requires hover before the press. A direct
            // touchscreen press moves and clicks in one event, so establish
            // the same hover at this location before forwarding its press.
            if (input==3) {
                int32_t hoverResult;
                if(dc_menu_step(&_titleMenu,buttons,5,(int32_t)gameX,(int32_t)gameY,1,0,&hoverResult)!=DC_OK)
                    return @"Title pointer hover failed";
            }
            int32_t result;
            dc_status menuStatus=dc_menu_step(&_titleMenu,buttons,5,(int32_t)gameX,(int32_t)gameY,1,input,&result);
            if(menuStatus!=DC_OK)return @"Title menu update failed";
            _selectedTitleOption=_titleMenu.active ? _titleMenu.hover+2 : -1;
            menuResult=result;menuRow=_titleMenu.hover;
        }
        uint64_t up=DC_PAD_UP|(UINT64_C(1)<<17),down=DC_PAD_DOWN|(UINT64_C(1)<<19);
        if(acceptsInput && !_galleryMode && (controller.pressed&(up|down|DC_PAD_A|DC_PAD_PLUS))) {
            int step=(controller.pressed&up)?-1:(controller.pressed&down)?1:0;
            if(step) {
                do { _controllerTitleRow=(_controllerTitleRow+step+5)%5; }
                while((_controllerTitleRow==2&&!_editUnlocked)||(_controllerTitleRow==3&&!_extraUnlocked));
            }
            menuRow=_controllerTitleRow;
            menuResult=(controller.pressed&(DC_PAD_A|DC_PAD_PLUS))?1:3;
            _selectedTitleOption=menuRow+2;
        }
        BOOL galleryTap=(acceptsInput && _galleryMode && touching && !prevTitleTouch);
        _previousTitleTouch=touching;
        if(acceptsInput && !_galleryMode && pcInput.keys[0x3b]==3) {
            NSString *configError=[self enterConfigSceneFromDirectory:directory];
            if(configError)return configError;
            return nil;
        }
        if(_galleryMode) {
            [self tryLoadExtraGalleryFromDirectory:directory];
            uint64_t prevPad=up|DC_PAD_LEFT|(UINT64_C(1)<<20);
            uint64_t nextPad=down|DC_PAD_RIGHT|(UINT64_C(1)<<18);
            if(_extraSceneLoaded) {
                if(_galleryWaiting) {
                    if(_galleryAction==0 && transitionReady) {
                        _galleryWaiting=NO;
                    } else if((_galleryAction==2||_galleryAction==3) && transitionReady && !_gameAudio.selectionBusy) {
                        _galleryMode=NO;_galleryViewingCG=NO;_galleryWaiting=NO;_galleryAction=0;
                        if(_galleryTexture){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}
                        [_gameAudio stopExtraMusic];
                        [_gameAudio startTitleMusic];
                        _titleStateInitialized=NO;_titleMenuInitialized=NO;
                    } else if(_galleryAction>=4 && _galleryAction<=20 && transitionReady) {
                        _galleryIndex=_galleryAction-4;
                        [self loadGalleryImageFromDirectory:directory];
                        _galleryViewingCG=YES;_galleryAction=0;_galleryWaiting=YES;
                        if([_startupScene requestTransition:4 tick:sceneTick]!=DC_OK)return @"Extra CG entry transition failed";
                    } else if(_galleryAction==21 && transitionReady) {
                        if(_galleryTexture){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}
                        for(unsigned g=0;g<3;++g)_extraMenus[g]=(dc_menu_state){.hover=-1,.selected=-1};
                        _galleryViewingCG=NO;_galleryAction=0;_galleryWaiting=YES;
                        if([_startupScene requestTransition:4 tick:sceneTick]!=DC_OK)return @"Extra CG return transition failed";
                    }
                } else if(pcInput.keys[1]==3) {
                    [_gameAudio suspendForSystemPage];
                    if([_startupScene requestTransition:3 tick:sceneTick]!=DC_OK)return @"Extra dummy transition failed";
                    return [self enterDummySceneFromDirectory:directory owner:8];
                } else if(_galleryViewingCG) {
                    if(pcInput.mouse[0]==3 || pcInput.mouse[1]==3 || galleryTap ||
                       pcInput.keys[0x1c]==3 || (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS))) {
                        if(![_gameAudio playGameplayEffectNamed:@"se101.wav"])[_gameAudio playMenuSelection];
                        if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra CG close transition failed";
                        _galleryWaiting=YES;_galleryAction=21;
                    }
                } else {
                    float screenX=(x+1.0f)*0.5f*_width;
                    float screenY=(1.0f-y)*0.5f*_height;
                    float gameX=(screenX-offsetX)/scale;
                    float gameY=(screenY-offsetY)/scale;
                    BOOL selectedFromMenu=NO;
                    if(pcInput.active || touching || prevTitleTouch) {
                        dc_menu_button buttons0[6]={0},buttons1[11]={0},buttons2[2]={0};
                        for(uint32_t i=0;i<6;++i)buttons0[i]=(dc_menu_button){.x=64+152*(int32_t)i,.y=112,.width=144,.height=176,.disabled=0};
                        for(uint32_t i=0;i<11;++i)buttons1[i]=(dc_menu_button){.x=64+152*(int32_t)(i%6),.y=i<6?368:536,.width=144,.height=128,.disabled=0};
                        buttons2[0]=(dc_menu_button){.x=48,.y=704,.width=56,.height=56,.disabled=0};
                        buttons2[1]=(dc_menu_button){.x=128,.y=704,.width=56,.height=56,.disabled=0};
                        uint8_t input=pcInput.active?pcInput.mouse[0]:(touching?(prevTitleTouch?1:3):(prevTitleTouch?2:0));
                        int32_t res0=-1,res1=-1,res2=-1;
                        if(input==3) {
                            int32_t hr=-1;
                            dc_menu_step(&_extraMenus[0],buttons0,6,(int32_t)gameX,(int32_t)gameY,1,0,&hr);
                            dc_menu_step(&_extraMenus[1],buttons1,11,(int32_t)gameX,(int32_t)gameY,1,0,&hr);
                            dc_menu_step(&_extraMenus[2],buttons2,2,(int32_t)gameX,(int32_t)gameY,1,0,&hr);
                        }
                        dc_menu_step(&_extraMenus[0],buttons0,6,(int32_t)gameX,(int32_t)gameY,1,input,&res0);
                        dc_menu_step(&_extraMenus[1],buttons1,11,(int32_t)gameX,(int32_t)gameY,1,input,&res1);
                        dc_menu_step(&_extraMenus[2],buttons2,2,(int32_t)gameX,(int32_t)gameY,1,input,&res2);
                        if(res0==1 && _extraMenus[0].selected>=0 && _extraMenus[0].selected<6) {
                            if(![_gameAudio playGameplayEffectNamed:@"se101.wav"])[_gameAudio playMenuSelection];
                            if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra HCG open transition failed";
                            _galleryWaiting=YES;_galleryAction=4u+(uint32_t)_extraMenus[0].selected;
                            selectedFromMenu=YES;
                        } else if(res1==1 && _extraMenus[1].selected>=0 && _extraMenus[1].selected<11) {
                            if(![_gameAudio playGameplayEffectNamed:@"se101.wav"])[_gameAudio playMenuSelection];
                            if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra CG open transition failed";
                            _galleryWaiting=YES;_galleryAction=10u+(uint32_t)_extraMenus[1].selected;
                            selectedFromMenu=YES;
                        } else if(res2==1 && _extraMenus[2].selected>=0 && _extraMenus[2].selected<2) {
                            [_gameAudio playMenuSelection];
                            if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra exit transition failed";
                            _galleryWaiting=YES;_galleryAction=2u+(uint32_t)_extraMenus[2].selected;
                            selectedFromMenu=YES;
                        }
                    }
                    if(!selectedFromMenu) {
                        if(pcInput.mouse[1]==3 || (controller.pressed&DC_PAD_B)) {
                            [_gameAudio playMenuSelection];
                            if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra right-click exit transition failed";
                            _galleryWaiting=YES;_galleryAction=3;
                        } else if(pcInput.keys[0xcb]==3 || pcInput.keys[0xc8]==3 || pcInput.keys[0xc9]==3 || pcInput.wheel>0 || (controller.pressed&prevPad)) {
                            _galleryIndex=(_galleryIndex+18u)%19u;
                            for(unsigned g=0;g<3;++g)_extraMenus[g]=(dc_menu_state){.hover=-1,.selected=-1};
                            if(_galleryIndex<6)_extraMenus[0]=(dc_menu_state){.active=1,.hover=(int32_t)_galleryIndex,.selected=-1};
                            else if(_galleryIndex<17)_extraMenus[1]=(dc_menu_state){.active=1,.hover=(int32_t)(_galleryIndex-6),.selected=-1};
                            else _extraMenus[2]=(dc_menu_state){.active=1,.hover=(int32_t)(_galleryIndex-17),.selected=-1};
                        } else if(pcInput.keys[0xcd]==3 || pcInput.keys[0xd0]==3 || pcInput.keys[0xd1]==3 || pcInput.wheel<0 || (controller.pressed&nextPad)) {
                            _galleryIndex=(_galleryIndex+1u)%19u;
                            for(unsigned g=0;g<3;++g)_extraMenus[g]=(dc_menu_state){.hover=-1,.selected=-1};
                            if(_galleryIndex<6)_extraMenus[0]=(dc_menu_state){.active=1,.hover=(int32_t)_galleryIndex,.selected=-1};
                            else if(_galleryIndex<17)_extraMenus[1]=(dc_menu_state){.active=1,.hover=(int32_t)(_galleryIndex-6),.selected=-1};
                            else _extraMenus[2]=(dc_menu_state){.active=1,.hover=(int32_t)(_galleryIndex-17),.selected=-1};
                        } else if(pcInput.keys[0x1c]==3 || (controller.pressed&(DC_PAD_A|DC_PAD_PLUS))) {
                            if(_galleryIndex<17) {
                                if(![_gameAudio playGameplayEffectNamed:@"se101.wav"])[_gameAudio playMenuSelection];
                                if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra pad open transition failed";
                                _galleryWaiting=YES;_galleryAction=4u+_galleryIndex;
                            } else {
                                [_gameAudio playMenuSelection];
                                if([_startupScene requestTransition:2 tick:sceneTick]!=DC_OK)return @"Extra pad exit transition failed";
                                _galleryWaiting=YES;_galleryAction=2u+(_galleryIndex-17u);
                            }
                        }
                    }
                }
            } else {
                if(pcInput.mouse[1]==2 || pcInput.keys[1]==3 || (controller.pressed&DC_PAD_B)) {
                    _galleryMode=NO;
                    if(_galleryTexture){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}
                    [_gameAudio stopExtraMusic];
                    [_gameAudio startTitleMusic];
                    _titleStateInitialized=NO;_titleMenuInitialized=NO;
                } else if(pcInput.keys[0xcb]==3 || pcInput.keys[0xc8]==3 || pcInput.keys[0xc9]==3 || pcInput.wheel>0 || (controller.pressed&prevPad)) {
                    if(_galleryIndex>0)--_galleryIndex;
                    [self loadGalleryImageFromDirectory:directory];
                } else if(pcInput.mouse[0]==3 || galleryTap || pcInput.keys[0xcd]==3 || pcInput.keys[0xd0]==3 || pcInput.keys[0xd1]==3 || pcInput.wheel<0 || (controller.pressed&(nextPad|DC_PAD_A|DC_PAD_PLUS))) {
                    ++_galleryIndex;
                    [self loadGalleryImageFromDirectory:directory];
                }
            }
            menuResult=-1;menuRow=-1;
        }
        dc_title_input titleInput={.transition_ready=transitionReady,.selection_busy=_gameAudio.selectionBusy,
            .escape_code=_galleryMode?0:pcInput.keys[1],.menu_result=menuResult,.menu_row=menuRow};
        dc_title_plan titlePlan;
        if(dc_title_build_plan(&_titleState,&titleInput,&titlePlan)!=DC_OK)return @"Title action planning failed";
        BOOL enteredGallery=NO;
        for(uint32_t i=0;i<titlePlan.count;++i) {
            dc_title_command command=titlePlan.commands[i];
            if(command.kind==DC_TITLE_PLAY_SELECTION) {
                if(![_gameAudio playMenuSelection])return @"Menu selection audio failed";
            } else if(command.kind==DC_TITLE_TRANSITION) {
                if([_startupScene requestTransition:command.value tick:sceneTick]!=DC_OK)return @"Title selection transition failed";
            } else if(command.kind==DC_TITLE_CLEANUP || command.kind==DC_TITLE_STOP_MUSIC) {
                [_gameAudio stopTitleMusic];
            } else if(command.kind==DC_TITLE_BACKUP || command.kind==DC_TITLE_HIDE) {
                /* Load-slot and hide callbacks are represented by the native
                 * planner. ENTER=2 enters the saved-game scene; ENTER=1 is
                 * followed by INIT_GAME for the new-game intro. */
            } else if(command.kind==DC_TITLE_ENTER) {
                if(command.value==2) {
                    NSString *saveError=[self enterSaveSceneFromDirectory:directory];
                    if(saveError)return saveError;
                } else if(command.value==3) {
                    /* Original Edit destination (FUN_005f1d20): the character
                     * edit presentation over the first gameplay scene. The
                     * story save is not modified. */
                    [self loadStoryFromDirectory:directory];
                    dc_story_state savedStory=_story;
                    BOOL savedStoryInit=_storyInitialized;
                    dc_flow_state savedFlow=_flowState;
                    BOOL savedFlowInit=_flowInitialized;
                    _story.chapter=3;_story.map=0;_story.stage=2;
                    _storyInitialized=YES;
                    [_gameScene detachRenderer];_gameScene=nil;
                    NSString *editError=[self startGameSceneFromDirectory:directory];
                    _story=savedStory;_storyInitialized=savedStoryInit;
                    _flowState=savedFlow;_flowInitialized=savedFlowInit;
                    if(editError)return editError;
                    if(_gameScene)[_gameScene setEditMode:YES];
                } else if(command.value==4) {
                    /* Original Extra destination (0x510a40): CG gallery grid
                     * in RPP_02.pp with bgm012.wav. */
                    _galleryMode=YES;_galleryViewingCG=NO;_galleryWaiting=YES;_galleryAction=0;_galleryIndex=0;enteredGallery=YES;
                    for(unsigned g=0;g<3;++g)_extraMenus[g]=(dc_menu_state){.hover=-1,.selected=-1};
                    _selectedTitleOption=-1;
                    [self tryLoadExtraGalleryFromDirectory:directory];
                    if(!_extraSceneLoaded)[self loadGalleryImageFromDirectory:directory];
                    [_gameAudio startExtraMusic];
                    [_startupScene requestTransition:4 tick:sceneTick];
                } else if(command.value==6) {
                    NSString *dummyError=[self enterDummySceneFromDirectory:directory owner:4];
                    if(dummyError)return dummyError;
                } else if(command.value!=1) {
                    /* ENTER=1 (New Game) falls through to INIT_GAME. */
                    return [NSString stringWithFormat:@"Title destination %u is not implemented",command.value];
                }
            } else if(command.kind==DC_TITLE_INIT_GAME) {
                NSString *introError=nil;
                // New Game must not inherit an old interaction-complete flag
                // or player position. Reserve the player prefix for the first
                // actual scene save, then append the fresh chapter state.
                NSString *saveDirectory=[directory stringByAppendingPathComponent:@"save"];
                [[NSFileManager defaultManager] createDirectoryAtPath:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
                [[NSData dataWithBytes:(uint8_t[DC_GAME_PLAYER_SAVE_BYTES]){0} length:DC_GAME_PLAYER_SAVE_BYTES]
                    writeToFile:[saveDirectory stringByAppendingPathComponent:@"player.state"] options:NSDataWritingAtomic error:nil];
                [self resetStory];
                [self saveStoryToDirectory:directory];
                _introScene=[[DCIntroScene alloc] initWithDirectory:directory error:&introError];
                if(!_introScene)return introError ?: @"New-game initialization failed";
                if(_configuration)[_introScene applyConfiguration:_configuration];
                if([_startupScene requestTransition:3 tick:sceneTick]!=DC_OK ||
                   [_startupScene requestTransition:4 tick:sceneTick]!=DC_OK)return @"Intro entry transition failed";
            } else if(command.kind==DC_TITLE_QUIT) {
                [self returnToTitleScene];
                return nil;
            } else return @"Title destination adapter is not implemented";
        }
        _titleState=enteredGallery?(dc_title_state){.waiting=0,.action=0,.hover=255}:titlePlan.next;
        if(_saveScene||_configScene||_gameScene||_dummyScene)return nil;
        if(_introScene) {
            BOOL introTouch = touching || dc_gamepad_pointer_contact_active() ||
                (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS)) ||
                pcInput.keys[0x1c]==1 || pcInput.keys[0x1c]==3 || pcInput.keys[0xd0]==1 || pcInput.keys[0xd0]==3;
            NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
                touching:introTouch width:_width height:_height];
            if(failure)return failure;
            NSString *auxiliaryFailure=[self handleIntroAuxiliaryFromDirectory:directory];
            if(auxiliaryFailure)return auxiliaryFailure;
            if(!_introScene||_configScene||_saveScene||_dummyScene)return nil;
            _presentedScene=DCVulkanSpriteSceneIntro;++_presentedFrames;return nil;
        }
#define ADD_TITLE_LAYER(index_, x_, y_) do { \
    dc_vk_sprite_item *item = &draws[drawCount++]; \
    item->texture = _titleTextures[(index_)]; item->blend_mode = 3; \
    item->pose.width = _titleWidths[(index_)] * scale; \
    item->pose.height = _titleHeights[(index_)] * scale; \
    item->pose.x = offsetX + (x_) * scale; item->pose.y = offsetY + (y_) * scale; \
    item->pose.z = 0.5f; item->pose.scale_x = item->pose.scale_y = item->pose.alpha = 1.0f; \
    item->pose.red = item->pose.green = item->pose.blue = 1.0f; \
    item->pose.u0 = 0; item->pose.u1 = 1; item->pose.v0 = 0; item->pose.v1 = 1; \
} while (0)
#define ADD_EXTRA_LAYER(tex_, x_, y_, w_, h_) do { \
    dc_vk_sprite_item *item = &draws[drawCount++]; \
    item->texture = (tex_); item->blend_mode = 3; \
    item->pose.width = (w_) * scale; \
    item->pose.height = (h_) * scale; \
    item->pose.x = offsetX + (x_) * scale; item->pose.y = offsetY + (y_) * scale; \
    item->pose.z = 0.5f; item->pose.scale_x = item->pose.scale_y = item->pose.alpha = 1.0f; \
    item->pose.red = item->pose.green = item->pose.blue = 1.0f; \
    item->pose.u0 = 0; item->pose.u1 = 1; item->pose.v0 = 0; item->pose.v1 = 1; \
} while (0)
        if (!_galleryMode) {
            ADD_TITLE_LAYER(1, 0, 0);
            if (_selectedTitleOption >= 2 && _selectedTitleOption <= 6)
                ADD_TITLE_LAYER((uint32_t)_selectedTitleOption, 702, 400 + 72 * (_selectedTitleOption - 2));
            if (!_editUnlocked) ADD_TITLE_LAYER(7, 702, 544);
            if (!_extraUnlocked) ADD_TITLE_LAYER(8, 702, 616);
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            ADD_TITLE_LAYER(0, gameX - 6.4f, gameY - 6.4f);
        } else if (_extraSceneLoaded) {
            if (_galleryViewingCG && !_galleryTexture) [self loadGalleryImageFromDirectory:directory];
            if (_galleryViewingCG && _galleryTexture) {
                ADD_EXTRA_LAYER(_galleryTexture, 0, 0, 1024, 768);
            } else {
                ADD_EXTRA_LAYER(_extraTextures[0], 0, 0, 1024, 768);
                if (_extraMenus[0].active && _extraMenus[0].hover >= 0 && _extraMenus[0].hover < 6) {
                    ADD_EXTRA_LAYER(_extraTextures[1], 64 + 152 * _extraMenus[0].hover, 112, 144, 176);
                }
                if (_extraMenus[1].active && _extraMenus[1].hover >= 0 && _extraMenus[1].hover < 11) {
                    int32_t idx = _extraMenus[1].hover;
                    ADD_EXTRA_LAYER(_extraTextures[2], 64 + 152 * (idx % 6), idx < 6 ? 368 : 536, 144, 128);
                }
                if (_extraMenus[2].active && _extraMenus[2].hover == 0) {
                    ADD_EXTRA_LAYER(_extraTextures[3], 48, 704, 56, 56);
                } else if (_extraMenus[2].active && _extraMenus[2].hover == 1) {
                    ADD_EXTRA_LAYER(_extraTextures[4], 128, 704, 56, 56);
                }
                float screenX = (x + 1.0f) * 0.5f * _width;
                float screenY = (1.0f - y) * 0.5f * _height;
                float gameX = (screenX - offsetX) / scale;
                float gameY = (screenY - offsetY) / scale;
                ADD_TITLE_LAYER(0, gameX - 6.4f, gameY - 6.4f);
            }
        } else {
            ADD_TITLE_LAYER(1, 0, 0);
            if(!_galleryTexture)[self loadGalleryImageFromDirectory:directory];
            if(_galleryTexture) {
                dc_vk_sprite_item *item=&draws[drawCount++];
                item->texture=_galleryTexture;item->blend_mode=3;
                float side=fminf(1024.0f*scale,768.0f*scale);
                item->pose=(dc_sprite_pose){.width=side,.height=side*.75f,
                    .x=offsetX+(1024*scale-side)*.5f,.y=offsetY+(768*scale-side*.75f)*.5f,
                    .z=.6f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
            }
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            ADD_TITLE_LAYER(0, gameX - 6.4f, gameY - 6.4f);
        }
#undef ADD_EXTRA_LAYER
#undef ADD_TITLE_LAYER
    } else {
        if(_gameScene) {
            if(![_gameAudio resumeGameplayEffects])return @"Gameplay effect resume failed";
            NSString *characterFailure=[_gameScene updateCharacterWithExitSoundBusy:[_gameAudio gameplaySlotBusy:28] tick:sceneTick];
            if(characterFailure)return characterFailure;
            NSString *effectFailure=[self playPendingGameplayEffect];if(effectFailure)return effectFailure;
            NSString *systemFailure=[_gameScene updateSystemWithSelectionSoundBusy:[_gameAudio gameplaySlotBusy:0] tick:sceneTick];
            if(systemFailure)return systemFailure;
            if(controller.pressed&DC_PAD_B)[_gameAudio cancelGameplayVoice];
            dc_pad_frame gameController=controller;
            BOOL suppressInput=_suppressGameplayTouch;
            if(_suppressGameplayTouch) gameController=(dc_pad_frame){0};
            BOOL gameTouch=touching;
            if(_suppressGameplayTouch){gameTouch=NO;_suppressGameplayTouch=NO;}
            dc_pc_frame gamePC=pcInput;
            if(suppressInput) gamePC=(dc_pc_frame){0};
            _gameScene.voiceMouthPhase=_gameAudio?[_gameAudio gameplayVoiceMouthPhase]:0.0f;
            NSString *gameFailure=[_gameScene drawAtTick:sceneTick inputX:x inputY:y touching:gameTouch controller:gameController pcInput:gamePC width:_width height:_height];
            if(gameFailure)return gameFailure;
            if(_gameScene.interactiveScene)_secondaryViewDisabledSetting=!_gameScene.secondaryViewVisible;
            effectFailure=[self playPendingGameplayEffect];if(effectFailure)return effectFailure;
            NSString *voiceFailure=[self playPendingGameplayVoice];
            if(voiceFailure)return voiceFailure;
            NSString *transitionFailure=[self handleGameplayTransitionFromDirectory:directory];
            if(transitionFailure)return transitionFailure;
            _previousGameplayTouch=gameTouch;
            _presentedScene=_gameScene.gameFinished ? DCVulkanSpriteSceneGameComplete : DCVulkanSpriteSceneGameplay;
            ++_presentedFrames;
            return nil;
        }
        double milliseconds = time * 1000.0;
        if (!isfinite(milliseconds) || milliseconds < 0) return @"Invalid diagnostic animation time";
        uint32_t tick = (uint32_t)fmod(milliseconds, 4294967296.0);
        uint32_t delta = _diagnosticTickInitialized ? tick - _lastDiagnosticTick : 0;
        if (!_diagnosticTickInitialized) {
            /* Self-authored XA bytes exercise the real resource-to-controller
             * path. No original names, keys or game payloads are supplied. */
            const uint8_t target[] = {0x9b,0x96,0x9e,0x98,0x91,0x90,0x8c,0x8b,0x96,0x9c,0xff};
            const size_t keysOffset = 13 + sizeof(target), tableOffset = 160 + sizeof(target);
            const size_t poseOffset = tableOffset + DC_XA_CLIP_COUNT * DC_XA_CLIP_RECORD_BYTES;
            const uint8_t nodeTarget[] = {0x8c,0x86,0x91,0x8b,0x97,0x9a,0x8b,0x96,0x9c,0xd2,0x91,0x90,0x9b,0x9a,0xff};
            const size_t poseKeysOffset = poseOffset + 16 + sizeof(nodeTarget);
            NSMutableData *fixture = [NSMutableData dataWithLength:poseKeysOffset + 2 * 52];
            uint8_t *bytes = fixture.mutableBytes;
            bytes[0] = 1;
            dc_write_word_le(bytes + 1, 1);
            dc_write_word_le(bytes + 5, sizeof(target));
            memcpy(bytes + 9, target, sizeof(target));
            dc_write_word_le(bytes + 9 + sizeof(target), 2);
            for (uint32_t key = 0; key < 2; ++key) {
                for (uint32_t component = 0; component < DC_MATERIAL_COMPONENTS; ++component)
                    dc_write_float_le(bytes + keysOffset + key * 72 + component * 4, 1.0f);
                dc_write_word_le(bytes + keysOffset + key * 72 + 68, key * 8);
            }
            dc_write_float_le(bytes + keysOffset + 12, 0.35f);
            bytes[tableOffset - 1] = 1;
            dc_write_float_le(bytes + tableOffset + 64, 18.0f);
            dc_write_float_le(bytes + tableOffset + 76, 6.283185307179586f);
            bytes[tableOffset + 80] = 1;
            dc_write_word_le(bytes + poseOffset, 1);
            dc_write_word_le(bytes + poseOffset + 4, sizeof(nodeTarget));
            memcpy(bytes + poseOffset + 8, nodeTarget, sizeof(nodeTarget));
            dc_write_word_le(bytes + poseOffset + 8 + sizeof(nodeTarget), 2);
            for (uint32_t key = 0; key < 2; ++key) {
                uint8_t *record = bytes + poseKeysOffset + key * 52;
                dc_write_word_le(record, key * 8);
                float angle = key ? 1.8f : -0.6f;
                dc_write_float_le(record + 12, sinf(angle * 0.5f));
                dc_write_float_le(record + 16, cosf(angle * 0.5f));
                dc_write_float_le(record + 28, key ? 0.2f : -0.2f);
                dc_write_float_le(record + 40, key ? 1.15f : 0.85f);
                dc_write_float_le(record + 44, key ? 1.15f : 0.85f);
                dc_write_float_le(record + 48, 1);
            }
            dc_animation_clip clips[DC_XA_CLIP_COUNT];
            dc_animation_timing timing[DC_XA_CLIP_COUNT];
            dc_status status = dc_xa_load_clips(bytes, fixture.length, clips, timing, DC_XA_CLIP_COUNT);
            if (status != DC_OK)
                return [NSString stringWithFormat:@"Native XA fixture rejected: %d", status];
            _diagnosticClip = clips[0];
            _diagnosticTiming = timing[0];
            status = dc_xa_load_material_keys(bytes, fixture.length, 0, _diagnosticMaterialKeys, 2);
            if (status != DC_OK)
                return [NSString stringWithFormat:@"Native XA material keys rejected: %d", status];
            dc_xa_material_track track;
            status = dc_xa_material_track_at(bytes, fixture.length, 0, &track);
            dc_xx *model = NULL;
            uint32_t materialIndex = UINT32_MAX;
            if (status == DC_OK) status = dc_xx_open(dc_diagnostic_xx, sizeof(dc_diagnostic_xx), &model);
            if (status == DC_OK)
                status = dc_xx_find_material_encoded(model, bytes + track.name_offset, track.name_length, &materialIndex);
            if (status == DC_OK) status = dc_xx_material_baseline(model, materialIndex, &_diagnosticBaseline);
            dc_xa_pose_track poseTrack;
            uint32_t nodeIndex = UINT32_MAX;
            if (status == DC_OK) status = dc_xa_pose_track_at(bytes, fixture.length, 0, &poseTrack);
            if (status == DC_OK)
                status = dc_xx_find_node_encoded(model, bytes + poseTrack.name_offset, poseTrack.name_length, &nodeIndex);
            if (status == DC_OK) status = dc_xx_node_matrix(model, nodeIndex, &_diagnosticPose);
            if (status == DC_OK) status = dc_xa_load_pose_keys(bytes, fixture.length, 0, _diagnosticPoseKeys, 2);
            dc_xx_close(model);
            if (status != DC_OK)
                return [NSString stringWithFormat:@"Native XA/XX material binding rejected: %d", status];
            _diagnosticMaterial = _diagnosticMaterialKeys[0].value;
            _diagnosticAnimation = (dc_animation_state){.blend = 1};
        }
        dc_animation_tick_result update;
        dc_status animationStatus = dc_animation_tick(&_diagnosticAnimation, &_diagnosticClip, &_diagnosticTiming,
            1, delta, 1, tick, &update);
        if (animationStatus != DC_OK)
            return [NSString stringWithFormat:@"Native animation tick failed: %d", animationStatus];
        _diagnosticTickInitialized = YES;
        _lastDiagnosticTick = tick;
        animationMoved = delta > 0 && update.samples[0] != update.previous_frame;
        float oldAlpha = _diagnosticMaterial.components[3];
        dc_status materialStatus = dc_material_sample(_diagnosticMaterialKeys, 2, &_diagnosticBaseline,
            update.samples[0], &_diagnosticMaterial);
        if (materialStatus != DC_OK)
            return [NSString stringWithFormat:@"Native material sampling failed: %d", materialStatus];
        materialMoved = animationMoved && oldAlpha != _diagnosticMaterial.components[3];
        dc_matrix previousPose = _diagnosticPose;
        dc_status poseStatus = dc_pose_sample(_diagnosticPoseKeys, 2, 0, update.samples[0], &_diagnosticPose);
        if (poseStatus != DC_OK)
            return [NSString stringWithFormat:@"Native pose sampling failed: %d", poseStatus];
        poseMoved = animationMoved && memcmp(&previousPose, &_diagnosticPose, sizeof(previousPose)) != 0;
        float poseScale = hypotf(_diagnosticPose.values[0], _diagnosticPose.values[1]);
        float side = fminf(_width, _height) * 0.4f;
        dc_vk_sprite_item *item = &draws[drawCount++];
        item->texture = _texture; item->blend_mode = 3; item->point_filter = 1;
        item->pose = (dc_sprite_pose){.width = side, .height = side,
            .x = _width * (0.5f + x * 0.3f + _diagnosticPose.values[12]*0.3f), .y = _height * (0.5f - y * 0.3f), .z = 0.5f,
            .origin_x = 0.5f, .origin_y = 0.5f, .scale_x = poseScale, .scale_y = poseScale, .alpha = _diagnosticMaterial.components[3],
            .rotation = atan2f(_diagnosticPose.values[1], _diagnosticPose.values[0]), .red = 1, .green = 1, .blue = 1,
            .u0 = 0, .u1 = 1, .v0 = 0, .v1 = 1};
    }
    const uint8_t clear[] = {10,15,26,255};
    NSString *titleFailure=showTitle ? [_startupScene drawSprites:draws count:drawCount tick:sceneTick width:_width height:_height] : nil;
    if (titleFailure || (!showTitle && dc_vk_sprite_render(_renderer, draws, drawCount, clear, NULL, 0) != DC_OK)) {
        if(titleFailure)return titleFailure;
        NSString *message = [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
        [self destroyRenderer];
        return message;
    }
    /* Report only the scene whose draw was successfully presented. Loading a
     * texture or drawing the fallback must not certify a later game screen. */
    _presentedScene = showTitle ? DCVulkanSpriteSceneTitle : DCVulkanSpriteSceneDiagnostic;
    if (animationMoved) _diagnosticAnimationAdvanced = YES;
    if (materialMoved) _diagnosticMaterialAdvanced = YES;
    if (poseMoved) _diagnosticPoseAdvanced = YES;
    ++_presentedFrames;
    return nil;
}
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time touching:(BOOL)touching controller:(dc_pad_frame)controller pcInput:(dc_pc_frame)pcInput
            completion:(void (^)(NSString *, NSString *, DCVulkanSpriteScene, BOOL, BOOL, BOOL, BOOL, NSString *, BOOL, BOOL, BOOL))completion {
    if (atomic_load(&_suspended) || !self.window ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        completion(nil, _deviceName ?: @"", _presentedScene, NO, NO, NO, NO, @"", NO, NO, NO);
        return;
    }
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGSize drawableSize = layer.drawableSize;
    uint32_t width = (uint32_t)drawableSize.width, height = (uint32_t)drawableSize.height;
    if (!width || !height) {
        completion(nil, _deviceName ?: @"", _presentedScene, NO, NO, NO, NO, @"", NO, NO, NO);
        return;
    }
    NSString *directory = [self.startupDataDirectory copy] ?: @"";
    if([self.superview isKindOfClass:DCVulkanContainerView.class] && self.bounds.size.width>0 && self.bounds.size.height>0) {
        CGSize inputSize=self.superview.bounds.size;
        pcInput.x=(pcInput.x*inputSize.width-self.frame.origin.x)/self.bounds.size.width;
        pcInput.y=(pcInput.y*inputSize.height-self.frame.origin.y)/self.bounds.size.height;
    }
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            if (atomic_load(&self->_suspended)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, self->_deviceName ?: @"", self->_presentedScene, NO, NO, NO, NO, @"", NO, NO, NO);
                });
                return;
            }
            BOOL hadRenderer = (self->_renderer != NULL);
            BOOL canRecover = atomic_exchange(&self->_needsRecoveryAfterResume, false);
            NSString *error = [self drawAtX:x y:y time:time layer:layer width:width height:height dataDirectory:directory touching:touching controller:controller pcInput:pcInput];
            if (error && (atomic_load(&self->_suspended) || (hadRenderer && canRecover))) {
                if (atomic_load(&self->_suspended)) {
                    error = nil;
                } else {
                    [self detachRendererOnly];
                    error = [self drawAtX:x y:y time:time layer:layer width:width height:height dataDirectory:directory touching:touching controller:controller pcInput:pcInput];
                }
            }
            NSString *device = self->_deviceName ?: @"";
            DCVulkanSpriteScene scene = self->_presentedScene;
            BOOL advanced = self->_diagnosticAnimationAdvanced;
            BOOL materialAdvanced = self->_diagnosticMaterialAdvanced;
            BOOL poseAdvanced = self->_diagnosticPoseAdvanced;
            BOOL musicAdvanced = self->_introScene ? self->_introScene.audioAdvanced : self->_gameAudio.musicAdvanced;
            NSString *introState=self->_introScene.presentationState ?: @"";
            BOOL skinAdvanced=self->_startupScene.skinAdvanced;
            BOOL gameplaySkinAdvanced=self->_gameScene.actorSkinAdvanced;
            BOOL interactionCompleted=self->_gameScene.interactionCompleted;
            BOOL controlBusy=(scene==DCVulkanSpriteSceneGameplay||scene==DCVulkanSpriteSceneGameComplete) &&
                (self->_gameScene.interactionActive||self->_gameAudio.gameplayVoiceBusy);
            NSString *gameContext=self->_gameScene.presentationContext.length?self->_gameScene.presentationContext:
                (self->_configScene.presentationContext.length?self->_configScene.presentationContext:
                 (self->_saveScene.presentationContext?:@""));
            NSString *probeStatus=@"";
#if DEBUG
            probeStatus=self->_probeWorkerStatus?:@"";
#endif
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_gameplayContext=gameContext;self->_renderProbeStatus=probeStatus;
                dc_gamepad_set_context((uint32_t)scene,interactionCompleted,controlBusy);
                completion(error, device, scene, advanced, materialAdvanced, poseAdvanced, musicAdvanced, introState, skinAdvanced, gameplaySkinAdvanced, interactionCompleted);
            });
        }
    });
}
@end

@implementation DCVulkanContainerView
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.blackColor;
        _surface=[[DCVulkanSpriteView alloc] initWithFrame:self.bounds];
        [self addSubview:_surface];
    }
    return self;
}
- (void)setReservesControls:(BOOL)value { _reservesControls=value;[self setNeedsLayout]; }
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange];[self setNeedsLayout]; }
- (void)layoutSubviews {
    [super layoutSubviews];CGRect frame=self.bounds;
    if(_reservesControls) {
        UIEdgeInsets s=self.safeAreaInsets;dc_pc_touch_view v;
        if(dc_pc_touch_viewport(frame.size.width,frame.size.height,s.left,s.top,s.right,s.bottom,&v)==DC_OK)
            frame=CGRectMake(v.x,v.y,v.width,v.height);
    }
    _surface.frame=frame;
}
@end
