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
#include "dc_menu.h"
#include "dc_save.h"
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

@implementation DCVulkanSpriteView {
    dc_vk_sprite *_renderer;
    uintptr_t _texture;
    DCStartupScene *_startupScene;
    DCGameAudio *_gameAudio;
    DCIntroScene *_introScene;
    DCGameScene *_gameScene;
    dc_title_state _titleState;
    BOOL _titleStateInitialized;
    dc_menu_state _titleMenu;
    BOOL _titleMenuInitialized,_previousTitleTouch;
    BOOL _previousGameplayTouch;
    BOOL _titleUnlocksLoaded,_editUnlocked,_extraUnlocked;
    uintptr_t _titleTextures[9];
    uint32_t _width, _height;
    uint32_t _titleWidths[9], _titleHeights[9];
    BOOL _titleSceneLoaded;
    DCVulkanSpriteScene _presentedScene;
    NSInteger _selectedTitleOption;
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
- (void)releaseRenderer {
    dispatch_async(_renderQueue, ^{
        [self->_gameAudio pause];
        [self->_introScene pause];
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
    NSString *gameError=nil;
    _gameScene=[[DCGameScene alloc] initWithDirectory:directory renderer:_renderer error:&gameError];
    if(!_gameScene)return gameError ?: @"Chapter 3 scene initialization failed";
    _previousGameplayTouch=NO;
    return nil;
}
- (void)destroyRenderer {
    [_gameScene detachRenderer];
    [_introScene detachRenderer];
    [_startupScene detachRenderer];
    dc_vk_sprite_destroy(_renderer);
    _renderer = NULL;
    _texture = 0;
    memset(_titleTextures, 0, sizeof(_titleTextures));
    memset(_titleWidths, 0, sizeof(_titleWidths));
    memset(_titleHeights, 0, sizeof(_titleHeights));
    _titleSceneLoaded = NO;
    _gameScene = nil;
    _previousGameplayTouch = NO;
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
- (NSString *)drawAtX:(float)x y:(float)y time:(double)time
                layer:(CAMetalLayer *)layer width:(uint32_t)width height:(uint32_t)height
         dataDirectory:(NSString *)directory touching:(BOOL)touching {
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
    if (_startupScene && !_startupScene.finished) {
        double milliseconds = time * 1000.0;
        if (!isfinite(milliseconds) || milliseconds < 0) return @"Invalid startup animation time";
        uint32_t tick = (uint32_t)fmod(milliseconds, 4294967296.0);
        NSString *error = [_startupScene drawAtTick:tick touching:touching width:_width height:_height];
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
    if(_gameScene.gameFinished && touching && !_previousGameplayTouch){
        [_gameScene detachRenderer];
        _gameScene=nil;
        [_introScene detachRenderer];
        _introScene=nil;
        _titleStateInitialized=NO;
        _titleMenuInitialized=NO;
        _previousTitleTouch=NO;
        _previousGameplayTouch=NO;
    }
    if(_introScene) {
        if(_introScene.completed) {
            if(_introScene) {
                NSString *gameError=[self startGameSceneFromDirectory:directory];
                if(gameError)return gameError;
                NSString *gameFailure=[_gameScene drawAtTick:sceneTick inputX:x inputY:y touching:touching width:_width height:_height];
                if(gameFailure)return gameFailure;
                _previousGameplayTouch=touching;
                _presentedScene=_gameScene.gameFinished ? DCVulkanSpriteSceneGameComplete : DCVulkanSpriteSceneGameplay;
                ++_presentedFrames;
                return nil;
            }
        }
        if(_introScene) {
        NSString *failure=[_introScene drawWithRenderer:_renderer transition:_startupScene tick:sceneTick
            touching:touching width:_width height:_height];
        if(failure)return failure;
        _presentedScene=DCVulkanSpriteSceneIntro;++_presentedFrames;return nil;
        }
    }
    dc_vk_sprite_item draws[5] = {0};
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
        if (!_gameAudio) {
            NSString *audioError=nil;
            _gameAudio=[[DCGameAudio alloc] initWithDirectory:directory error:&audioError];
            if(!_gameAudio)return audioError ?: @"Title audio resources are unavailable";
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
        if (acceptsInput && (touching || _previousTitleTouch)) {
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
            uint8_t input=touching ? (_previousTitleTouch?2:1) : 3;
            int32_t result;
            dc_status menuStatus=dc_menu_step(&_titleMenu,buttons,5,(int32_t)gameX,(int32_t)gameY,1,input,&result);
            if(menuStatus!=DC_OK)return @"Title menu update failed";
            _selectedTitleOption=_titleMenu.active ? _titleMenu.hover+2 : -1;
            menuResult=result;menuRow=_titleMenu.hover;
        }
        _previousTitleTouch=touching;
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
                 * planner. The local port resumes the persisted player slot
                 * directly when ENTER=2 arrives. */
            } else if(command.kind==DC_TITLE_ENTER) {
                if(command.value==2) {
                    NSString *gameError=[self startGameSceneFromDirectory:directory];
                    if(gameError)return gameError;
                    [_introScene detachRenderer];
                    _introScene=nil;
                } else if(command.value!=1) {
                    return [NSString stringWithFormat:@"Title destination %u is not implemented",command.value];
                }
            } else if(command.kind==DC_TITLE_INIT_GAME) {
                NSString *introError=nil;
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
                touching:touching width:_width height:_height];
            if(failure)return failure;
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
        if (touching) {
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            ADD_TITLE_LAYER(0, gameX - 6.4f, gameY - 6.4f);
        }
#undef ADD_TITLE_LAYER
    } else {
        if(_gameScene) {
            NSString *gameFailure=[_gameScene drawAtTick:sceneTick inputX:x inputY:y touching:touching width:_width height:_height];
            if(gameFailure)return gameFailure;
            _previousGameplayTouch=touching;
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
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time touching:(BOOL)touching
            completion:(void (^)(NSString *, NSString *, DCVulkanSpriteScene, BOOL, BOOL, BOOL, BOOL, NSString *, BOOL, BOOL))completion {
    if (!self.window) { completion(@"Vulkan sprite view is not attached to a window", @"", DCVulkanSpriteSceneDiagnostic, NO, NO, NO, NO, @"", NO); return; }
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGSize drawableSize = layer.drawableSize;
    uint32_t width = (uint32_t)drawableSize.width, height = (uint32_t)drawableSize.height;
    NSString *directory = [self.startupDataDirectory copy] ?: @"";
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            NSString *error = [self drawAtX:x y:y time:time layer:layer width:width height:height dataDirectory:directory touching:touching];
            NSString *device = self->_deviceName ?: @"";
            DCVulkanSpriteScene scene = self->_presentedScene;
            BOOL advanced = self->_diagnosticAnimationAdvanced;
            BOOL materialAdvanced = self->_diagnosticMaterialAdvanced;
            BOOL poseAdvanced = self->_diagnosticPoseAdvanced;
            BOOL musicAdvanced = self->_introScene ? self->_introScene.audioAdvanced : self->_gameAudio.musicAdvanced;
            NSString *introState=self->_introScene.presentationState ?: @"";
            BOOL skinAdvanced=self->_startupScene.skinAdvanced;
            BOOL interactionCompleted=self->_gameScene.interactionCompleted;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error, device, scene, advanced, materialAdvanced, poseAdvanced, musicAdvanced, introState, skinAdvanced, interactionCompleted); });
        }
    });
}
@end
