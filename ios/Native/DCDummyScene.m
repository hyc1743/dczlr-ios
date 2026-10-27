#import "DCDummyScene.h"
#import "DCStartupScene.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <string.h>

@implementation DCDummyScene {
    NSString *_directory;
    DCStartupScene *_transition;
    dc_vk_sprite *_renderer;
    NSData *_rgba;
    uintptr_t _texture;
    uint32_t _imageWidth,_imageHeight;
    BOOL _entered,_returning;
    uint32_t _action;
}
- (uint32_t)action { return _action; }
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    transition:(DCStartupScene *)transition error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];_renderer=renderer;_transition=transition;
    NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"dummy.bmp"]];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
    if(source)CFRelease(source);
    if(!image){if(error)*error=@"Original dummy screen bitmap is unavailable";return nil;}
    _imageWidth=(uint32_t)CGImageGetWidth(image);_imageHeight=(uint32_t)CGImageGetHeight(image);
    if(!_imageWidth||!_imageHeight){CGImageRelease(image);if(error)*error=@"Original dummy screen bitmap has empty dimensions";return nil;}
    size_t bytes=(size_t)_imageWidth*_imageHeight*4;
    NSMutableData *rgba=[NSMutableData dataWithLength:bytes];
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(rgba.mutableBytes,_imageWidth,_imageHeight,8,
        (size_t)_imageWidth*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    if(!context){CGColorSpaceRelease(color);CGImageRelease(image);if(error)*error=@"Original dummy screen bitmap context failed";return nil;}
    CGContextDrawImage(context,CGRectMake(0,0,_imageWidth,_imageHeight),image);
    CGContextRelease(context);CGColorSpaceRelease(color);CGImageRelease(image);
    _rgba=[rgba copy];
    if([self attachRenderer:renderer]!=nil){if(error)*error=@"Original dummy screen texture upload failed";return nil;}
    return self;
}
- (NSString *)attachRenderer:(dc_vk_sprite *)renderer {
    if(_renderer==renderer&&_texture)return nil;
    [self detachRenderer];_renderer=renderer;
    return dc_vk_sprite_upload(_renderer,_imageWidth,_imageHeight,_rgba.bytes,_rgba.length,&_texture)==DC_OK?nil:@"Original dummy screen texture upload failed";
}
- (void)detachRenderer {
    if(_renderer&&_texture)dc_vk_sprite_remove_texture(_renderer,_texture);
    _texture=0;_renderer=NULL;
}
- (void)pause {}
- (NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input
    width:(uint32_t)width height:(uint32_t)height {
    if(!_renderer||!_transition||!_texture)return @"Dummy screen renderer is unavailable";
    uint32_t ready=0;
    if([_transition queryTransitionReady:&ready]!=DC_OK)return @"Dummy screen transition query failed";
    if(!_entered)_entered=YES;
    if(!_action&&!_returning&&(input.keys[1]==3||input.mouse[1]==2)){
        _returning=YES;
        if([_transition requestTransition:4 tick:tick]!=DC_OK)return @"Dummy screen return transition failed";
    }
    if(_returning&&ready)_action=1;
    float scale=fminf(width/1024.f,height/768.f);
    dc_vk_sprite_item item={0};
    item.texture=_texture;item.blend_mode=3;
    item.pose=(dc_sprite_pose){.width=1024*scale,.height=768*scale,
        .x=(width-1024*scale)*.5f,.y=(height-768*scale)*.5f,.z=.5f,
        .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
    return [_transition drawSprites:&item count:1 tick:tick width:width height:height];
}
- (void)dealloc {[self detachRenderer];}
@end
