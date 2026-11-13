#import "DCIntroScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include "dc_script.h"
#include "dc_save.h"
#include "dc_text.h"
#include "dc_config.h"
#include <CoreFoundation/CFStringEncodingExt.h>
#include <math.h>
#include <string.h>

static const dc_intro_descriptor dcIntroChapters[DC_INTRO_CHAPTERS]={
    {0,2},{1,31},{2,9},{-1,-1},{15,2},{-1,-1},{3,38},{-1,-1},
    {4,31},{5,5},{-1,-1},{16,2},{-1,-1},{6,42},{-1,-1},{7,43},
    {8,4},{-1,-1},{9,4},{-1,-1},{10,51},{-1,-1},{11,74},{13,4},{-1,-1},{12,13},{14,4},{17,1},{18,2}
};
static BOOL dcIntroLooksLikeShiftJIS(const uint8_t *bytes,size_t length) {
    size_t dbcsPairs=0,kanaPairs=0;
    for(size_t i=0;i<length;++i) {
        uint8_t c=bytes[i];
        if(c<0x80)continue;
        if(!((c>=0x81&&c<=0x9f)||(c>=0xe0&&c<=0xef)))return NO;
        if(i+1>=length)return NO;
        uint8_t t=bytes[++i];
        if(!((t>=0x40&&t<=0x7e)||(t>=0x80&&t<=0xfc)))return NO;
        ++dbcsPairs;
        if((c==0x82&&t>=0x9f&&t<=0xf1)||(c==0x83&&t>=0x40&&t<=0x96))++kanaPairs;
    }
    return dbcsPairs>0 && kanaPairs*5>=dbcsPairs;
}
static NSString *dcIntroDecodeWithFlag(const void *bytes,size_t length,BOOL preferShiftJIS) {
    NSStringEncoding primary=CFStringConvertEncodingToNSStringEncoding(
        preferShiftJIS ? kCFStringEncodingDOSJapanese : kCFStringEncodingDOSChineseSimplif);
    NSStringEncoding fallback=CFStringConvertEncodingToNSStringEncoding(
        preferShiftJIS ? kCFStringEncodingDOSChineseSimplif : kCFStringEncodingDOSJapanese);
    NSString *decoded=[[NSString alloc] initWithBytes:bytes length:length encoding:primary];
    if(decoded)return decoded;
    decoded=[[NSString alloc] initWithBytes:bytes length:length encoding:fallback];
    return decoded ?: [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
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
    DCDecodedImage *_background,*_windowFrame,*_nextPrompt;
    NSString *_speaker;
    dc_script_decoded _decoded;
    dc_vk_sprite *_renderer;
    uintptr_t _backgroundTexture,_textTexture,_windowFrameTexture,_nextPromptTexture;
    dc_text_state _text;
    dc_text_plan _textPlan;
    dc_intro_state _flow;
    uint32_t _lastTick,_pendingChapter;
    uint32_t _entryFrame,_targetEntryFrame,_auxiliaryDestination;
    uint32_t _fastForwardAccumMs;
    int32_t _liveFrame;
    uint8_t _finishFlags[3];
    size_t _cursor;
    BOOL _touching,_completed,_dirty,_tickInitialized,_needsResumeAtNextTick,_textStarted,_initialUpdateSkipped,_hasTextPlan;
    BOOL _windowHidden,_fastForward,_backlogMode,_backlogReplayedVoice,_voiceSkippedByFastForward,_scriptIsShiftJIS;
    AVAudioPlayer *_music,*_sound,*_voice,*_selection;
    float _musicVolume,_soundVolume,_voiceVolume;
    BOOL _pausedMusic,_pausedVoice,_pausedSound;
    BOOL _seeking;
    BOOL _musicAdvanced,_voiceAdvanced,_soundAdvanced;
    BOOL _captureEnabled,_capturedFirstRecord;
}
- (uint32_t)frame { return _text.frame<0 ? 0 : (uint32_t)_text.frame; }
- (uint32_t)chapter { return _flow.chapter; }
- (uint32_t)pendingChapter { return _pendingChapter; }
- (uint32_t)auxiliaryDestination {return _auxiliaryDestination;}
- (NSData *)numericState {return _gameState;}
- (BOOL)backlogMode {return _backlogMode;}
- (void)consumeAuxiliaryDestination {_auxiliaryDestination=0;}
- (void)resumeAtTick:(uint32_t)tick {
    _needsResumeAtNextTick=NO;
    if(_tickInitialized)_text.wait_stamp+=tick-_lastTick;
    _lastTick=tick;_tickInitialized=YES;_touching=NO;
}
- (void)resumeFromAuxiliaryAtTick:(uint32_t)tick {
    if(_flow.action==5 && _music) {
        _music.currentTime=0;
        _pausedMusic=YES;
    }
    _flow.action=0;_flow.waiting=0;
    _auxiliaryDestination=0;
    [self resumeAtTick:tick];
}
- (void)applyConfiguration:(NSData *)configuration {
    if(!configuration)return;
    dc_config state;
    if(dc_config_decode(configuration.bytes,configuration.length,&state)!=DC_OK)return;
    float voice=0,bgm=0,se=0;
    dc_config_slider_value(&state,0,&voice);
    dc_config_slider_value(&state,1,&bgm);
    dc_config_slider_value(&state,2,&se);
    _voiceVolume=powf(10.0f,voice/2000.0f);
    _musicVolume=powf(10.0f,bgm/2000.0f);
    _soundVolume=powf(10.0f,se/2000.0f);
    if(_music)_music.volume=_musicVolume;
    if(_sound)_sound.volume=_soundVolume;
    if(_voice)_voice.volume=_voiceVolume;
    if(_selection)_selection.volume=_soundVolume;
}
- (void)toggleWindowHidden { _windowHidden=!_windowHidden; }
- (void)setFastForward:(BOOL)fastForward {
    if(!fastForward)_fastForwardAccumMs=100;
    _fastForward=fastForward;
}
- (NSString *)replayCurrentVoice {
    if(!_decoded.controls[1][0])return nil;
    NSString *audioError=nil;
    AVAudioPlayer *voice=[self playerForName:_decoded.controls[1] archive:@"RPP_00.pp" loop:NO error:&audioError];
    if(!voice)return audioError;
    voice.volume=_voiceVolume;
    [_voice stop];_voice=voice;_pausedVoice=NO;_voiceSkippedByFastForward=NO;
    if(![_voice play]){[_voice prepareToPlay];if(![_voice play])_pausedVoice=YES;}
    return nil;
}
- (NSString *)handleSpaceOrMiddleClick {
    if(!_text.active||_flow.waiting)return nil;
    _windowHidden=NO;
    if(_decoded.controls[1][0]) {
        if(_backlogMode)_backlogReplayedVoice=YES;
        return [self replayCurrentVoice];
    }
    return nil;
}
- (NSString *)requestAuxiliary:(uint32_t)destination transition:(DCStartupScene *)transition tick:(uint32_t)tick {
    if(_flow.waiting||_auxiliaryDestination)return nil;
    if(destination!=2&&destination!=5&&destination!=7)return @"Unknown original script system destination";
    if([transition requestTransition:destination==5?3:2 tick:tick]!=DC_OK)return @"Script system transition failed";
    if(destination==2||destination==7) {
        [_sound stop];[_voice stop];_pausedVoice=NO;_pausedSound=NO;
        if(!_selection)_selection=[self playerForName:(const uint8_t *)"se100" archive:@"RPP_14.pp" loop:NO error:nil];
        if(_selection) {
            if(_selection.isPlaying)[_selection stop];
            _selection.volume=_soundVolume;_selection.currentTime=0;
            if(![_selection play]){[_selection prepareToPlay];[_selection play];}
        }
    }
    _flow.action=destination;_flow.waiting=1;return nil;
}
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
    return [self initWithDirectory:directory startChapter:0 error:error];
}
- (instancetype)initWithDirectory:(NSString *)directory startChapter:(uint32_t)startChapter error:(NSString **)error {
    NSMutableData *state=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
    if(dc_game_state_init(state.mutableBytes,state.length)!=DC_OK){if(error)*error=@"New-game numeric state initialization failed";return nil;}
    return [self initWithDirectory:directory startChapter:startChapter numericState:state savedFrame:0 error:error];
}
- (instancetype)initWithDirectory:(NSString *)directory startChapter:(uint32_t)startChapter
        numericState:(NSMutableData *)state savedFrame:(uint32_t)frame error:(NSString **)error {
    if(!(self=[super init]))return nil;
    if(startChapter>=DC_INTRO_CHAPTERS) { if(error)*error=@"Story chapter is outside the script table";return nil; }
    _directory=[directory copy];
    _musicVolume=_soundVolume=_voiceVolume=1.0f;
    NSString *docsRoot = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *docsCfg = docsRoot.length ? [[docsRoot stringByAppendingPathComponent:@"game/Data"] stringByAppendingPathComponent:@"gcd.cfg"] : @"";
    NSString *cfgPath = (docsCfg.length && [NSFileManager.defaultManager fileExistsAtPath:docsCfg]) ? docsCfg : [directory stringByAppendingPathComponent:@"gcd.cfg"];
    NSData *cfgData=[NSData dataWithContentsOfFile:cfgPath];
    if(cfgData)[self applyConfiguration:cfgData];
    _captureEnabled=[NSProcessInfo.processInfo.environment[@"PORTLAB_CAPTURE_STARTUP"] isEqualToString:@"1"];
    if(state.length!=DC_GAME_STATE_BYTES){if(error)*error=@"Original numeric state size rejected";return nil;}
    if(frame>(uint32_t)dcIntroChapters[startChapter].last_frame){if(error)*error=@"Saved script frame outside original descriptor";return nil;}
    _gameState=state;_entryFrame=frame;
    NSError *reason=nil;
    _scripts=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_16.pp"]] error:&reason];
    _images=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if(!_scripts || !_images) {if(error)*error=reason.localizedDescription;return nil;}
    if(!_captureEnabled) {
        for(uint32_t i=0;i<_images.entryCount;++i) {
            NSString *entryName=[_images asciiNameAtIndex:i];
            if([entryName caseInsensitiveCompare:@"bt_00.ema"]==NSOrderedSame)
                _windowFrame=[_images decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:16*1024*1024 error:nil];
            else if([entryName caseInsensitiveCompare:@"bt_01.ema"]==NSOrderedSame)
                _nextPrompt=[_images decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:16*1024*1024 error:nil];
        }
    }
    if(startChapter || frame) {
        /* Mid-story or saved-frame entry: the transition host is not needed;
         * the chapter script starts immediately and the chapter-end routing advances. */
        _flow=(dc_intro_state){.chapter=startChapter,.waiting=0};
    } else {
        _flow=(dc_intro_state){.waiting=1};
    }
    _flow.progress=((const uint8_t *)_gameState.bytes)[0x23];
    NSString *failure=[self loadChapter:startChapter];
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
    _script=script;_scriptIsShiftJIS=dcIntroLooksLikeShiftJIS(script.bytes,script.length);
    _cursor=0;_backlogMode=NO;_backlogReplayedVoice=NO;_liveFrame=0;_fastForwardAccumMs=100;_voiceSkippedByFastForward=NO;
    _text=(dc_text_state){.columns=30,.max_lines=3,.visible_lines=1,.current_line=-1,
        .wait_state=-1,.wait_glyph=-1,.frame=-1,.last_frame=dcIntroChapters[chapter].last_frame,
        .wait_line=255,.active=1,.x=135,.y=652,.font_size=29,.scale=1,.rgb=0xffffff};
    _textStarted=NO;_hasTextPlan=NO;
    uint32_t entryFrame=_entryFrame;_entryFrame=0;_targetEntryFrame=entryFrame;
    NSString *failure=[self seekToFrame:entryFrame updateAudio:YES];
    if(failure){_targetEntryFrame=0;return failure;}
    _liveFrame=(int32_t)entryFrame;
    _text.frame=(int32_t)entryFrame-1;_targetEntryFrame=0;
    if(entryFrame){
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [AVAudioSession.sharedInstance setActive:YES error:nil];
        if(_music&&![_music play]){[_music prepareToPlay];if(![_music play])_pausedMusic=YES;}
        if(_voice&&![_voice play]){[_voice prepareToPlay];if(![_voice play])_pausedVoice=YES;}
        if(_sound&&![_sound play]){[_sound prepareToPlay];if(![_sound play])_pausedSound=YES;}
    }
    return nil;
}
- (NSString *)seekToFrame:(uint32_t)targetFrame updateAudio:(BOOL)updateAudio {
    if(!_script)return @"Intro script is unavailable";
    dc_script_control controls[2]={{{'#','C',0},2},{{'#','P',0},5}};
    dc_script_decoded next={0};
    size_t cursor=0;
    uint8_t lastMusic[sizeof(next.music)]={0};
    uint8_t lastBackground[sizeof(next.background)]={0};
    for(uint32_t f=0;f<=targetFrame;++f) {
        dc_status status=dc_script_decode(_script.bytes,_script.length,cursor,f,controls,2,&next);
        if(status!=DC_OK)return [NSString stringWithFormat:@"Intro record %u rejected: %d",f,status];
        if(next.music[0])memcpy(lastMusic,next.music,sizeof(lastMusic));
        if(next.background[0])memcpy(lastBackground,next.background,sizeof(lastBackground));
        cursor=next.record.next_offset;
    }
    const uint8_t *source=_script.bytes;
    NSString *speaker=dcIntroDecodeWithFlag(source+next.record.speaker.offset,next.record.speaker.length,_scriptIsShiftJIS);
    NSString *body=dcIntroDecodeWithFlag(source+next.record.body.offset,next.record.body.length,_scriptIsShiftJIS);
    if(!speaker || !body)return @"Intro text encoding is unsupported";
    if(next.message[0])return @"This intro record needs a pending message adapter";
    if(lastBackground[0]) {
        NSString *name=[NSString stringWithFormat:@"%s.ema",(const char *)lastBackground];
        DCDecodedImage *image=nil;NSError *reason=nil;
        for(uint32_t i=0;i<_images.entryCount;++i) {
            if([[_images asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame) {
                image=[_images decodeImageAtIndex:i inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];break;
            }
        }
        if(!image)return reason.localizedDescription ?: @"Intro background resource is unavailable";
        if(_backgroundTexture&&_renderer)dc_vk_sprite_remove_texture(_renderer,_backgroundTexture);
        _backgroundTexture=0;_background=image;
    }
    if(updateAudio) {
        NSString *audioError=nil;
        if(lastMusic[0]) {
            BOOL musicOff=!strcmp((const char *)lastMusic,"BGMOFF");
            AVAudioPlayer *music=nil;
            if(!musicOff) {
                music=[self playerForName:lastMusic archive:@"RPP_01.pp" loop:YES error:&audioError];
                if(!music)return audioError;
                music.volume=_musicVolume;
            }
            [_music stop];_music=music;_pausedMusic=NO;
            if(_music&&targetFrame==0&&![_music play]){[_music prepareToPlay];if(![_music play])_pausedMusic=YES;}
        }
        if(next.sound[0]) {
            AVAudioPlayer *sound=[self playerForName:next.sound archive:@"RPP_14.pp" loop:NO error:&audioError];
            if(!sound)return audioError;
            sound.volume=_soundVolume;
            [_sound stop];_sound=sound;_pausedSound=NO;
            if(_sound&&targetFrame==0&&![_sound play]){[_sound prepareToPlay];if(![_sound play])_pausedSound=YES;}
        }
        if(next.controls[1][0]) {
            AVAudioPlayer *voice=[self playerForName:next.controls[1] archive:@"RPP_00.pp" loop:NO error:&audioError];
            if(!voice)return audioError;
            voice.volume=_voiceVolume;
            [_voice stop];_voice=voice;_pausedVoice=NO;
            if(_voice&&targetFrame==0&&![_voice play]){[_voice prepareToPlay];if(![_voice play])_pausedVoice=YES;}
        }
    }
    _decoded=next;_cursor=cursor;_speaker=speaker;_voiceSkippedByFastForward=NO;
    _bodyBytes=[_script subdataWithRange:NSMakeRange(next.record.body.offset,next.record.body.length)];
    if(_bodyBytes.length>=DC_TEXT_BYTE_LIMIT || _bodyBytes.length<2)return @"Intro text exceeds the native controller profile";
    _text.body_bytes=(uint32_t)_bodyBytes.length;_text.visible_lines=1;_hasTextPlan=NO;_dirty=YES;
    return nil;
}
- (void)revealCurrentRecordAtFrame:(uint32_t)targetFrame tick:(uint32_t)tick {
    _text.frame=(int32_t)targetFrame;
    _text.current_line=2;
    _text.visible_lines=1;
    _text.wait_state=-2;
    _text.wait_line=255;
    _text.wait_glyph=-1;
    _text.last_fade_row=0;
    _text.rgb=_backlogMode?0xffc8c8u:0xffffffu;
    memset(_text.alpha,0,sizeof(_text.alpha));
    uint32_t end=_text.body_bytes/2;
    for(uint32_t i=0;i<=end&&i<DC_TEXT_GLYPH_LIMIT;++i)_text.alpha[i]=255;
    _text.fade_index=MIN(end+1u,DC_TEXT_GLYPH_LIMIT);
    _textStarted=YES;
    dc_text_plan plan;
    if(dc_text_build_plan(&_text,_bodyBytes.bytes,_bodyBytes.length,0,tick,0,&plan)==DC_OK){
        _textPlan=plan;_text=plan.next;_hasTextPlan=YES;
    }
    _dirty=YES;
}
- (NSString *)stepHistory:(int32_t)step tick:(uint32_t)tick {
    if(!_text.active||_flow.waiting||!_textStarted||step==0)return nil;
    _windowHidden=NO;
    uint32_t target=self.frame;
    if(step<0) {
        if(!_backlogMode) {
            BOOL midTypewriter=(_text.body_bytes>=2 && _text.fade_index<=_text.body_bytes/2);
            _liveFrame=(int32_t)self.frame;
            _backlogMode=YES;
            _backlogReplayedVoice=NO;
            target=midTypewriter?(uint32_t)_liveFrame:(_liveFrame>0?(uint32_t)(_liveFrame-1):0u);
        } else {
            target=self.frame>0?(self.frame-1u):0u;
        }
    } else {
        if(!_backlogMode)return nil;
        target=self.frame+1u;
        if(target>=(uint32_t)_liveFrame) {
            target=(uint32_t)_liveFrame;
            _backlogMode=NO;
            if(_backlogReplayedVoice){[_voice stop];_voice=nil;_pausedVoice=NO;_backlogReplayedVoice=NO;}
        }
    }
    NSString *failure=[self seekToFrame:target updateAudio:NO];
    if(failure)return failure;
    [self revealCurrentRecordAtFrame:target tick:tick];
    return nil;
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
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    if(!player) {if(error)*error=reason.localizedDescription ?: @"Intro audio decoder failed";return nil;}
    [player prepareToPlay];
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
    NSString *speaker=dcIntroDecodeWithFlag(source+next.record.speaker.offset,next.record.speaker.length,_scriptIsShiftJIS);
    NSString *body=dcIntroDecodeWithFlag(source+next.record.body.offset,next.record.body.length,_scriptIsShiftJIS);
    if(!speaker || !body)return @"Intro text encoding is unsupported";
    if(next.message[0])return @"This intro record needs a pending message adapter";
    AVAudioPlayer *music=nil,*sound=nil,*voice=nil;NSString *audioError=nil;
    BOOL musicOff=!strcmp((const char *)next.music,"BGMOFF");
    if(next.music[0] && !musicOff) {
        music=[self playerForName:next.music archive:@"RPP_01.pp" loop:YES error:&audioError];
        if(!music)return audioError;
        music.volume=_musicVolume;
    }
    if(!_seeking || frame==_targetEntryFrame) {
        if(next.sound[0]) {
            sound=[self playerForName:next.sound archive:@"RPP_14.pp" loop:NO error:&audioError];
            if(!sound)return audioError;
            sound.volume=_soundVolume;
        }
        if(next.controls[1][0] && !_fastForward) {
            voice=[self playerForName:next.controls[1] archive:@"RPP_00.pp" loop:NO error:&audioError];
            if(!voice)return audioError;
            voice.volume=_voiceVolume;
        }
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
    if(next.music[0]) {
        [_music stop];_music=music;_pausedMusic=NO;
        if(_music&&!_seeking&&![_music play]){[_music prepareToPlay];if(![_music play])_pausedMusic=YES;}
    }
    if(!_seeking || frame==_targetEntryFrame) {
        if(next.sound[0]) {
            [_sound stop];_sound=sound;_pausedSound=NO;
            if(_sound&&!_seeking&&![_sound play]){[_sound prepareToPlay];if(![_sound play])_pausedSound=YES;}
        }
        if(next.controls[1][0]) {
            [_voice stop];_voice=voice;_pausedVoice=NO;
            _voiceSkippedByFastForward=(_fastForward && voice==nil);
            if(_voice&&!_seeking&&![_voice play]){[_voice prepareToPlay];if(![_voice play])_pausedVoice=YES;}
        } else {
            _voiceSkippedByFastForward=NO;
        }
    }
    _decoded=next;_cursor=next.record.next_offset;_speaker=speaker;
    _bodyBytes=[_script subdataWithRange:NSMakeRange(next.record.body.offset,next.record.body.length)];
    if(_bodyBytes.length>=DC_TEXT_BYTE_LIMIT || _bodyBytes.length<2)return @"Intro text exceeds the native controller profile";
    _text.body_bytes=(uint32_t)_bodyBytes.length;_text.visible_lines=1;_text.rgb=0xffffffu;_backlogMode=NO;_liveFrame=(int32_t)frame;_hasTextPlan=NO;_dirty=YES;
    return nil;
}
- (void)detachRenderer {
    if(_renderer) {
        if(_backgroundTexture)dc_vk_sprite_remove_texture(_renderer,_backgroundTexture);
        if(_textTexture)dc_vk_sprite_remove_texture(_renderer,_textTexture);
        if(_windowFrameTexture)dc_vk_sprite_remove_texture(_renderer,_windowFrameTexture);
        if(_nextPromptTexture)dc_vk_sprite_remove_texture(_renderer,_nextPromptTexture);
    }
    _renderer=NULL;_backgroundTexture=_textTexture=_windowFrameTexture=_nextPromptTexture=0;_dirty=YES;_needsResumeAtNextTick=YES;
}
- (void)pause {
    _pausedMusic=_pausedMusic||_music.isPlaying;
    _pausedVoice=_pausedVoice||_voice.isPlaying;
    _pausedSound=_pausedSound||_sound.isPlaying;
    [_music pause];[_voice pause];[_sound pause];[_selection stop];_touching=NO;_needsResumeAtNextTick=YES;
}
- (void)dealloc { [self detachRenderer];[_music stop];[_sound stop];[_voice stop];[_selection stop]; }
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
    UIColor *speakerColor=_backlogMode?[UIColor colorWithRed:1.0 green:200.0/255.0 blue:200.0/255.0 alpha:1.0]:UIColor.whiteColor;
    NSDictionary *speakerBlack=@{NSFontAttributeName:font,NSForegroundColorAttributeName:UIColor.blackColor};
    NSDictionary *speakerWhite=@{NSFontAttributeName:font,NSForegroundColorAttributeName:speakerColor};
    CGFloat speakerScale=dcIntroWidthScale(_speaker,font,_decoded.record.speaker.length);
    for(unsigned j=0;j<4;++j)dcIntroDraw(context,_speaker,CGPointMake(58+shadowX[j],652+shadowY[j]),speakerBlack,speakerScale);
    dcIntroDraw(context,_speaker,CGPointMake(58,652),speakerWhite,speakerScale);
    for(uint32_t i=0;i<_textPlan.count;++i) {
        const dc_text_glyph *glyph=&_textPlan.glyphs[i];
        size_t length=glyph->bytes[0] ? (glyph->bytes[1] ? 2 : 1) : 0;
        uint32_t alpha=glyph->color>>24;
        if(!length || !alpha)continue;
        NSString *label=dcIntroDecodeWithFlag(glyph->bytes,length,_scriptIsShiftJIS);
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
        case DC_INTRO_CLEANUP:
            _pausedMusic=_pausedVoice=_pausedSound=NO;
            [_music stop];[_voice stop];[_sound stop];[_selection stop];break;
        case DC_INTRO_ENTER_CHAPTER:
            _pendingChapter=command.value;_completed=YES;break;
        case DC_INTRO_UNLOCK_PROGRESS: {
            uint8_t *bytes=_gameState.mutableBytes;
            if(!bytes[0x23])bytes[0x23]=1;
            if(!bytes[0x21bb])bytes[0x21bb]=1;
            if(!bytes[0x4353])bytes[0x4353]=1;
            break;
        }
        case DC_INTRO_CLEAR_FINISH: memset(_finishFlags,0,sizeof(_finishFlags));break;
        case DC_INTRO_STOP_AUDIO:
            if(command.value==2){_pausedMusic=_pausedMusic||_music.isPlaying;[_music pause];}
            else if(command.value==0){_pausedVoice=NO;[_voice stop];}
            else {_pausedSound=NO;[_sound stop];}
            break;
        case DC_INTRO_QUIT:
            _pausedMusic=_pausedVoice=_pausedSound=NO;
            [_music stop];[_voice stop];[_sound stop];[_selection stop];
            _pendingChapter=DC_INTRO_CHAPTERS;_completed=YES;
            break;
        case DC_INTRO_BACKUP: break;
        case DC_INTRO_ENTER_AUX:
            if(command.value==6){_pendingChapter=DC_INTRO_CHAPTERS;_completed=YES;}
            else {_auxiliaryDestination=command.value;_touching=NO;_needsResumeAtNextTick=YES;}
            break;
        default: return @"Intro auxiliary destination is not implemented";
        }
    }
    _flow=plan->next;return nil;
}
- (NSString *)drawWithRenderer:(dc_vk_sprite *)renderer transition:(DCStartupScene *)transition
        tick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height {
    if(_renderer!=renderer) { [self detachRenderer];_renderer=renderer; }
    if(_completed)return nil;
    if(_needsResumeAtNextTick) [self resumeAtTick:tick];
    if(_pausedMusic) {
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [AVAudioSession.sharedInstance setActive:YES error:nil];
        if(!_music || [_music play] || ([_music prepareToPlay] && [_music play])) _pausedMusic=NO;
    }
    if(_pausedVoice) {
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [AVAudioSession.sharedInstance setActive:YES error:nil];
        if(!_voice || [_voice play] || ([_voice prepareToPlay] && [_voice play])) _pausedVoice=NO;
    }
    if(_pausedSound) {
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [AVAudioSession.sharedInstance setActive:YES error:nil];
        if(!_sound || [_sound play] || ([_sound prepareToPlay] && [_sound play])) _pausedSound=NO;
    }
    uint32_t ready=0,delta=_tickInitialized ? tick-_lastTick : 0;
    if([transition queryTransitionReady:&ready]!=DC_OK)return @"Intro transition query failed";
    dc_intro_plan flowPlan;
    if(dc_intro_transition(&_flow,dcIntroChapters,DC_INTRO_CHAPTERS,ready,&flowPlan)!=DC_OK)return @"Intro transition planning failed";
    NSString *flowError=[self applyFlow:&flowPlan transition:transition tick:tick];if(flowError)return flowError;
    if(_text.active && _initialUpdateSkipped) {
        BOOL fastAdvanceReady=(_fastForward && !_flow.waiting);
        BOOL clickAdvance=(!_flow.waiting && (!touching && _touching));
        BOOL requestAdvance=!_textStarted || clickAdvance || fastAdvanceReady;
        if(requestAdvance && _windowHidden && _textStarted && !_fastForward) {
            _windowHidden=NO;
        } else if(requestAdvance && _backlogMode) {
            _windowHidden=NO;
            _backlogMode=NO;
            if(_backlogReplayedVoice){[_voice stop];_voice=nil;_pausedVoice=NO;_backlogReplayedVoice=NO;}
            NSString *failure=[self seekToFrame:(uint32_t)_liveFrame updateAudio:NO];
            if(failure)return failure;
            [self revealCurrentRecordAtFrame:(uint32_t)_liveFrame tick:tick];
        } else if(requestAdvance) {
            _windowHidden=NO;
            _backlogReplayedVoice=NO;
            dc_text_advance_plan advance;
            if(dc_text_advance(&_text,_fastForward?1:0,&advance)!=DC_OK)return @"Intro text advance failed";
            _text=advance.next;_textStarted=YES;
            if(advance.load_record) {NSString *failure=[self loadRecord];if(failure)return failure;}
            else if(_text.frame>=0)_liveFrame=_text.frame;
        }
        if(_text.active && !_backlogMode) {
            dc_text_plan plan;
            if(dc_text_build_plan(&_text,_bodyBytes.bytes,_bodyBytes.length,(int32_t)delta,tick,_fastForward?1:0,&plan)!=DC_OK)return @"Intro text layout/fade failed";
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
    if(_windowFrame && !_windowFrameTexture)
        dc_vk_sprite_upload(_renderer,_windowFrame.width,_windowFrame.height,_windowFrame.rgba.bytes,_windowFrame.rgba.length,&_windowFrameTexture);
    if(_nextPrompt && !_nextPromptTexture)
        dc_vk_sprite_upload(_renderer,_nextPrompt.width,_nextPrompt.height,_nextPrompt.rgba.bytes,_nextPrompt.rgba.length,&_nextPromptTexture);
    if(_hasTextPlan && _dirty) {NSString *failure=[self uploadText];if(failure)return failure;}
    float scale=fminf((float)width/1024,(float)height/768);
    dc_sprite_pose pose={.width=1024*scale,.height=768*scale,.x=(width-1024*scale)*.5f,.y=(height-768*scale)*.5f,
        .z=.5f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
    dc_vk_sprite_item items[4]={0};size_t count=0;
    if(_backgroundTexture)items[count++]=(dc_vk_sprite_item){.pose=pose,.texture=_backgroundTexture,.blend_mode=3};
    if(!_captureEnabled && !_windowHidden && _text.active && _windowFrameTexture) {
        dc_sprite_pose windowPose=pose;
        windowPose.y=pose.y+608.0f*scale;
        windowPose.width=1024.0f*scale;
        windowPose.height=160.0f*scale;
        windowPose.alpha=98.0f/255.0f;
        items[count++]=(dc_vk_sprite_item){.pose=windowPose,.texture=_windowFrameTexture,.blend_mode=3};
    }
    if((_captureEnabled || !_windowHidden) && _textTexture)items[count++]=(dc_vk_sprite_item){.pose=pose,.texture=_textTexture,.blend_mode=3};
    if(!_captureEnabled && !_windowHidden && !_backlogMode && _text.active && _nextPromptTexture && _hasTextPlan &&
       _text.body_bytes>=2 && _text.alpha[_text.body_bytes/2-1]==255 && ((tick/500u)%2u)==0) {
        dc_sprite_pose promptPose=pose;
        promptPose.x=pose.x+954.0f*scale;
        promptPose.y=pose.y+720.0f*scale;
        promptPose.width=32.0f*scale;
        promptPose.height=32.0f*scale;
        items[count++]=(dc_vk_sprite_item){.pose=promptPose,.texture=_nextPromptTexture,.blend_mode=3};
    }
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
