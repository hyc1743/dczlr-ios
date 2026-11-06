#import "DCGameAudio.h"
#import "DCArchive.h"
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#include "dc_scene_ui.h"
#include "dc_config.h"
#include <math.h>

@interface DCGameAudio () <AVAudioPlayerDelegate>
@end

static NSString *DCGameplaySlotName(NSUInteger slot) {
    if(slot>=35)return nil;
    char name[16];
    return dc_scene_effect_name((uint32_t)slot,name,sizeof(name))==DC_OK?[NSString stringWithUTF8String:name]:nil;
}

@implementation DCGameAudio {
    AVAudioPlayer *_music,*_selection;
    NSMutableDictionary<NSString *,DCArchive *> *_archives;
    NSMutableDictionary<NSString *,AVAudioPlayer *> *_gameplayEffects,*_gameplayVoices;
    NSMutableSet<NSString *> *_pausedGameplayEffects;
    NSMutableSet<NSString *> *_pausedGameplayVoices;
    BOOL _resumeTitleAfterSystem,_sessionConfigured;
    float _voiceVolume,_effectVolume,_musicVolume;
    NSString *_directory;
    NSString *_voiceChainNext;
    BOOL _advanced;
}
- (BOOL)ensureAudioSession {
    NSError *reason=nil;
    AVAudioSession *session=AVAudioSession.sharedInstance;
    if(!_sessionConfigured) {
        if(![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&reason])
            return NO;
        _sessionConfigured=YES;
    }
    return [session setActive:YES error:&reason];
}
- (NSData *)sound:(NSString *)name inArchive:(NSString *)file directory:(NSString *)directory error:(NSString **)error {
    NSError *reason=nil;
    if(!_archives)_archives=[NSMutableDictionary dictionary];
    NSString *path=[directory stringByAppendingPathComponent:file];
    DCArchive *archive=_archives[path];
    if(!archive) {
        archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:path] error:&reason];
        if(archive)_archives[path]=archive;
    }
    if (!archive) {if(error)*error=reason.localizedDescription;return nil;}
    for (uint32_t i=0;i<archive.entryCount;++i) {
        if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame) {
            NSData *data=[archive readEntryAtIndex:i limit:32*1024*1024 error:&reason];
            if(!data && error)*error=reason.localizedDescription;
            return data;
        }
    }
    if(error)*error=[NSString stringWithFormat:@"Missing audio resource: %@",name];
    return nil;
}
- (instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error {
    if (!(self=[super init])) return nil;
    _directory=[directory copy];
    _voiceVolume=_effectVolume=_musicVolume=1;
    NSData *music=[self sound:@"bgm000.wav" inArchive:@"RPP_01.pp" directory:directory error:error];
    NSData *selection=[self sound:@"se100.wav" inArchive:@"RPP_14.pp" directory:directory error:error];
    if(!music || !selection)return nil;
    NSError *reason=nil;
    _music=[[AVAudioPlayer alloc] initWithData:music error:&reason];
    if(!_music) {if(error)*error=reason.localizedDescription;return nil;}
    _selection=[[AVAudioPlayer alloc] initWithData:selection error:&reason];
    if(!_selection) {if(error)*error=reason.localizedDescription;return nil;}
    _music.numberOfLoops=-1;
    if(![_music prepareToPlay] || ![_selection prepareToPlay]) {if(error)*error=@"Audio decoder preparation failed";return nil;}
    return self;
}
- (NSString *)prepareGameplayAudio {
    @synchronized(self) {
        if(!_gameplayEffects)_gameplayEffects=[NSMutableDictionary dictionary];
        return nil;
    }
}
- (BOOL)playGameplayEffectNamed:(NSString *)name {
    @synchronized(self) {
        if(!name.length)return NO;
        if(!_gameplayEffects)_gameplayEffects=[NSMutableDictionary dictionary];
        AVAudioPlayer *player=_gameplayEffects[name];
        if(!player) {
            NSString *error=nil;NSData *data=[self sound:name inArchive:@"RPP_14.pp" directory:_directory error:&error];
            if(!data)return NO;
            NSError *reason=nil;player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
            if(!player || ![player prepareToPlay])return NO;
            _gameplayEffects[name]=player;
        }
        if(![self ensureAudioSession])return NO;
        if(player.isPlaying)[player stop];
        player.currentTime=0;player.volume=_effectVolume;
        if([player play])return YES;
        [player prepareToPlay];
        return [player play];
    }
}
- (BOOL)playGameplaySlot:(NSUInteger)slot {
    NSString *name=DCGameplaySlotName(slot);
    return name && [self playGameplayEffectNamed:name];
}
- (BOOL)gameplaySlotBusy:(NSUInteger)slot {
    @synchronized(self) {
        NSString *name=DCGameplaySlotName(slot);
        return name && _gameplayEffects[name].isPlaying;
    }
}
- (BOOL)resumeGameplayEffects {
    @synchronized(self) {
        if(!_pausedGameplayEffects.count)return YES;
        if(![self ensureAudioSession])return NO;
        for(NSString *name in _pausedGameplayEffects)if(![_gameplayEffects[name] play])return NO;
        [_pausedGameplayEffects removeAllObjects];return YES;
    }
}
- (BOOL)playGameplayVoiceNamed:(NSString *)name {
    @synchronized(self) {
        if (!name.length) return NO;
        AVAudioPlayer *player=_gameplayVoices[name];
        if (!player) {
            unichar prefix=[name characterAtIndex:0];
            NSString *primary=(prefix=='b'||prefix=='B')?@"RPP_12.pp":((prefix=='c'||prefix=='C')?@"RPP_13.pp":@"RPP_11.pp");
            NSArray<NSString *> *archives=@[primary,@"RPP_11.pp",@"RPP_12.pp",@"RPP_13.pp"];
            NSData *data=nil;
            for (NSString *archive in archives) {
                NSString *error=nil;
                data=[self sound:name inArchive:archive directory:_directory error:&error];
                if (data) break;
            }
            if (!data) return NO;
            NSError *reason=nil;player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
            if (!player || ![player prepareToPlay]) return NO;
            player.meteringEnabled=YES;
            if (!_gameplayVoices) _gameplayVoices=[NSMutableDictionary dictionary];
            _gameplayVoices[name]=player;
        }
        for (AVAudioPlayer *other in _gameplayVoices.allValues) if (other.isPlaying) [other stop];
        player.delegate=self;
        if (name.length>=3 && [[name substringFromIndex:1] caseInsensitiveCompare:@"st001_01.wav"]==NSOrderedSame)
            _voiceChainNext=[NSString stringWithFormat:@"%cst002_01.wav",[name characterAtIndex:0]];
        else
            _voiceChainNext=nil;
        if(![self ensureAudioSession])return NO;
        player.currentTime=0;
        player.volume=_voiceVolume;
        if([player play])return YES;
        [player prepareToPlay];
        return [player play];
    }
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    NSString *next=nil;
    @synchronized(self) {
        if (!flag || player.delegate!=self) return;
        next=_voiceChainNext;_voiceChainNext=nil;
    }
    if (next) [self playGameplayVoiceNamed:next];
}
- (NSString *)startTitleMusic {
    @synchronized(self) {
        if (_music.isPlaying) return nil;
        if(![self ensureAudioSession]) return @"Audio session activation failed";
        if(![_music play]) return @"Title music did not start";
        return nil;
    }
}
- (BOOL)musicAdvanced {
    @synchronized(self) {
        if(_music.isPlaying && _music.currentTime>.1)_advanced=YES;
        return _advanced;
    }
}
- (BOOL)playMenuSelection {
    @synchronized(self) {
        if(_selection.isPlaying)[_selection stop];
        _selection.volume=_effectVolume;
        _selection.currentTime=0;
        return [_selection play];
    }
}
- (BOOL)selectionBusy { @synchronized(self) { return _selection.isPlaying; } }
- (BOOL)gameplayVoiceBusy {
    @synchronized(self) {
        for (AVAudioPlayer *player in _gameplayVoices.allValues) if (player.isPlaying) return YES;
        return NO;
    }
}
- (float)gameplayVoiceMouthPhase {
    @synchronized(self) {
        for (AVAudioPlayer *player in _gameplayVoices.allValues) {
            if (!player.isPlaying) continue;
            [player updateMeters];
            float power=[player averagePowerForChannel:0];
            float wave=0.5f+0.5f*sinf((float)player.currentTime*18.0f);
            float level=(power>-60.0f)?fmaxf(0.0f,fminf(1.0f,(power+45.0f)/38.0f)):(0.35f+0.55f*wave);
            return fmaxf(0.0f,fminf(9.0f,(0.65f*level+0.35f*wave)*9.0f));
        }
        return 0.0f;
    }
}
- (void)stopTitleMusic { @synchronized(self) { [_music stop]; } }
- (void)cancelGameplayVoice {
    @synchronized(self) {
        _voiceChainNext=nil;
        for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
    }
}
- (void)pause {
    @synchronized(self) {
        _voiceChainNext=nil;[_music pause];[_selection stop];
        if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
        for(NSString *name in _gameplayEffects) {
            AVAudioPlayer *player=_gameplayEffects[name];
            if(player.isPlaying)[_pausedGameplayEffects addObject:name];
            [player pause];
        }
        for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
    }
}
- (void)applyConfiguration:(NSData *)configuration {
    @synchronized(self) {
        dc_config state;if(dc_config_decode(configuration.bytes,configuration.length,&state)!=DC_OK)return;
        float voice,bgm,se;dc_config_slider_value(&state,0,&voice);dc_config_slider_value(&state,1,&bgm);dc_config_slider_value(&state,2,&se);
        _voiceVolume=powf(10,voice/2000);_effectVolume=powf(10,se/2000);_musicVolume=powf(10,bgm/2000);
        _music.volume=_musicVolume;_selection.volume=_effectVolume;
        for(AVAudioPlayer *player in _gameplayEffects.allValues)player.volume=_effectVolume;
        for(AVAudioPlayer *player in _gameplayVoices.allValues)player.volume=_voiceVolume;
    }
}
- (void)suspendForSystemPage {
    @synchronized(self) {
        _resumeTitleAfterSystem=_music.isPlaying;[_music pause];[_selection stop];
        if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
        if(!_pausedGameplayVoices)_pausedGameplayVoices=[NSMutableSet set];
        for(NSString *name in _gameplayEffects){AVAudioPlayer *player=_gameplayEffects[name];if(player.isPlaying)[_pausedGameplayEffects addObject:name];[player pause];}
        for(NSString *name in _gameplayVoices){AVAudioPlayer *player=_gameplayVoices[name];if(player.isPlaying)[_pausedGameplayVoices addObject:name];[player pause];}
    }
}
- (BOOL)resumeAfterSystemPage {
    @synchronized(self) {
        if(_resumeTitleAfterSystem&&![_music play])return NO;_resumeTitleAfterSystem=NO;
        if(![self resumeGameplayEffects])return NO;
        for(NSString *name in _pausedGameplayVoices)if(![_gameplayVoices[name] play])return NO;
        [_pausedGameplayVoices removeAllObjects];return YES;
    }
}
- (void)dealloc { [_music stop];[_selection stop];for(AVAudioPlayer *player in _gameplayEffects.allValues)[player stop];for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop]; }
@end
