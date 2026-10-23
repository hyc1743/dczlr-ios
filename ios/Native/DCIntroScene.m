#import "DCIntroScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include "dc_script.h"
#include "dc_save.h"
#include "dc_text.h"
#include <CoreFoundation/CFStringEncodingExt.h>
#include <math.h>
#include <string.h>

static const dc_intro_descriptor dcIntroChapters[DC_INTRO_CHAPTERS]={
    {0,2},{1,31},{2,9},{-1,-1},{15,2},{-1,-1},{3,38},{-1,-1},
    {4,31},{5,5},{-1,-1},{16,2},{-1,-1},{6,42},{-1,-1},{7,43},
    {8,4},{-1,-1},{9,4},{-1,-1},{10,51},{-1,-1},{11,74},{13,4},{-1,-1},{12,13}
};
static NSString *dcIntroDecode(const void *bytes,size_t length) {
    NSStringEncoding encoding=CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseSimplif);
    return [[NSString alloc] initWithBytes:bytes length:length encoding:encoding];
}
static CGFloat dcIntroWidthScale(NSString *label,UIFont *font,size_t byteCount) {
    CGFloat width=[label sizeWithAttributes:@{NSFontAttributeName:font}].width;
    /* D3DXCreateFontA requests integer height/2 width, so one DBCS byte-pair
     * occupies twice that width, including two ordinary ASCII characters. */
    return width>0 ? ((29/2)*byteCount)/width : 1;
}
static void dcIntroDraw(CGContextRef context,NSString *label,CGPoint point,NSDictionary *attributes,CGFloat horizontalScale) {
    CGContextSaveGState(context);CGContextTranslateCTM(context,point.x,point.y);
    CGContextScaleCTM(context,horizontalScale,1);
    [label drawAtPoint:CGPointZero withAttributes:attributes];CGContextRestoreGState(context);
}

