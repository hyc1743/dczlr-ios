#import "DCIntroScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include "dc_script.h"
#include "dc_save.h"
#include <math.h>
#include <string.h>

@implementation DCIntroScene {
    NSString *_directory;
    NSData *_script;
    NSMutableData *_gameState,*_textPixels;
    DCArchive *_images;
    DCDecodedImage *_background;
    NSString *_speaker,*_body;
    dc_script_decoded _decoded;
    dc_vk_sprite *_renderer;
    uintptr_t _backgroundTexture,_textTexture;
    uint32_t _frame;
    size_t _cursor;
    BOOL _touching,_waiting,_completed,_dirty;
    AVAudioPlayer *_music,*_sound,*_voice;
    BOOL _pausedMusic,_pausedVoice;
    BOOL _musicAdvanced,_voiceAdvanced,_soundAdvanced;
}
- (uint32_t)frame { return _frame; }
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
    _gameState=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
    if(dc_game_state_init(_gameState.mutableBytes,_gameState.length)!=DC_OK) {
        if(error)*error=@"New-game numeric state initialization failed";return nil;
    }
    NSError *reason=nil;
    DCArchive *scripts=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_16.pp"]] error:&reason];
    _images=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if(!scripts || !_images) {if(error)*error=reason.localizedDescription;return nil;}
    for(uint32_t i=0;i<scripts.entryCount;++i) {
        if([[scripts asciiNameAtIndex:i] caseInsensitiveCompare:@"00.txt"]==NSOrderedSame) {
            _script=[scripts readEntryAtIndex:i limit:DC_SCRIPT_BYTE_LIMIT error:&reason];break;
        }
    }
    if(!_script) {if(error)*error=reason.localizedDescription ?: @"First new-game script is unavailable";return nil;}
    NSString *failure=[self loadRecord];
    if(failure) {if(error)*error=failure;return nil;}
    _waiting=YES;
    return self;
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
    dc_status status=dc_script_decode(_script.bytes,_script.length,_cursor,_frame,controls,2,&next);
    if(status!=DC_OK)return [NSString stringWithFormat:@"Intro record %u rejected: %d",_frame,status];
    const uint8_t *source=_script.bytes;
    NSString *speaker=[[NSString alloc] initWithBytes:source+next.record.speaker.offset length:next.record.speaker.length encoding:NSShiftJISStringEncoding];
    NSString *body=[[NSString alloc] initWithBytes:source+next.record.body.offset length:next.record.body.length encoding:NSShiftJISStringEncoding];
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
        NSString *name=[NSString stringWithFormat:@"%s.ema",next.background];
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
    _decoded=next;_cursor=next.record.next_offset;_speaker=speaker;_body=body;_dirty=YES;
    return nil;
}
- (void)detachRenderer {
    if(_renderer) {
        if(_backgroundTexture)dc_vk_sprite_remove_texture(_renderer,_backgroundTexture);
        if(_textTexture)dc_vk_sprite_remove_texture(_renderer,_textTexture);
    }
    _renderer=NULL;_backgroundTexture=_textTexture=0;_dirty=YES;
}
- (void)pause {
    _pausedMusic=_music.isPlaying;_pausedVoice=_voice.isPlaying;
    [_music pause];[_voice pause];[_sound stop];_touching=NO;
}
- (void)dealloc { [self detachRenderer];[_music stop];[_sound stop];[_voice stop]; }
- (NSString *)uploadText {
    /* Temporary Apple text adapter: original layout bounds/font size, native
     * fallback font and complete record. Glyph fade/layout equivalence pending. */
    _textPixels=[NSMutableData dataWithLength:1024*768*4];
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(_textPixels.mutableBytes,1024,768,8,1024*4,color,
        kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(color);
    if(!context)return @"Intro text surface allocation failed";
    CGContextTranslateCTM(context,0,768);CGContextScaleCTM(context,1,-1);
    UIGraphicsPushContext(context);
    NSDictionary *attributes=@{NSFontAttributeName:[UIFont systemFontOfSize:29],
        NSForegroundColorAttributeName:UIColor.whiteColor,NSStrokeColorAttributeName:UIColor.blackColor,
        NSStrokeWidthAttributeName:@(-3)};
    [_speaker drawInRect:CGRectMake(58,652,77,116) withAttributes:attributes];
    [_body drawInRect:CGRectMake(135,652,889,116) withAttributes:attributes];
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
- (NSString *)drawWithRenderer:(dc_vk_sprite *)renderer transition:(DCStartupScene *)transition
        tick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height {
    if(_renderer!=renderer) { [self detachRenderer];_renderer=renderer; }
    if(_completed)return @"First intro chapter completed; next gameplay callback is not implemented";
    if(_pausedMusic) {if(![_music play])return @"Intro music resume failed";_pausedMusic=NO;}
    if(_pausedVoice) {if(![_voice play])return @"Intro voice resume failed";_pausedVoice=NO;}
    uint32_t ready=0;
    if([transition queryTransitionReady:&ready]!=DC_OK)return @"Intro transition query failed";
    BOOL wasWaiting=_waiting;
    if(_waiting && ready)_waiting=NO;
    if(!_waiting && !wasWaiting && !touching && _touching && !_completed) {
        if(_frame==2) {
            _completed=YES;
            return @"First intro chapter completed; next gameplay callback is not implemented";
        }
        ++_frame;NSString *failure=[self loadRecord];if(failure)return failure;
    }
    _touching=touching;
    if(_background && !_backgroundTexture && dc_vk_sprite_upload(_renderer,_background.width,_background.height,
        _background.rgba.bytes,_background.rgba.length,&_backgroundTexture)!=DC_OK)return @"Intro background upload failed";
    if(_dirty) {NSString *failure=[self uploadText];if(failure)return failure;}
    float scale=fminf((float)width/1024,(float)height/768);
    dc_sprite_pose pose={.width=1024*scale,.height=768*scale,.x=(width-1024*scale)*.5f,.y=(height-768*scale)*.5f,
        .z=.5f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
    dc_vk_sprite_item items[2]={0};size_t count=0;
    if(_backgroundTexture)items[count++]=(dc_vk_sprite_item){.pose=pose,.texture=_backgroundTexture,.blend_mode=3};
    items[count++]=(dc_vk_sprite_item){.pose=pose,.texture=_textTexture,.blend_mode=3};
    return [transition drawSprites:items count:count tick:tick width:width height:height];
}
@end
