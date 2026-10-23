#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdint.h>
#include <stdio.h>

int dc_vk_sprite_pixel_gate(void *metal_layer, uint32_t validation);

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,320,240)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        if (!layer.device) { fprintf(stderr, "No Metal device; surface execution unavailable\n"); return 1; }
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.opaque = YES;
        layer.frame = window.contentView.bounds;
        layer.drawableSize = CGSizeMake(320,240);
        window.contentView.wantsLayer = YES;
        window.contentView.layer = layer;
        [window orderFrontRegardless];
        [window display];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        int result = dc_vk_sprite_pixel_gate((__bridge void *)layer, 0);
        [window close];
        if (!result) puts("PASS: Vulkan Metal surface acquire/blit/present with pixel gate; physical display inspection unverified");
        return result;
    }
}