@implementation DCIntroScene {
    NSString *_directory;
    NSData *_script,*_bodyBytes;
    NSMutableData *_gameState,*_textPixels;
    DCArchive *_images,*_scripts;
    DCDecodedImage *_background;
    NSString *_speaker;
    dc_script_decoded _decoded;
    dc_vk_sprite *_renderer;
    uintptr_t _backgroundTexture,_textTexture;
    dc_text_state _text;
    dc_text_plan _textPlan;
    dc_intro_state _flow;
    uint32_t _lastTick,_pendingChapter;
    uint8_t _finishFlags[3];
    size_t _cursor;
    BOOL _touching,_completed,_dirty,_tickInitialized,_textStarted,_initialUpdateSkipped,_hasTextPlan;
    AVAudioPlayer *_music,*_sound,*_voice;
    BOOL _pausedMusic,_pausedVoice;
    BOOL _musicAdvanced,_voiceAdvanced,_soundAdvanced;
    BOOL _captureEnabled,_capturedFirstRecord;
}
- (uint32_t)frame { return _text.frame<0 ? 0 : (uint32_t)_text.frame; }
- (uint32_t)chapter { return _flow.chapter; }
- (NSString *)presentationState {
    return _hasTextPlan && _textTexture ? [NSString stringWithFormat:@"%u:%u:%u",_flow.chapter,self.frame,_text.fade_index] : @"";
}
- (BOOL)completed { return _completed; }
- (BOOL)audioAdvanced {
    if(_music.isPlaying && _music.currentTime>.02)_musicAdvanced=YES;
    if(_voice.isPlaying && _voice.currentTime>.02)_voiceAdvanced=YES;
    if(_sound.isPlaying && _sound.currentTime>.02)_soundAdvanced=YES;
    return _musicAdvanced && _voiceAdvanced && _soundAdvanced;
}
- (instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];
    _captureEnabled=[NSProcessInfo.processInfo.environment[@"PORTLAB_CAPTURE_STARTUP"] isEqualToString:@"1"];
    _gameState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
    if(dc_game_state_init(_gameState.mutableBytes,_gameState.length)!=DC_OK) {
        if(error)*error=@"New-game numeric state initialization failed";return nil;
    }
    NSError *reason=nil;
    _scripts=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_16.pp"]] error:&reason];
    _images=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if(!_scripts || !_images) {if(error)*error=reason.localizedDescription;return nil;}
    _flow=(dc_intro_state){.waiting=1};
    NSString *failure=[self loadChapter:0];
    if(failure) {if(error)*error=failure;return nil;}
    return self;
}
- (NSString *)loadChapter:(uint32_t)chapter {
    if(chapter>=DC_INTRO_CHAPTERS || dcIntroChapters[chapter].script<0)return @"Chapter is not a numbered intro script";
    NSString *name=[NSString stringWithFormat:@"%02d.txt",dcIntroChapters[chapter].script];
    NSData *script=nil;NSError *reason=nil;
    for(uint32_t i=0;i<_scripts.entryCount;++i) {
        if([[_scripts asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame) {
            script=[_scripts readEntryAtIndex:i limit:DC_SCRIPT_BYTE_LIMIT error:&reason];break;
        }
    }
    if(!script)return reason.localizedDescription ?: @"Numbered intro script is unavailable";
    _script=script;_cursor=0;
    _text=(dc_text_state){.columns=30,.max_lines=3,.visible_lines=1,.current_line=-1,
        .wait_state=-1,.wait_glyph=-1,.frame=-1,.last_frame=dcIntroChapters[chapter].last_frame,
        .wait_line=255,.active=1,.x=135,.y=652,.font_size=29,.scale=1,.rgb=0xffffff};
    _textStarted=NO;_hasTextPlan=NO;
    return [self loadRecord];
}
- (AVAudioPlayer *)playerForName:(const uint8_t *)name archive:(NSString *)archiveName loop:(BOOL)loop error:(NSString **)error {
    NSString *nameString=[[NSString alloc] initWithUTF8String:(const char *)name];
    if(!nameString || [nameString rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location!=NSNotFound) {
        if(error)*error=@"Intro audio identifier is unsupported";return nil;
    }
    NSString *file=[nameString stringByAppendingString:@".wav"];
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:archiveName]] error:&reason];
    if(!archive) {if(error)*error=reason.localizedDescription;return nil;}
    NSData *data=nil;
    for(uint32_t i=0;i<archive.entryCount;++i) {
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:file]==NSOrderedSame) {
            data=[archive readEntryAtIndex:i limit:32*1024*1024 error:&reason];break;
        }
    }
    if(!data) {if(error)*error=reason.localizedDescription ?: @"Intro audio resource is unavailable";return nil;}
    AVAudioPlayer *player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
    if(!player || ![player prepareToPlay]) {if(error)*error=reason.localizedDescription ?: @"Intro audio decoder failed";return nil;}
    player.numberOfLoops=loop ? -1 : 0;
    return player;
}
- (NSString *)loadRecord {
    dc_script_control controls[2]={{{'#','C',0},2},{{'#','P',0},5}};
    dc_script_decoded next;
    uint32_t frame=self.frame;
    dc_status status=dc_script_decode(_script.bytes,_script.length,_cursor,frame,controls,2,&next);
    if(status!=DC_OK)return [NSString stringWithFormat:@"Intro record %u rejected: %d",frame,status];
    const uint8_t *source=_script.bytes;
    NSString *speaker=dcIntroDecode(source+next.record.speaker.offset,next.record.speaker.length);
    NSString *body=dcIntroDecode(source+next.record.body.offset,next.record.body.length);
    if(!speaker || !body)return @"Intro text encoding is unsupported";
    if(next.message[0])return @"This intro record needs a pending message adapter";
    AVAudioPlayer *music=nil,*sound=nil,*voice=nil;NSString *audioError=nil;
    BOOL musicOff=!strcmp((const char *)next.music,"BGMOFF");
    if(next.music[0] && !musicOff) {
        music=[self playerForName:next.music archive:@"RPP_01.pp" loop:YES error:&audioError];
        if(!music)return audioError;
    }
    if(next.sound[0]) {
        sound=[self playerForName:next.sound archive:@"RPP_14.pp" loop:NO error:&audioError];
        if(!sound)return audioError;
    }
    if(next.controls[1][0]) {
        voice=[self playerForName:next.controls[1] archive:@"RPP_00.pp" loop:NO error:&audioError];
        if(!voice)return audioError;
    }
    if(next.background[0]) {
        NSString *name=[NSString stringWithFormat:@"%s.ema",(const char *)next.background];
        DCDecodedImage *image=nil;NSError *reason=nil;
        for(uint32_t i=0;i<_images.entryCount;++i) {
            if([[_images asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame) {
                image=[_images decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];break;
            }
        }
        if(!image)return reason.localizedDescription ?: @"Intro background resource is unavailable";
        if(_backgroundTexture)dc_vk_sprite_remove_texture(_renderer,_backgroundTexture);
        _backgroundTexture=0;_background=image;
    }
    if(next.music[0]) {[_music stop];_music=music;if(_music && ![_music play])return @"Intro music did not start";}
    if(sound) {[_sound stop];_sound=sound;if(![_sound play])return @"Intro sound did not start";}
    if(voice) {[_voice stop];_voice=voice;if(![_voice play])return @"Intro voice did not start";}
    _decoded=next;_cursor=next.record.next_offset;_speaker=speaker;
    _bodyBytes=[_script subdataWithRange:NSMakeRange(next.record.body.offset,next.record.body.length)];
    if(_bodyBytes.length>=DC_TEXT_BYTE_LIMIT || _bodyBytes.length<2)return @"Intro text exceeds the native controller profile";
    _text.body_bytes=(uint32_t)_bodyBytes.length;_text.visible_lines=1;_hasTextPlan=NO;_dirty=YES;
    return nil;
}
- (void)detachRenderer {
    if(_renderer) {
        if(_backgroundTexture)dc_vk_sprite_remove_texture(_renderer,_backgroundTexture);
        if(_textTexture)dc_vk_sprite_remove_texture(_renderer,_textTexture);
    }
    _renderer=NULL;_backgroundTexture=_textTexture=0;_dirty=YES;_tickInitialized=NO;
}
- (void)pause {
    _pausedMusic=_music.isPlaying;_pausedVoice=_voice.isPlaying;
    [_music pause];[_voice pause];[_sound stop];_touching=NO;_tickInitialized=NO;
}
- (void)dealloc { [self detachRenderer];[_music stop];[_sound stop];[_voice stop]; }
- (NSString *)uploadText {
    /* Numeric layout/fade comes from the original-verified normal controller.
     * Apple rasterizes CP936 cells; original Windows font pixels are unproven. */
    _textPixels=[NSMutableData dataWithLength:1024*768*4];
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(_textPixels.mutableBytes,1024,768,8,1024*4,color,
        kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(color);
    if(!context)return @"Intro text surface allocation failed";
    CGContextTranslateCTM(context,0,768);CGContextScaleCTM(context,1,-1);
    UIGraphicsPushContext(context);
    UIFont *font=[UIFont monospacedSystemFontOfSize:29 weight:UIFontWeightHeavy];
    const int shadowX[4]={-1,1,-1,1},shadowY[4]={-1,1,1,-1};
    NSDictionary *speakerBlack=@{NSFontAttributeName:font,NSForegroundColorAttributeName:UIColor.blackColor};
    NSDictionary *speakerWhite=@{NSFontAttributeName:font,NSForegroundColorAttributeName:UIColor.whiteColor};
    CGFloat speakerScale=dcIntroWidthScale(_speaker,font,_decoded.record.speaker.length);
    for(unsigned j=0;j<4;++j)dcIntroDraw(context,_speaker,CGPointMake(58+shadowX[j],652+shadowY[j]),speakerBlack,speakerScale);
    dcIntroDraw(context,_speaker,CGPointMake(58,652),speakerWhite,speakerScale);
    for(uint32_t i=0;i<_textPlan.count;++i) {
        const dc_text_glyph *glyph=&_textPlan.glyphs[i];
        size_t length=glyph->bytes[0] ? (glyph->bytes[1] ? 2 : 1) : 0;
        uint32_t alpha=glyph->color>>24;
        if(!length || !alpha)continue;
        NSString *label=dcIntroDecode(glyph->bytes,length);
        if(!label) {UIGraphicsPopContext();CGContextRelease(context);return @"Intro cell encoding is unsupported";}
        UIColor *color=[UIColor colorWithRed:((glyph->color>>16)&255)/255.0 green:((glyph->color>>8)&255)/255.0
            blue:(glyph->color&255)/255.0 alpha:alpha/255.0];
        NSDictionary *black=@{NSFontAttributeName:font,NSForegroundColorAttributeName:[UIColor colorWithWhite:0 alpha:alpha/255.0]};
        NSDictionary *foreground=@{NSFontAttributeName:font,NSForegroundColorAttributeName:color};
        size_t visibleBytes=0;
        for(size_t j=0;j<length;++j)visibleBytes+=glyph->bytes[j]!='\r' && glyph->bytes[j]!='\n';
        CGFloat horizontalScale=dcIntroWidthScale(label,font,visibleBytes);
        for(unsigned j=0;j<4;++j)dcIntroDraw(context,label,CGPointMake(glyph->x+shadowX[j],glyph->y+shadowY[j]),black,horizontalScale);
        dcIntroDraw(context,label,CGPointMake(glyph->x,glyph->y),foreground,horizontalScale);
    }
    UIGraphicsPopContext();CGContextRelease(context);
    /* Renderer expects straight alpha. */
    uint8_t *pixels=_textPixels.mutableBytes;
    for(size_t i=0;i<_textPixels.length;i+=4) {
        uint32_t alpha=pixels[i+3];
        if(alpha && alpha!=255)for(unsigned c=0;c<3;++c)pixels[i+c]=(uint8_t)MIN(255,(pixels[i+c]*255u+alpha/2)/alpha);
    }
    uintptr_t texture=0;
    dc_status status=dc_vk_sprite_upload(_renderer,1024,768,_textPixels.bytes,_textPixels.length,&texture);
    if(status!=DC_OK)return @"Intro text texture upload failed";
    if(_textTexture)dc_vk_sprite_remove_texture(_renderer,_textTexture);
    _textTexture=texture;_dirty=NO;return nil;
}
- (NSString *)applyFlow:(const dc_intro_plan *)plan transition:(DCStartupScene *)transition tick:(uint32_t)tick {
    for(uint32_t i=0;i<plan->count;++i) {
        dc_intro_command command=plan->commands[i];
        switch(command.kind) {
        case DC_INTRO_RESET_TEXT:
            if(_textTexture)dc_vk_sprite_remove_texture(_renderer,_textTexture);
            _textTexture=0;_textPixels=nil;_bodyBytes=nil;_hasTextPlan=NO;_text.active=0;break;
        case DC_INTRO_TRANSITION:
            if([transition requestTransition:command.value tick:tick]!=DC_OK)return @"Intro chapter transition request failed";
            break;
        case DC_INTRO_LOAD_SCRIPT: {
            NSString *failure=[self loadChapter:command.value];if(failure)return failure;break;
        }
        case DC_INTRO_CLEANUP: [_music stop];[_voice stop];[_sound stop];break;
        case DC_INTRO_ENTER_CHAPTER:
            _pendingChapter=command.value;_completed=YES;
            return [NSString stringWithFormat:@"Gameplay chapter %u callback is not implemented",command.value];
        case DC_INTRO_UNLOCK_PROGRESS: {
            uint8_t *bytes=_gameState.mutableBytes;bytes[0x23]=bytes[0x21bb]=bytes[0x4353]=1;break;
        }
        case DC_INTRO_CLEAR_FINISH: memset(_finishFlags,0,sizeof(_finishFlags));break;
        case DC_INTRO_STOP_AUDIO:
            if(command.value==2)[_music stop];else if(command.value==0)[_voice stop];else [_sound stop];break;
        case DC_INTRO_QUIT: return @"Game session ended";
        default: return @"Intro auxiliary destination is not implemented";
        }
    }
    _flow=plan->next;return nil;
}
- (NSString *)drawWithRenderer:(dc_vk_sprite *)renderer transition:(DCStartupScene *)transition
        tick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height {
    if(_renderer!=renderer) { [self detachRenderer];_renderer=renderer; }
    if(_completed)return [NSString stringWithFormat:@"Gameplay chapter %u callback is not implemented",_pendingChapter];
    if(_pausedMusic) {if(![_music play])return @"Intro music resume failed";_pausedMusic=NO;}
    if(_pausedVoice) {if(![_voice play])return @"Intro voice resume failed";_pausedVoice=NO;}
    uint32_t ready=0,delta=_tickInitialized ? tick-_lastTick : 0;
    if([transition queryTransitionReady:&ready]!=DC_OK)return @"Intro transition query failed";
    dc_intro_plan flowPlan;
    if(dc_intro_transition(&_flow,dcIntroChapters,DC_INTRO_CHAPTERS,ready,&flowPlan)!=DC_OK)return @"Intro transition planning failed";
    NSString *flowError=[self applyFlow:&flowPlan transition:transition tick:tick];if(flowError)return flowError;
    if(_text.active && _initialUpdateSkipped) {
        if(!_textStarted || (!_flow.waiting && !touching && _touching)) {
            dc_text_advance_plan advance;
            if(dc_text_advance(&_text,0,&advance)!=DC_OK)return @"Intro text advance failed";
            _text=advance.next;_textStarted=YES;
            if(advance.load_record) {NSString *failure=[self loadRecord];if(failure)return failure;}
        }
        if(_text.active) {
            dc_text_plan plan;
            if(dc_text_build_plan(&_text,_bodyBytes.bytes,_bodyBytes.length,(int32_t)delta,tick,0,&plan)!=DC_OK)return @"Intro text layout/fade failed";
            if(!_hasTextPlan || plan.count!=_textPlan.count || memcmp(plan.glyphs,_textPlan.glyphs,plan.count*sizeof(dc_text_glyph)))_dirty=YES;
            _textPlan=plan;_text=plan.next;_hasTextPlan=YES;
        }
    }
    _initialUpdateSkipped=YES;
    if(!_text.active && !_flow.waiting) {
        if(dc_intro_finish(&_flow,dcIntroChapters,DC_INTRO_CHAPTERS,&flowPlan)!=DC_OK)return @"Intro chapter completion planning failed";
        flowError=[self applyFlow:&flowPlan transition:transition tick:tick];if(flowError)return flowError;
    }
    _touching=touching;
    if(_background && !_backgroundTexture && dc_vk_sprite_upload(_renderer,_background.width,_background.height,
        _background.rgba.bytes,_background.rgba.length,&_backgroundTexture)!=DC_OK)return @"Intro background upload failed";
    if(_hasTextPlan && _dirty) {NSString *failure=[self uploadText];if(failure)return failure;}
    float scale=fminf((float)width/1024,(float)height/768);
    dc_sprite_pose pose={.width=1024*scale,.height=768*scale,.x=(width-1024*scale)*.5f,.y=(height-768*scale)*.5f,
        .z=.5f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
    dc_vk_sprite_item items[2]={0};size_t count=0;
    if(_backgroundTexture)items[count++]=(dc_vk_sprite_item){.pose=pose,.texture=_backgroundTexture,.blend_mode=3};
    if(_textTexture)items[count++]=(dc_vk_sprite_item){.pose=pose,.texture=_textTexture,.blend_mode=3};
    BOOL capture=_captureEnabled && !_capturedFirstRecord && _flow.chapter==0 && self.frame==0 &&
        _hasTextPlan && _text.fade_index>_text.body_bytes/2 && ready;
    NSMutableData *readback=capture ? [NSMutableData dataWithLength:(size_t)width*height*4] : nil;
    NSString *failure=[transition drawSprites:items count:count tick:tick width:width height:height readback:readback];
    if(!failure && capture) {
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)readback);
        CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrderDefault|kCGImageAlphaPremultipliedLast,
            provider,NULL,false,kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);CGColorSpaceRelease(color);
        if(!image)return @"Intro capture image failed";
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *url=[documents URLByAppendingPathComponent:@"intro-first-record.png"];
        CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        if(!destination) {CGImageRelease(image);return @"Intro capture destination failed";}
        CGImageDestinationAddImage(destination,image,NULL);BOOL saved=CGImageDestinationFinalize(destination);
        CFRelease(destination);CGImageRelease(image);
        if(!saved)return @"Intro capture write failed";
        _capturedFirstRecord=YES;
    }
    if(!failure) {_tickInitialized=YES;_lastTick=tick;}
    return failure;
}
@end
