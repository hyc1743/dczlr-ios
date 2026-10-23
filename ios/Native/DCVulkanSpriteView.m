#import "DCVulkanSpriteView.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "dc_vk_sprite.h"
#include "dc_sprite_spv.h"
#include "dc_animation.h"
#import "DCArchive.h"
#include <math.h>

static const char dcRenderQueueKey;

@implementation DCVulkanSpriteView {
    dc_vk_sprite *_renderer;
    uintptr_t _texture;
    uintptr_t _startupTexture;
    uintptr_t _titleTextures[9];
    uint32_t _width, _height;
    uint32_t _startupWidth, _startupHeight;
    uint32_t _titleWidths[9], _titleHeights[9];
    BOOL _titleSceneLoaded;
    DCVulkanSpriteScene _presentedScene;
    NSInteger _selectedTitleOption;
    CFTimeInterval _lastStartupScan;
    CFTimeInterval _lastTitleScan;
    NSString *_deviceName;
    uint64_t _presentedFrames;
    dc_animation_state _diagnosticAnimation;
    uint32_t _lastDiagnosticTick;
    BOOL _diagnosticTickInitialized;
    BOOL _diagnosticAnimationAdvanced;
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
        dc_vk_sprite_destroy(self->_renderer);
        self->_renderer = NULL;
        self->_texture = 0;
        self->_startupTexture = 0;
        memset(self->_titleTextures, 0, sizeof(self->_titleTextures));
        memset(self->_titleWidths, 0, sizeof(self->_titleWidths));
        memset(self->_titleHeights, 0, sizeof(self->_titleHeights));
        self->_titleSceneLoaded = NO;
        self->_presentedScene = DCVulkanSpriteSceneDiagnostic;
        self->_diagnosticTickInitialized = NO;
        self->_diagnosticAnimationAdvanced = NO;
        self->_width = self->_height = 0;
    });
}
- (BOOL)tryLoadStartupCardFromDirectory:(NSString *)directory {
    if (_startupTexture || directory.length == 0 || CACurrentMediaTime() - _lastStartupScan < 1)
        return _startupTexture != 0;
    _lastStartupScan = CACurrentMediaTime();
    NSString *archivePath = [directory stringByAppendingPathComponent:@"RPP_02.pp"];
    NSURL *archiveURL = [NSURL fileURLWithPath:archivePath];
    NSError *error = nil;
    DCArchive *archive = [[DCArchive alloc] initWithURL:archiveURL error:&error];
    if (!archive) return NO; /* The user may still be importing the resource pack. */
    uint32_t index = UINT32_MAX;
    for (uint32_t i = 0; i < archive.entryCount; ++i) {
        if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:@"illusion.ema"] == NSOrderedSame) {
            index = i;
            break;
        }
    }
    if (index == UINT32_MAX) return NO;
    DCDecodedImage *image = [archive decodeImageAtIndex:index inputLimit:8 * 1024 * 1024
        outputLimit:64 * 1024 * 1024 error:&error];
    if (!image) return NO;
    if (dc_vk_sprite_upload(_renderer, image.width, image.height, image.rgba.bytes,
            image.rgba.length, &_startupTexture) != DC_OK) {
        _startupTexture = 0;
        return NO;
    }
    _startupWidth = image.width;
    _startupHeight = image.height;
    return YES;
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
    for (uint32_t i = 0; i < 9; ++i) {
        DCDecodedImage *image = [archive decodeImageAtIndex:indices[i] inputLimit:8 * 1024 * 1024
            outputLimit:64 * 1024 * 1024 error:&error];
        if (!image || dc_vk_sprite_upload(_renderer, image.width, image.height, image.rgba.bytes,
                image.rgba.length, &handles[i]) != DC_OK) {
            for (uint32_t j = 0; j < i; ++j) dc_vk_sprite_remove_texture(_renderer, handles[j]);
            return NO;
        }
        widths[i] = image.width;
        heights[i] = image.height;
    }
    memcpy(_titleTextures, handles, sizeof(handles));
    memcpy(_titleWidths, widths, sizeof(widths));
    memcpy(_titleHeights, heights, sizeof(heights));
    _titleSceneLoaded = YES;
    return YES;
}
- (void)destroyRenderer {
    dc_vk_sprite_destroy(_renderer);
    _renderer = NULL;
    _texture = 0;
    _startupTexture = 0;
    memset(_titleTextures, 0, sizeof(_titleTextures));
    memset(_titleWidths, 0, sizeof(_titleWidths));
    memset(_titleHeights, 0, sizeof(_titleHeights));
    _titleSceneLoaded = NO;
    _presentedScene = DCVulkanSpriteSceneDiagnostic;
    _diagnosticTickInitialized = NO;
    _diagnosticAnimationAdvanced = NO;
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
        dc_vk_sprite_config config = {.width = width, .height = height, .max_textures = 16, .initial_filter = 2,
            .vertex_spirv = dc_sprite_vert_spv, .vertex_spirv_bytes = sizeof(dc_sprite_vert_spv),
            .fragment_spirv = dc_sprite_frag_spv, .fragment_spirv_bytes = sizeof(dc_sprite_frag_spv),
            .metal_layer = (__bridge void *)layer};
        char error[512];
        if (dc_vk_sprite_create(&config, &_renderer, error, sizeof(error)) != DC_OK)
            return [NSString stringWithUTF8String:error];
        const uint8_t checker[] = {255,80,40,255, 40,220,100,255, 40,100,255,255, 250,230,100,255};
        if (dc_vk_sprite_upload(_renderer, 2, 2, checker, sizeof(checker), &_texture) != DC_OK) {
            NSString *message = [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
            [self releaseRenderer];
            return message;
        }
        dc_vk_sprite_info info;
        dc_vk_sprite_get_info(_renderer, &info);
        _deviceName = [NSString stringWithUTF8String:info.device_name];
        _width = width; _height = height;
    }
    [self tryLoadStartupCardFromDirectory:directory];
    BOOL titleReady = [self tryLoadTitleSceneFromDirectory:directory];
    BOOL showTitle = titleReady && time >= 2.0;
    dc_vk_sprite_item draws[5] = {0};
    size_t drawCount = 0;
    BOOL animationMoved = NO;
    if (showTitle) {
        /* The original title assets and hit regions use 1024x768 coordinates. */
        float scale = fminf((float)_width / 1024.0f, (float)_height / 768.0f);
        float offsetX = ((float)_width - 1024.0f * scale) * 0.5f;
        float offsetY = ((float)_height - 768.0f * scale) * 0.5f;
        if (touching) {
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            _selectedTitleOption = -1;
            for (NSInteger row = 0; row < 5; ++row) {
                float buttonY = 400.0f + 72.0f * row;
                if (gameX >= 702.0f && gameX < 958.0f && gameY >= buttonY && gameY < buttonY + 48.0f) {
                    _selectedTitleOption = row + 2;
                    break;
                }
            }
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
        ADD_TITLE_LAYER(7, 702, 544);
        ADD_TITLE_LAYER(8, 702, 616);
        if (touching) {
            float screenX = (x + 1.0f) * 0.5f * _width;
            float screenY = (1.0f - y) * 0.5f * _height;
            float gameX = (screenX - offsetX) / scale;
            float gameY = (screenY - offsetY) / scale;
            ADD_TITLE_LAYER(0, gameX - 6.4f, gameY - 6.4f);
        }
#undef ADD_TITLE_LAYER
    } else if (_startupTexture) {
        float scale = fminf((float)_width / _startupWidth, (float)_height / _startupHeight);
        dc_vk_sprite_item *item = &draws[drawCount++];
        item->texture = _startupTexture; item->blend_mode = 3;
        item->pose.width = _startupWidth * scale; item->pose.height = _startupHeight * scale;
        item->pose.x = (_width - item->pose.width) * 0.5f;
        item->pose.y = (_height - item->pose.height) * 0.5f;
        item->pose.z = 0.5f; item->pose.scale_x = item->pose.scale_y = item->pose.alpha = 1;
        item->pose.red = item->pose.green = item->pose.blue = 1;
        item->pose.u0 = 0; item->pose.u1 = 1; item->pose.v0 = 0; item->pose.v1 = 1;
    } else {
        double milliseconds = time * 1000.0;
        if (!isfinite(milliseconds) || milliseconds < 0) return @"Invalid diagnostic animation time";
        uint32_t tick = (uint32_t)fmod(milliseconds, 4294967296.0);
        uint32_t delta = _diagnosticTickInitialized ? tick - _lastDiagnosticTick : 0;
        if (!_diagnosticTickInitialized) {
            _diagnosticAnimation = (dc_animation_state){.blend = 1};
        }
        /* A self-authored repeating clip exercises the reconstructed numeric
         * update in the actual host without supplying any original assets. */
        dc_animation_clip clip = {.first_frame = 0, .last_frame = 6.283185307179586f, .loop = 1};
        dc_animation_timing timing = {.duration_seconds = 18};
        dc_animation_tick_result update;
        dc_status animationStatus = dc_animation_tick(&_diagnosticAnimation, &clip, &timing,
            1, delta, 1, tick, &update);
        if (animationStatus != DC_OK)
            return [NSString stringWithFormat:@"Native animation tick failed: %d", animationStatus];
        _diagnosticTickInitialized = YES;
        _lastDiagnosticTick = tick;
        animationMoved = delta > 0 && update.samples[0] != update.previous_frame;
        float side = fminf(_width, _height) * 0.4f;
        dc_vk_sprite_item *item = &draws[drawCount++];
        item->texture = _texture; item->blend_mode = 3; item->point_filter = 1;
        item->pose = (dc_sprite_pose){.width = side, .height = side,
            .x = _width * (0.5f + x * 0.3f), .y = _height * (0.5f - y * 0.3f), .z = 0.5f,
            .origin_x = 0.5f, .origin_y = 0.5f, .scale_x = 1, .scale_y = 1, .alpha = 1,
            .rotation = update.samples[0], .red = 1, .green = 1, .blue = 1,
            .u0 = 0, .u1 = 1, .v0 = 0, .v1 = 1};
    }
    const uint8_t clear[] = {10,15,26,255};
    if (dc_vk_sprite_render(_renderer, draws, drawCount, clear, NULL, 0) != DC_OK) {
        NSString *message = [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
        [self destroyRenderer];
        return message;
    }
    /* Report only the scene whose draw was successfully presented. Loading a
     * texture or drawing the fallback must not certify a later game screen. */
    _presentedScene = showTitle ? DCVulkanSpriteSceneTitle :
        (_startupTexture ? DCVulkanSpriteSceneStartupCard : DCVulkanSpriteSceneDiagnostic);
    if (animationMoved) _diagnosticAnimationAdvanced = YES;
    ++_presentedFrames;
    return nil;
}
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time touching:(BOOL)touching
            completion:(void (^)(NSString *, NSString *, DCVulkanSpriteScene, BOOL))completion {
    if (!self.window) { completion(@"Vulkan sprite view is not attached to a window", @"", DCVulkanSpriteSceneDiagnostic, NO); return; }
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
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error, device, scene, advanced); });
        }
    });
}
@end
