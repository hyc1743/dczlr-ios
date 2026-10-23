#import "DCVulkanSpriteView.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "dc_vk_sprite.h"
#include "dc_sprite_spv.h"
#import "DCArchive.h"
#include <math.h>

static const char dcRenderQueueKey;

@implementation DCVulkanSpriteView {
    dc_vk_sprite *_renderer;
    uintptr_t _texture;
    uintptr_t _startupTexture;
    uint32_t _width, _height;
    uint32_t _startupWidth, _startupHeight;
    CFTimeInterval _lastStartupScan;
    NSString *_deviceName;
    uint64_t _presentedFrames;
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
        _renderQueue = dispatch_queue_create("org.example.portlab.vulkan-render", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_renderQueue, &dcRenderQueueKey, (void *)&dcRenderQueueKey, NULL);
    }
    return self;
}
- (NSString *)deviceName { return _deviceName; }
- (uint64_t)presentedFrames { return _presentedFrames; }
- (BOOL)startupCardLoaded { return _startupTexture != 0; }
- (void)releaseRenderer {
    dispatch_async(_renderQueue, ^{
        dc_vk_sprite_destroy(self->_renderer);
        self->_renderer = NULL;
        self->_texture = 0;
        self->_startupTexture = 0;
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
- (void)destroyRenderer {
    dc_vk_sprite_destroy(_renderer);
    _renderer = NULL;
    _texture = 0;
    _startupTexture = 0;
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
         dataDirectory:(NSString *)directory {
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
    BOOL originalCard = _startupTexture != 0;
    float sourceWidth = originalCard ? _startupWidth : 2;
    float sourceHeight = originalCard ? _startupHeight : 2;
    float scale = originalCard ? fminf((float)_width / sourceWidth, (float)_height / sourceHeight)
                               : fminf(_width, _height) * 0.4f / 2;
    float quadWidth = sourceWidth * scale, quadHeight = sourceHeight * scale;
    float originX = originalCard ? 0 : 0.5f;
    float originY = originalCard ? 0 : 0.5f;
    float spriteX = originalCard ? (_width - quadWidth) * 0.5f + x * _width * 0.3f
                                 : _width * (0.5f + x * 0.3f);
    float spriteY = originalCard ? (_height - quadHeight) * 0.5f - y * _height * 0.3f
                                 : _height * (0.5f - y * 0.3f);
    dc_vk_sprite_item draw = {.texture = originalCard ? _startupTexture : _texture, .blend_mode = 3, .point_filter = 0,
        .pose = {.width = quadWidth, .height = quadHeight, .x = spriteX, .y = spriteY,
            .z = 0, .origin_x = originX, .origin_y = originY, .scale_x = 1, .scale_y = 1,
            .alpha = 1, .red = 1, .green = 1, .blue = 1,
            .rotation = originalCard ? 0 : (float)fmod(time * 0.35, 6.283185307179586),
            .u0 = 0, .u1 = 1, .v0 = 0, .v1 = 1}};
    const uint8_t clear[] = {10,15,26,255};
    if (dc_vk_sprite_render(_renderer, &draw, 1, clear, NULL, 0) != DC_OK) {
        NSString *message = [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
        [self destroyRenderer];
        return message;
    }
    ++_presentedFrames;
    return nil;
}
- (void)requestDrawAtX:(float)x y:(float)y time:(double)time
            completion:(void (^)(NSString *, NSString *, BOOL))completion {
    if (!self.window) { completion(@"Vulkan sprite view is not attached to a window", self.deviceName, self.startupCardLoaded); return; }
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGSize drawableSize = layer.drawableSize;
    uint32_t width = (uint32_t)drawableSize.width, height = (uint32_t)drawableSize.height;
    NSString *directory = [self.startupDataDirectory copy] ?: @"";
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            NSString *error = [self drawAtX:x y:y time:time layer:layer width:width height:height dataDirectory:directory];
            NSString *device = self->_deviceName ?: @"";
            BOOL startup = self->_startupTexture != 0;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error, device, startup); });
        }
    });
}
@end
