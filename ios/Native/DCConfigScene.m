#import "DCConfigScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <string.h>

typedef struct config_sprite { const char *name; float w,h,x,y,ox,oy; } config_sprite;
/* Original VA00671c98, stride0x54. These are logical sizes, independent
 * of patched bitmap payload dimensions. */
static const config_sprite configSprites[11]={
    {"k_defo.ema",64,64,0,0,.1f,.1f},
    {"config_base.ema",1024,768,0,0,0,0},
    {"config_default.ema",128,32,872,656,0,0},
    {"hanyo_gameend.ema",56,56,48,704,0,0},
    {"hanyo_title.ema",56,56,128,704,0,0},
    {"hanyo_back.ema",56,56,936,704,0,0},
    {"hanyo_SaveLoad.ema",56,56,328,704,0,0},
    {"config_map.ema",56,48,752,320,0,0},
    {"config_botan.ema",96,40,288,464,0,0},
    {"config_slider.ema",24,24,246,100,.5f,.5f},
    {"config_sample.ema",48,48,928,448,0,0}
};
static BOOL configHit(float x,float y,float rx,float ry,float w,float h) {
    return x>=rx&&x<=rx+w&&y>=ry&&y<=ry+h;
}

@implementation DCConfigScene {
    dc_vk_sprite *_renderer;
    dc_config _config;
    uintptr_t _textures[11];
    DCStartupScene *_transition;
    NSString *_directory,*_captureName;
    AVAudioPlayer *_music,*_voice,*_select,*_toggle;
    BOOL _entered,_ready,_persist;
    uint32_t _pendingAction,_action,_changes;
    int32_t _drag,_hover;
    NSDictionary *_lastRenderCapture;
}
- (NSData *)configuration {return [NSData dataWithBytes:&_config length:sizeof(_config)];}
- (uint32_t)action {return _action;}
- (BOOL)persistOnDeparture {return _persist;}
- (NSDictionary *)lastRenderCapture {return _lastRenderCapture;}
- (NSString *)presentationContext {
    return [NSString stringWithFormat:@"system=configuration ready=%d drag=%d changes=%u pending=%u action=%u",_ready,_drag,_changes,_pendingAction,_action];
}
- (void)requestRenderCapture:(NSString *)name {_captureName=[name copy];}
- (AVAudioPlayer *)audio:(NSString *)name archive:(NSString *)file error:(NSString **)error {
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:file]] error:&reason];
    if(!archive){if(error)*error=reason.localizedDescription;return nil;}
    for(uint32_t i=0;i<archive.entryCount;++i)if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame){
        NSData *data=[archive readEntryAtIndex:i limit:32*1024*1024 error:&reason];
        AVAudioPlayer *player=data?[[AVAudioPlayer alloc] initWithData:data error:&reason]:nil;
        if(!player||![player prepareToPlay]){if(error)*error=reason.localizedDescription?:@"Configuration audio preparation failed";return nil;}
        return player;
    }
    if(error)*error=[NSString stringWithFormat:@"Missing original configuration audio %@",name];return nil;
}
- (void)updateVolumes {
    float voice,bgm,se;
    dc_config_slider_value(&_config,0,&voice);dc_config_slider_value(&_config,1,&bgm);dc_config_slider_value(&_config,2,&se);
    /* DirectSound attenuation is in hundredths of a decibel. */
    _voice.volume=powf(10,voice/2000);_music.volume=powf(10,bgm/2000);
    _select.volume=_toggle.volume=powf(10,se/2000);
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
        configuration:(NSData *)configuration transition:(DCStartupScene *)transition error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];_renderer=renderer;_transition=transition;_drag=_hover=-1;
    if(dc_config_decode(configuration.bytes,configuration.length,&_config)!=DC_OK){if(error)*error=@"Original configuration state rejected";return nil;}
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if(!archive){if(error)*error=reason.localizedDescription;return nil;}
    for(unsigned target=0;target<11;++target){
        NSString *name=[NSString stringWithUTF8String:configSprites[target].name];BOOL found=NO;
        for(uint32_t i=0;i<archive.entryCount;++i)if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame){
            DCDecodedImage *image=[archive decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];
            if(!image||dc_vk_sprite_upload(renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&_textures[target])!=DC_OK){
                if(error)*error=reason.localizedDescription?:@"Configuration bitmap upload failed";return nil;
            }
            found=YES;break;
        }
        if(!found){if(error)*error=[NSString stringWithFormat:@"Missing original configuration bitmap %@",name];return nil;}
    }
    _voice=[self audio:@"sample_v.wav" archive:@"RPP_00.pp" error:error];
    _music=[self audio:@"bgm005.wav" archive:@"RPP_01.pp" error:error];
    _select=[self audio:@"se100.wav" archive:@"RPP_14.pp" error:error];
    _toggle=[self audio:@"se101.wav" archive:@"RPP_14.pp" error:error];
    if(!_voice||!_music||!_select||!_toggle)return nil;
    _music.numberOfLoops=-1;[self updateVolumes];[_music play];return self;
}
- (void)detachRenderer {
    if(_renderer)for(unsigned i=0;i<11;++i)if(_textures[i])dc_vk_sprite_remove_texture(_renderer,_textures[i]);
    memset(_textures,0,sizeof(_textures));_renderer=NULL;
}
- (void)pause {[_music pause];[_voice pause];[_select pause];[_toggle pause];}
- (void)resumeFromTemporaryScreen {_pendingAction=_action=0;_entered=_ready=_persist=NO;[_music play];}
- (void)dealloc {[self detachRenderer];[_music stop];[_voice stop];[_select stop];[_toggle stop];}
- (NSString *)depart:(uint32_t)action tick:(uint32_t)tick {
    _pendingAction=action;_persist=action!=5;_drag=-1;
    if(action!=5){_select.currentTime=0;[_select play];}
    else [self pause];
    return [_transition requestTransition:action==5?3:2 tick:tick]==DC_OK?nil:@"Configuration departure transition failed";
}
- (void)append:(unsigned)index x:(float)x y:(float)y scale:(float)scale
        offsetX:(float)ox offsetY:(float)oy items:(dc_vk_sprite_item *)items count:(size_t *)count {
    config_sprite sprite=configSprites[index];
    dc_sprite_pose pose={.width=sprite.w*scale,.height=sprite.h*scale,.x=ox+x*scale,.y=oy+y*scale,.z=.5f,
        .origin_x=sprite.ox,.origin_y=sprite.oy,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
    items[(*count)++]=(dc_vk_sprite_item){.pose=pose,.texture=_textures[index],.blend_mode=3};
}
- (NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input width:(uint32_t)width height:(uint32_t)height {
    if(!_renderer)return @"Configuration renderer detached";
    if(!_entered){
        if([_transition requestTransition:4 tick:tick]!=DC_OK)return @"Configuration entry transition failed";
        _entered=YES;
    }
    uint32_t ready=0;if([_transition queryTransitionReady:&ready]!=DC_OK)return @"Configuration transition query failed";
    if(ready){if(_pendingAction&&!_select.isPlaying)_action=_pendingAction;else if(!_pendingAction)_ready=YES;}
    float x=input.x*1024,y=input.y*768;_hover=-1;
    if(_ready&&!_pendingAction){
        if(input.keys[1]==3){NSString *failure=[self depart:5 tick:tick];if(failure)return failure;}
        else if(input.mouse[1]==2||input.keys[0x3b]==3){NSString *failure=[self depart:1 tick:tick];if(failure)return failure;}
        else {
            if(_drag>=0){
                if(input.mouse[0]&1){
                    if(dc_config_slider_apply(&_config,(uint32_t)_drag,x)!=DC_OK)return @"Configuration slider update failed";
                    ++_changes;[self updateVolumes];
                }else {
                    AVAudioPlayer *preview=_drag==0?_voice:_drag==2?_select:nil;
                    if(preview){preview.currentTime=0;[preview play];}_drag=-1;
                }
            }else {
                for(uint32_t slider=0;slider<DC_CONFIG_SLIDERS;++slider){
                    dc_config_track track;float center;
                    dc_config_slider_track(slider,&track);dc_config_slider_center(&_config,slider,&center);
                    if(configHit(x,y,center-12,track.y,24,24)||configHit(x,y,track.x,track.y,track.width,track.height)){
                        if(input.mouse[0]==3){_drag=(int32_t)slider;dc_config_slider_apply(&_config,slider,x);++_changes;[self updateVolumes];}
                        break;
                    }
                }
                static const float switchX[6]={752,832,912,288,288,800},switchY[6]={320,320,320,464,624,568};
                if(_drag<0)for(unsigned i=0;i<6;++i){
                    if(configHit(x,y,switchX[i],switchY[i],i<3?56:96,i<3?48:40)&&input.mouse[0]==3){
                        dc_config_switch_toggle(&_config,i);++_changes;_toggle.currentTime=0;[_toggle play];break;
                    }
                }
                if(_drag<0)for(unsigned i=0;i<5;++i){
                    config_sprite sprite=configSprites[i+2];
                    if(!configHit(x,y,sprite.x,sprite.y,sprite.w,sprite.h))continue;
                    _hover=(int32_t)i;
                    if(input.mouse[0]==3){
                        if(i==0){dc_config_reset(&_config);++_changes;[self updateVolumes];_toggle.currentTime=0;[_toggle play];}
                        else {static const uint32_t actions[5]={0,4,2,1,3};NSString *failure=[self depart:actions[i] tick:tick];if(failure)return failure;}
                    }
                    break;
                }
            }
        }
    }
    dc_vk_sprite_item items[24]={0};size_t count=0;
    float scale=fminf(width/1024.f,height/768.f),ox=(width-1024*scale)*.5f,oy=(height-768*scale)*.5f;
    [self append:1 x:0 y:0 scale:scale offsetX:ox offsetY:oy items:items count:&count];
    if(_hover>=0){config_sprite sprite=configSprites[_hover+2];[self append:(unsigned)_hover+2 x:sprite.x y:sprite.y scale:scale offsetX:ox offsetY:oy items:items count:&count];}
    for(unsigned slider=0;slider<DC_CONFIG_SLIDERS;++slider){
        dc_config_track track;float center;
        dc_config_slider_track(slider,&track);dc_config_slider_center(&_config,slider,&center);
        [self append:9 x:center y:track.y+12-(slider<3?3:0) scale:scale offsetX:ox offsetY:oy items:items count:&count];
    }
    static const float switchX[6]={752,832,912,288,288,800},switchY[6]={320,320,320,464,624,568};
    for(unsigned i=0;i<6;++i){uint32_t value=0;dc_config_switch_value(&_config,i,&value);
        if(value)[self append:i<3?7:8 x:switchX[i] y:switchY[i] scale:scale offsetX:ox offsetY:oy items:items count:&count];
    }
    [self append:10 x:928 y:448 scale:scale offsetX:ox offsetY:oy items:items count:&count];
    float rgb[3];for(unsigned i=0;i<3;++i)dc_config_slider_value(&_config,7+i,&rgb[i]);
    items[count-1].pose.red=rgb[0]/255;items[count-1].pose.green=rgb[1]/255;items[count-1].pose.blue=rgb[2]/255;
    [self append:0 x:x y:y scale:scale offsetX:ox offsetY:oy items:items count:&count];
    if(input.keys[0x2e]==3)_captureName=@"system-config-native.png";
    NSMutableData *pixels=_captureName?[NSMutableData dataWithLength:(size_t)width*height*4]:nil;
    NSString *failure=[_transition drawSprites:items count:count tick:tick width:width height:height readback:pixels];
    if(failure)return failure;
    if(pixels){
        NSString *name=_captureName.lastPathComponent;_captureName=nil;
        NSString *directory=[_directory stringByDeletingLastPathComponent];
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Big|kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
        NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
        CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        if(!image||!destination){if(destination)CFRelease(destination);if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(color);return @"Configuration capture allocation failed";}
        CGImageDestinationAddImage(destination,image,NULL);BOOL written=CGImageDestinationFinalize(destination);
        CFRelease(destination);CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(color);
        if(!written)return @"Configuration capture write failed";
        NSMutableArray *values=[NSMutableArray array];for(unsigned i=0;i<10;++i){float value;dc_config_slider_value(&_config,i,&value);[values addObject:@(value)];}
        _lastRenderCapture=@{@"file":name,@"width":@(width),@"height":@(height),@"draws":@(count),@"values":values,
            @"changes":@(_changes),@"drag":@(_drag),@"ready":@(_ready),@"pointer":@[@(x),@(y)],
            @"switches":@[@(_config.bytes[27]),@(_config.bytes[28]),@(_config.bytes[29]),@(_config.bytes[25]),@(_config.bytes[24]),@(_config.bytes[26])]};
        NSData *json=[NSJSONSerialization dataWithJSONObject:_lastRenderCapture options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[[directory stringByAppendingPathComponent:name] stringByAppendingString:@".json"] atomically:YES];
    }
    return nil;
}
@end
