#import "DCVulkanSpriteView.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
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

static void dc_write_word_le(uint8_t *out, uint32_t bits) {
    for (uint32_t i = 0; i < 4; ++i) out[i] = (uint8_t)(bits >> (8 * i));
}

static void dc_write_float_le(uint8_t *out, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    dc_write_word_le(out, bits);
}

static BOOL dc_pc_key_held(const dc_pc_frame *input, uint32_t scan) {
    return input && scan < DC_PC_KEY_COUNT && (input->keys[scan] & 1u) != 0;
}
static BOOL dc_pc_key_pressed(const dc_pc_frame *input, uint32_t scan) {
    return input && scan < DC_PC_KEY_COUNT && input->keys[scan] == 3;
}
static void dc_merge_pc_actions(dc_pc_frame input, dc_pad_frame *controller) {
    if (!controller) return;
    /* The original PC emergency key and Alt+F4 both leave gameplay through
     * the same safe title transition on iOS. They never terminate the app. */
    if (dc_pc_key_pressed(&input,1) ||
        (dc_pc_key_held(&input,0x38) && dc_pc_key_pressed(&input,0x3e))) {
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
    BOOL _galleryMode;
    uint32_t _galleryIndex;
    uintptr_t _galleryTexture;
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
        _renderQueue = dispatch_queue_create("org.example.portlab.vulkan-render", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_renderQueue, &dcRenderQueueKey, (void *)&dcRenderQueueKey, NULL);
    }
    return self;
}
- (NSString *)deviceName { return _deviceName; }
- (uint64_t)presentedFrames { return _presentedFrames; }
- (DCVulkanSpriteScene)presentedScene { return _presentedScene; }
- (BOOL)controllerMovementAdvanced { return _gameScene.controllerMovementAdvanced; }
- (BOOL)controllerCameraAdvanced { return _gameScene.controllerCameraAdvanced; }
- (BOOL)gameplaySaveCompleted { return _gameScene.manualSaveCompleted; }
- (NSString *)gameplayContext { return _gameplayContext?:@""; }
- (NSString *)renderProbeStatus { return _renderProbeStatus?:@""; }
- (void)releaseRenderer {
    dispatch_async(_renderQueue, ^{
        [self->_gameAudio pause];
        [self->_introScene pause];
        [self->_configScene pause];
        [self->_saveScene pause];
        [self->_dummyScene pause];
        self->_previousTitleTouch=NO;
        self->_previousGameplayTouch=NO;
        [self destroyRenderer];
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
- (NSString *)startGameSceneFromDirectory:(NSString *)directory {
    if(_gameScene)return nil;
    if(_gameAudio){NSString *audioError=[_gameAudio prepareGameplayAudio];if(audioError)return audioError;}
    NSString *gameError=nil;
    BOOL resume=_resumeNextScene;_resumeNextScene=NO;
    _gameScene=[[DCGameScene alloc] initWithDirectory:directory renderer:_renderer chapter:_story.chapter
        mapSelector:_story.map stage:_story.stage stageProgress:_story.stage<DC_STORY_STAGES?_story.stages[_story.stage].progress:0
        sceneTypeOverride:_endingSceneTypeOverride resumeSavedPlayer:resume error:&gameError];
    if(!_gameScene)return gameError ?: @"Story scene initialization failed";
    _gameScene.transitionScene=_startupScene;
    [self ensureFlowState];
    if(_flowInitialized) {
        _flowState.meta.previous_type=_flowState.meta.scene_type;
        _flowState.meta.scene_type=(uint8_t)_gameScene.sceneType;
        _flowState.meta.chapter=(uint8_t)_story.chapter;
        _flowState.meta.map=(uint8_t)_story.map;_flowState.meta.stage=(uint8_t)_story.stage;
        [self syncFlowFlagsFromStory];
    }
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
    return nil;
}
- (NSString *)enterConfigSceneFromDirectory:(NSString *)directory {
    if(!_configuration)[self loadConfigurationFromDirectory:directory];
    NSString *error=nil;
    _configScene=[[DCConfigScene alloc] initWithDirectory:directory renderer:_renderer configuration:_configuration transition:_startupScene error:&error];
    if(!_configScene)return error?:@"Configuration page initialization failed";
    _systemOwnerType=_gameScene?_gameScene.sceneType:1;_systemOwnerChapter=_story.chapter;
    [_gameAudio suspendForSystemPage];
    return nil;
}
- (NSString *)enterSaveSceneFromDirectory:(NSString *)directory {
    NSString *error=nil;
    _saveScene=[[DCSaveScene alloc] initWithDirectory:directory renderer:_renderer transition:_startupScene
        ownerSceneType:_gameScene?_gameScene.sceneType:1 chapter:_story.chapter error:&error];
    if(!_saveScene)return error?:@"Save page initialization failed";
    _systemOwnerType=_gameScene?_gameScene.sceneType:1;_systemOwnerChapter=_story.chapter;
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
- (NSString *)handleIntroAuxiliaryFromDirectory:(NSString *)directory {
    uint32_t destination=_introScene.auxiliaryDestination;
    if(!destination)return nil;
    [_introScene consumeAuxiliaryDestination];
    if(destination==2)return [self enterConfigSceneFromDirectory:directory];
    if(destination==7)return [self enterSaveSceneFromDirectory:directory];
    if(destination==5)return [self enterDummySceneFromDirectory:directory owner:3];
    if(destination==6){
        [_introScene detachRenderer];_introScene=nil;
        _titleStateInitialized=NO;_titleMenuInitialized=NO;_previousTitleTouch=NO;
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
    meta.chapter=(uint8_t)_story.chapter;meta.map=(uint8_t)_story.map;meta.stage=(uint8_t)_story.stage;
    if(_gameScene)meta.scene_type=(uint8_t)_gameScene.sceneType;
    char name[16];if(dc_save_slot_name(slot,name,sizeof(name))!=DC_OK)return @"Original save slot number rejected";
    NSMutableData *encoded=[NSMutableData dataWithLength:DC_SAVE_SLOT_BYTES];
    if(dc_save_slot_encode(_numericState.bytes,_numericState.length,&meta,encoded.mutableBytes,encoded.length)!=DC_OK)return @"Original save state encoding failed";
    NSString *saveDirectory=[directory stringByAppendingPathComponent:@"save"];
    [[NSFileManager defaultManager] createDirectoryAtPath:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    if(![encoded writeToFile:[saveDirectory stringByAppendingPathComponent:[NSString stringWithUTF8String:name]] options:NSDataWritingAtomic error:nil])return @"Original save slot write failed";
    return nil;
}
- (NSString *)resumeSystemOwnerAtTick:(uint32_t)tick {
    if(_gameScene){[_gameScene resumeAtTick:tick];}
    if(_introScene){[_introScene resumeFromAuxiliaryAtTick:tick];}
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
    _story.chapter=meta.chapter;_story.map=meta.map;_story.stage=meta.stage;_storyInitialized=YES;
    for(unsigned i=0;i<DC_STORY_STAGES;++i){size_t base=(size_t)i*0x2198;_story.stages[i].flag_a=p[base];_story.stages[i].flag_b=p[base+1];_story.stages[i].progress=p[base+0x23];}
    [_saveScene detachRenderer];_saveScene=nil;
    if(![_gameAudio resumeAfterSystemPage])return @"System audio resume failed";
    _resumeNextScene=YES;NSString *error=[self enterStoryChapter:_story.chapter directory:directory];
    if(error)return error;[_gameScene resumeAtTick:tick];return nil;
}
- (NSString *)handleGameplayTransitionFromDirectory:(NSString *)directory {
    if(!_gameScene || !_gameScene.chapterEndAction)return nil;
    uint32_t action=_gameScene.chapterEndAction;
    if(action==2) {
        [self ensureFlowState];
        if(_flowInitialized && _gameScene.sceneType>=4 && _gameScene.sceneType<=6) {
            dc_flow_exit_metrics metrics={
                .level=_gameScene.flowLevel,
                .flag_b=_gameScene.flowFlagB,
                .count=_gameScene.flowCount,
                .outcome_a=_gameScene.stageOutcomeA,
                .outcome_b=_gameScene.stageOutcomeB};
            dc_flow_result flowResult;
            if(dc_flow_scene_exit(&_flowState,&metrics,&flowResult)==DC_OK &&
               flowResult.destination_type!=13) {
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
        return [self enterStoryChapter:_story.chapter directory:directory];
    } else if(action==6) {
        /* Edit presentation finished: return to the title. */
        [_gameScene detachRenderer];
        _gameScene=nil;
        _titleStateInitialized=NO;
        _titleMenuInitialized=NO;
        _previousTitleTouch=NO;
        _previousGameplayTouch=NO;
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
            _story=loaded;_storyInitialized=YES;return;
        }
    }
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
}
- (NSString *)enterStoryChapter:(uint32_t)chapter directory:(NSString *)directory {
    dc_story_chapter profile;
    if(dc_story_chapter_profile(chapter,&profile)!=DC_OK)return @"Story chapter profile rejected";
    _story.chapter=chapter;
    if(profile.map>=0)_story.map=(uint32_t)profile.map;
    if(profile.stage>=0)_story.stage=(uint32_t)profile.stage;
    _storyInitialized=YES;
    [self updateFlowMetaForChapter:chapter profile:&profile];
    [self saveStoryToDirectory:directory];
    /* Consume the completed script before installing its destination. Keeping
     * it here would re-enter this chapter on every subsequent draw. */
    [_introScene detachRenderer];
    _introScene=nil;
    [_gameScene detachRenderer];
    _gameScene=nil;
    [_endingScene detachRenderer];
    _endingScene=nil;
    _endingSceneTypeOverride=0;
    if(profile.script>=0) {
        _resumeNextScene=NO;
        NSString *introError=nil;
        _introScene=[[DCIntroScene alloc] initWithDirectory:directory startChapter:chapter error:&introError];
        if(!_introScene)return introError ?: @"Mid-story script entry failed";
    } else if(profile.scene==DC_STORY_SCENE_ENDING) {
        NSString *endingError=nil;
        _endingScene=[[DCEndingScene alloc] initWithDirectory:directory renderer:_renderer transition:_startupScene
            story:&_story error:&endingError];
        if(!_endingScene)return endingError?:@"Ending selector initialization failed";
        _previousGameplayTouch=NO;_suppressGameplayTouch=YES;
    } else {
        NSString *gameError=[self startGameSceneFromDirectory:directory];
        if(gameError)return gameError;
        _previousGameplayTouch=NO;
        _suppressGameplayTouch=YES;
    }
    return nil;
}
- (void)loadGalleryImageFromDirectory:(NSString *)directory {
    if(_galleryTexture){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}
    if(!_story.unlocked && _galleryIndex>0)_galleryIndex=0;
    NSString *name=[NSString stringWithFormat:@"M_c%03uN.ema",1+_galleryIndex];
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"rpsp_00.pp"]] error:&reason];
    if(!archive)return;
    for(uint32_t i=0;i<archive.entryCount;++i) {
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]!=NSOrderedSame)continue;
        DCDecodedImage *image=[archive decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];
        if(!image)return;
        dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&_galleryTexture);
        return;
    }
}
- (void)destroyRenderer {
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
    _galleryMode=NO;_galleryIndex=0;
    _galleryTexture=0;
    _gameScene = nil;
    _configScene=nil;_saveScene=nil;_numericState=nil;_configuration=nil;
    _dummyScene=nil;_dummyOwner=0;_endingScene=nil;_endingSceneTypeOverride=0;
    _previousGameplayTouch = NO;
    _suppressGameplayTouch = NO;
    _lastTitleScan = 0;
    _presentedScene = DCVulkanSpriteSceneDiagnostic;
    _diagnosticTickInitialized = NO;
    _diagnosticAnimationAdvanced = NO;
    _diagnosticMaterialAdvanced = NO;
    _diagnosticPoseAdvanced = NO;
    _width = _height = 0;
}
- (void)dealloc {
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
    } else if (pcInput.mouse[0]&1u) {
        /* A virtual Z/left-click is still a game tap even when no physical
         * pointer is connected. Touchscreen coordinates remain authoritative
         * for simultaneous finger input. */
        touching=YES;
    }
    dc_merge_pc_actions(pcInput,&controller);
    if (!width || !height) return @"CAMetalLayer has empty drawable size";
    if (_renderer && (_width != width || _height != height)) [self destroyRenderer];
    if (!_renderer) {
        dc_vk_sprite_config config = {.width = width, .height = height, .max_textures = 128, .initial_filter = 2,
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
            [self releaseRenderer];
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
        NSString *error = [_startupScene drawAtTick:tick touching:(touching || (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS))) width:_width height:_height];
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
            else if(_dummyOwner==3)[_introScene resumeFromAuxiliaryAtTick:sceneTick];
            _dummyOwner=0;
        }
        return nil;
    }
    if(_endingScene) {
        NSString *failure=[_endingScene drawAtTick:sceneTick pcInput:pcInput width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        if(_endingScene.action==2){
            [_endingScene detachRenderer];_endingScene=nil;_endingSceneTypeOverride=0;
            _titleStateInitialized=NO;_titleMenuInitialized=NO;_previousTitleTouch=NO;
        } else if(_endingScene.action==3||_endingScene.action==5){
            uint32_t action=_endingScene.action;
            [_endingScene detachRenderer];_endingScene=nil;
            NSString *pageError=action==3?[self enterConfigSceneFromDirectory:directory]:
                [self enterSaveSceneFromDirectory:directory];
            if(pageError)return pageError;
        } else if(_endingScene.action==4){
            return @"Game session ended";
        } else if(_endingScene.routeReady){
            static const uint32_t maps[7]={0,1,3,4,5,7,8};
            uint32_t category=_endingScene.category;
            _story.map=maps[_endingScene.mapIndex];_story.chapter=24;
            uint32_t stage=_endingScene.firstStage<=2?_endingScene.firstStage:0;
            _story.stage=2-stage;
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
    if(_configScene) {
        NSString *failure=[_configScene drawAtTick:sceneTick pcInput:pcInput width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneGameplay;++_presentedFrames;
        uint32_t action=_configScene.action;
        if(action) {
            if(action==1) {
                NSData *settings=_configScene.configuration;[self loadConfigurationFromDirectory:directory];
                _configuration=settings;[settings writeToFile:[directory stringByAppendingPathComponent:@"gcd.cfg"] options:NSDataWritingAtomic error:nil];
                if(_gameScene)[_gameScene applyConfiguration:(const dc_config *)settings.bytes];
                [_gameAudio applyConfiguration:settings];
                return [self resumeSystemOwnerAtTick:sceneTick];
            }
            if(action==2){[_configScene detachRenderer];_configScene=nil;[_gameScene detachRenderer];_gameScene=nil;_titleStateInitialized=NO;_titleMenuInitialized=NO;return nil;}
            if(action==3){[_configScene detachRenderer];_configScene=nil;return [self enterSaveSceneFromDirectory:directory];}
            if(action==4)return @"Game session ended";
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
            if(action==1)return [self resumeSystemOwnerAtTick:sceneTick];
            if(action==2){[_saveScene detachRenderer];_saveScene=nil;[_gameScene detachRenderer];_gameScene=nil;_titleStateInitialized=NO;_titleMenuInitialized=NO;return nil;}
            if(action==3){[_saveScene detachRenderer];_saveScene=nil;return [self enterConfigSceneFromDirectory:directory];}
            if(action==4)return @"Game session ended";
            if(action==5)return [self loadSelectedOriginalSlot:_saveScene.selectedSlotData directory:directory tick:sceneTick];
            if(action==6)return [self enterDummySceneFromDirectory:directory owner:2];
        }
        return nil;
    }
    if(_gameScene && (controller.pressed&DC_PAD_MINUS)) {
        [_gameAudio cancelGameplayVoice];
        [_gameScene detachRenderer];
        _gameScene=nil;
        [_introScene detachRenderer];_introScene=nil;
        _titleStateInitialized=NO;_titleMenuInitialized=NO;
        _galleryMode=NO;
        _previousTitleTouch=NO;_previousGameplayTouch=NO;
        showTitle=titleReady;
    }
    if(_introScene) {
        if(_introScene.completed) {
            if(_introScene) {
                uint32_t pending=_introScene.pendingChapter;
                if(pending>=DC_STORY_CHAPTERS) {
                    /* The final script finished: the story is complete. */
                    _story.unlocked=1;
                    for(uint32_t i=0;i<DC_STORY_STAGES;++i)_story.stages[i].progress=1;
                    _storyInitialized=YES;
                    [self saveStoryToDirectory:directory];
                    [_introScene detachRenderer];
                    _introScene=nil;
                    [_gameScene detachRenderer];
                    _gameScene=nil;
                    _titleStateInitialized=NO;
                    _titleMenuInitialized=NO;
                    _previousTitleTouch=NO;
                    _previousGameplayTouch=NO;
                    _presentedScene=DCVulkanSpriteSceneGameComplete;
                    ++_presentedFrames;
                    return nil;
                } else {
                    if(pending==24) {
                        /* Original end-of-script dispatcher: entering the ending
                           chapter unlocks all three stage progress flags. */
                        _story.unlocked=1;
                        for(uint32_t i=0;i<DC_STORY_STAGES;++i)_story.stages[i].progress=1;
                        _storyInitialized=YES;
                        [self saveStoryToDirectory:directory];
                    }
                    NSString *enterError=[self enterStoryChapter:pending directory:directory];
                    if(enterError)return enterError;
                    if(_introScene) {
                        NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
                            touching:(touching || (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS))) width:_width height:_height];
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
        NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
            touching:(touching || (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS))) width:_width height:_height];
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
            for (uint32_t slot=0;slot<80;++slot) {
                NSString *name=[NSString stringWithFormat:@"save/RP_%02u.sav",slot];
                NSString *path=[directory stringByAppendingPathComponent:name];
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
                NSError *saveError=nil;
                NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:&saveError];
                if(!attributes || [attributes[NSFileSize] unsignedLongLongValue]<DC_SAVE_RECORD_BYTES)
                    return @"Game save metadata has an invalid size";
                NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:path];
                if(!handle)return @"Game save metadata could not be opened";
                NSData *data=[handle readDataUpToLength:DC_SAVE_RECORD_BYTES error:&saveError];
                [handle closeFile];
                if(!data)return saveError.localizedDescription;
                dc_save_unlocks unlocked;
                if(dc_save_get_unlocks(data.bytes,data.length,&unlocked)!=DC_OK)return @"Game save metadata was rejected";
                _editUnlocked |= unlocked.edit!=0;_extraUnlocked |= unlocked.extra!=0;
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
        NSString *audioError=[_gameAudio startTitleMusic];
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
        if (acceptsInput && (pcInput.active || touching || _previousTitleTouch)) {
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
            uint8_t input=pcInput.active?pcInput.mouse[0]:(touching ? (_previousTitleTouch?1:3) : (_previousTitleTouch?2:0));
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
        _previousTitleTouch=touching;
        if(_galleryMode) {
            if(menuResult==1) {
                if(menuRow==0){if(_galleryIndex>0)--_galleryIndex;[self loadGalleryImageFromDirectory:directory];}
                else if(menuRow==1){++_galleryIndex;[self loadGalleryImageFromDirectory:directory];}
                else if(menuRow==2){_galleryMode=NO;if(_galleryTexture){dc_vk_sprite_remove_texture(_renderer,_galleryTexture);_galleryTexture=0;}}
            }
            menuResult=-1;menuRow=-1;
        }
        dc_title_input titleInput={.transition_ready=transitionReady,.selection_busy=_gameAudio.selectionBusy,
            .menu_result=menuResult,.menu_row=menuRow};
        dc_title_plan titlePlan;
        if(dc_title_build_plan(&_titleState,&titleInput,&titlePlan)!=DC_OK)return @"Title action planning failed";
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
                    _story.chapter=3;_story.map=0;_story.stage=2;
                    _storyInitialized=YES;
                    [_gameScene detachRenderer];_gameScene=nil;
                    NSString *editError=[self startGameSceneFromDirectory:directory];
                    if(editError)return editError;
                    if(_gameScene)[_gameScene setEditMode:YES];
                } else if(command.value==4) {
                    /* Original Extra destination: the title gallery grid whose
                     * rows unlock with the story stage flags. */
                    _galleryMode=YES;
                    _selectedTitleOption=-1;
                } else if(command.value==6) {
                    NSString *configError=[self enterConfigSceneFromDirectory:directory];
                    if(configError)return configError;
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
                if([_startupScene requestTransition:3 tick:sceneTick]!=DC_OK ||
                   [_startupScene requestTransition:4 tick:sceneTick]!=DC_OK)return @"Intro entry transition failed";
            } else if(command.kind==DC_TITLE_QUIT) {
                return @"Game session ended";
            } else return @"Title destination adapter is not implemented";
        }
        _titleState=titlePlan.next;
        if(_introScene) {
            NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
                touching:(touching || (controller.pressed&(DC_PAD_A|DC_PAD_B|DC_PAD_PLUS))) width:_width height:_height];
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
        ADD_TITLE_LAYER(1, 0, 0);
        if (_selectedTitleOption >= 2 && _selectedTitleOption <= 6)
            ADD_TITLE_LAYER((uint32_t)_selectedTitleOption, 702, 400 + 72 * (_selectedTitleOption - 2));
        if (!_editUnlocked) ADD_TITLE_LAYER(7, 702, 544);
        if (!_extraUnlocked) ADD_TITLE_LAYER(8, 702, 616);
        if (touching && !pcInput.active) {
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            ADD_TITLE_LAYER(0, gameX - 6.4f, gameY - 6.4f);
        }
#undef ADD_TITLE_LAYER
        if(_galleryMode) {
            if(!_galleryTexture)[self loadGalleryImageFromDirectory:directory];
            if(_galleryTexture) {
                dc_vk_sprite_item *item=&draws[drawCount++];
                item->texture=_galleryTexture;item->blend_mode=3;
                float side=fminf(1024.0f*scale,768.0f*scale);
                item->pose=(dc_sprite_pose){.width=side,.height=side*.75f,
                    .x=offsetX+(1024*scale-side)*.5f,.y=offsetY+(768*scale-side*.75f)*.5f,
                    .z=.6f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
            }
        }
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
    if (!self.window) { completion(@"Vulkan sprite view is not attached to a window", @"", DCVulkanSpriteSceneDiagnostic, NO, NO, NO, NO, @"", NO, NO, NO); return; }
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGSize drawableSize = layer.drawableSize;
    uint32_t width = (uint32_t)drawableSize.width, height = (uint32_t)drawableSize.height;
    NSString *directory = [self.startupDataDirectory copy] ?: @"";
    if([self.superview isKindOfClass:DCVulkanContainerView.class] && self.bounds.size.width>0 && self.bounds.size.height>0) {
        CGSize inputSize=self.superview.bounds.size;
        pcInput.x=(pcInput.x*inputSize.width-self.frame.origin.x)/self.bounds.size.width;
        pcInput.y=(pcInput.y*inputSize.height-self.frame.origin.y)/self.bounds.size.height;
    }
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            NSString *error = [self drawAtX:x y:y time:time layer:layer width:width height:height dataDirectory:directory touching:touching controller:controller pcInput:pcInput];
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
            NSString *gameContext=self->_gameScene.presentationContext?:@"";
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
