#import "DCVulkanSpriteView.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "dc_vk_sprite.h"
#include "dc_sprite_spv.h"
#include <math.h>

@implementation DCVulkanSpriteView {
    dc_vk_sprite *_renderer;
    uintptr_t _texture;
    uint32_t _width, _height;
    NSString *_deviceName;
    uint64_t _presentedFrames;
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
    }
    return self;
}
- (NSString *)deviceName { return _deviceName; }
- (uint64_t)presentedFrames { return _presentedFrames; }
- (void)releaseRenderer {
    dc_vk_sprite_destroy(_renderer);
    _renderer = NULL;
    _texture = 0;
    _width = _height = 0;
}
- (void)dealloc { [self releaseRenderer]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(ceil(self.bounds.size.width * scale), ceil(self.bounds.size.height * scale));
    if (_renderer && (_width != (uint32_t)layer.drawableSize.width || _height != (uint32_t)layer.drawableSize.height))
        [self releaseRenderer];
}
- (nullable NSString *)drawAtX:(float)x y:(float)y time:(double)time {
    if (!self.window) return @"Vulkan sprite view is not attached to a window";
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return @"Vulkan sprite view has empty bounds";
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    if (!_renderer) {
        uint32_t width = (uint32_t)layer.drawableSize.width, height = (uint32_t)layer.drawableSize.height;
        if (!width || !height) return @"CAMetalLayer has empty drawable size";
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
    float side = fminf(_width, _height) * 0.4f;
    dc_vk_sprite_item draw = {.texture = _texture, .blend_mode = 3, .point_filter = 1,
        .pose = {.width = side, .height = side, .x = _width * (0.5f + x * 0.3f), .y = _height * (0.5f - y * 0.3f),
            .z = 0.5f, .origin_x = 0.5f, .origin_y = 0.5f, .scale_x = 1, .scale_y = 1,
            .alpha = 1, .red = 1, .green = 1, .blue = 1, .rotation = (float)fmod(time * 0.35, 6.283185307179586),
            .u0 = 0, .u1 = 1, .v0 = 0, .v1 = 1}};
    const uint8_t clear[] = {10,15,26,255};
    if (dc_vk_sprite_render(_renderer, &draw, 1, clear, NULL, 0) != DC_OK) {
        NSString *message = [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
        [self releaseRenderer];
        return message;
    }
    ++_presentedFrames;
    return nil;
}
@end
