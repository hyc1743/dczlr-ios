#import "DCGameAudio.h"
#import "DCArchive.h"
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#include "dc_scene_ui.h"
#include "dc_config.h"
#include <ctype.h>
#include <math.h>

@interface DCGameAudio () <AVAudioPlayerDelegate>
@end

static NSString *DCGameplaySlotName(NSUInteger slot) {
    if(slot==100u)return @"camera.wav";
    if(slot>=35)return nil;
    char name[16];
    return dc_scene_effect_name((uint32_t)slot,name,sizeof(name))==DC_OK?[NSString stringWithUTF8String:name]:nil;
}

static NSString *DCGameplayMusicName(uint32_t sceneType,uint32_t mapSelector) {
    if(sceneType==2)return nil;
    switch(mapSelector) {
        case 0: return (sceneType==7||sceneType==12)?@"bgm100.wav":@"bgm101.wav";
        case 1: return @"bgm102.wav";
        case 2: return nil;
        case 3: return @"bgm107.wav";
        case 4: return @"bgm108.wav";
        case 5: return @"bgm103.wav";
        case 6: return @"bgm104.wav";
        case 7: return @"bgm105.wav";
        case 8: return @"bgm106.wav";
        default: return nil;
    }
}

@implementation DCGameAudio {
    AVAudioPlayer *_music,*_extraMusic,*_gameplayMusic,*_selection;
    NSMutableDictionary<NSString *,DCArchive *> *_archives;
    NSMutableDictionary<NSString *,AVAudioPlayer *> *_gameplayEffects,*_gameplayVoices;
    NSMutableSet<NSString *> *_pausedGameplayEffects;
    NSMutableSet<NSString *> *_pausedGameplayVoices;
    BOOL _resumeTitleAfterSystem,_resumeExtraAfterSystem,_resumeGameplayMusicAfterSystem,_suspendedForSystemPage,_sessionConfigured;
    BOOL _pausedTitleMusic,_pausedExtraMusic,_pausedGameplayMusic;
    float _voiceVolume,_effectVolume,_musicVolume;
    NSString *_directory;
    NSString *_gameplayMusicName;
    NSString *_voiceChainNext;
    BOOL _advanced;
}
- (BOOL)ensureAudioSession {
    NSError *reason=nil;
    AVAudioSession *session=AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&reason];
    _sessionConfigured=YES;
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
            if(!data)data=[self sound:name inArchive:@"RPP_17.pp" directory:_directory error:&error];
            if(!data)return NO;
            NSError *reason=nil;player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
            if(!player || ![player prepareToPlay])return NO;
            _gameplayEffects[name]=player;
        }
        if(player.isPlaying)[player stop];
        player.numberOfLoops=0;
        player.currentTime=0;player.volume=_effectVolume;
        if([self ensureAudioSession] && ([player play] || ([player prepareToPlay] && [player play])))return YES;
        if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
        [_pausedGameplayEffects addObject:name];
        return YES;
    }
}
- (BOOL)playGameplaySlot:(NSUInteger)slot {
    NSString *name=DCGameplaySlotName(slot);
    return name && [self playGameplayEffectNamed:name];
}
- (void)setGameplayLoopSlot:(NSUInteger)slot active:(BOOL)active {
    @synchronized(self) {
        NSString *name=DCGameplaySlotName(slot);
        if(!name.length)return;
        if(!active) {
            AVAudioPlayer *player=_gameplayEffects[name];
            if(player) {
                if(player.isPlaying)[player stop];
                player.numberOfLoops=0;
                player.currentTime=0;
            }
            [_pausedGameplayEffects removeObject:name];
            return;
        }
        if(!_gameplayEffects)_gameplayEffects=[NSMutableDictionary dictionary];
        AVAudioPlayer *player=_gameplayEffects[name];
        if(!player) {
            NSString *error=nil;NSData *data=[self sound:name inArchive:@"RPP_14.pp" directory:_directory error:&error];
            if(!data)return;
            NSError *reason=nil;player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
            if(!player || ![player prepareToPlay])return;
            _gameplayEffects[name]=player;
        }
        player.numberOfLoops=-1;
        player.volume=_effectVolume;
        if(player.isPlaying || [_pausedGameplayEffects containsObject:name])return;
        player.currentTime=0;
        if(!_suspendedForSystemPage && [self ensureAudioSession] && ([player play] || ([player prepareToPlay] && [player play])))return;
        if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
        [_pausedGameplayEffects addObject:name];
    }
}
- (BOOL)gameplaySlotBusy:(NSUInteger)slot {
    @synchronized(self) {
        NSString *name=DCGameplaySlotName(slot);
        return name && (_gameplayEffects[name].isPlaying || [_pausedGameplayEffects containsObject:name]);
    }
}
- (BOOL)resumeGameplayEffects {
    @synchronized(self) {
        if(_suspendedForSystemPage)return YES;
        if(!_pausedGameplayMusic && !_pausedGameplayEffects.count && !_pausedGameplayVoices.count)return YES;
        if(![self ensureAudioSession])return YES;
        if(_pausedGameplayMusic && _gameplayMusic) {
            _gameplayMusic.volume=_musicVolume;
            if([_gameplayMusic play] || ([_gameplayMusic prepareToPlay] && [_gameplayMusic play]))
                _pausedGameplayMusic=NO;
        }
        for(NSString *name in [_pausedGameplayEffects allObjects]) {
            AVAudioPlayer *player=_gameplayEffects[name];
            if(player && ![player play]) { [player prepareToPlay]; [player play]; }
            [_pausedGameplayEffects removeObject:name];
        }
        for(NSString *name in [_pausedGameplayVoices allObjects]) {
            AVAudioPlayer *player=_gameplayVoices[name];
            if(player && ![player play]) { [player prepareToPlay]; [player play]; }
            [_pausedGameplayVoices removeObject:name];
        }
        return YES;
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
        unichar targetPrefix=(unichar)tolower([name characterAtIndex:0]);
        for (NSString *otherName in _gameplayVoices) {
            if (!otherName.length || (unichar)tolower([otherName characterAtIndex:0])!=targetPrefix) continue;
            AVAudioPlayer *other=_gameplayVoices[otherName];
            if (other.isPlaying) [other stop];
        }
        for (NSString *pausedName in [_pausedGameplayVoices allObjects]) {
            if (pausedName.length && (unichar)tolower([pausedName characterAtIndex:0])==targetPrefix)
                [_pausedGameplayVoices removeObject:pausedName];
        }
        player.delegate=self;
        if (name.length>=3 && [[name substringFromIndex:1] caseInsensitiveCompare:@"st001_01.wav"]==NSOrderedSame)
            _voiceChainNext=[NSString stringWithFormat:@"%cst002_01.wav",[name characterAtIndex:0]];
        else if (_voiceChainNext.length && (unichar)tolower([_voiceChainNext characterAtIndex:0])==targetPrefix)
            _voiceChainNext=nil;
        player.currentTime=0;
        player.volume=_voiceVolume;
        if([self ensureAudioSession] && ([player play] || ([player prepareToPlay] && [player play])))return YES;
        if(!_pausedGameplayVoices)_pausedGameplayVoices=[NSMutableSet set];
        [_pausedGameplayVoices addObject:name];
        return YES;
    }
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    NSString *next=nil;
    @synchronized(self) {
        if (!flag || player.delegate!=self || !_voiceChainNext.length) return;
        unichar chainPrefix=(unichar)tolower([_voiceChainNext characterAtIndex:0]);
        BOOL matchesFinished=NO;
        for (NSString *key in _gameplayVoices) {
            if (_gameplayVoices[key]==player && key.length && (unichar)tolower([key characterAtIndex:0])==chainPrefix) {
                matchesFinished=YES;
                break;
            }
        }
        if (!matchesFinished) return;
        next=_voiceChainNext;_voiceChainNext=nil;
    }
    if (next) [self playGameplayVoiceNamed:next];
}
- (NSString *)startTitleMusic {
    @synchronized(self) {
        _pausedExtraMusic=NO;
        if (_extraMusic.isPlaying) [_extraMusic stop];
        if (_music.isPlaying) { _pausedTitleMusic=NO; return nil; }
        if(![self ensureAudioSession]) { _pausedTitleMusic=YES; return nil; }
        if([_music play] || ([_music prepareToPlay] && [_music play])) _pausedTitleMusic=NO;
        else _pausedTitleMusic=YES;
        return nil;
    }
}
- (NSString *)startExtraMusic {
    @synchronized(self) {
        _pausedTitleMusic=NO;
        if (_music.isPlaying) [_music stop];
        if (!_extraMusic) {
            NSString *error=nil;
            NSData *extraData=[self sound:@"bgm012.wav" inArchive:@"RPP_01.pp" directory:_directory error:&error];
            if (extraData) {
                NSError *reason=nil;
                _extraMusic=[[AVAudioPlayer alloc] initWithData:extraData error:&reason];
                if (_extraMusic) {
                    _extraMusic.numberOfLoops=-1;
                    _extraMusic.volume=_musicVolume;
                    [_extraMusic prepareToPlay];
                }
            }
        }
        AVAudioPlayer *target=_extraMusic?:_music;
        if (target.isPlaying) { _pausedExtraMusic=NO; return nil; }
        if(![self ensureAudioSession]) { _pausedExtraMusic=YES; return nil; }
        target.volume=_musicVolume;
        if([target play] || ([target prepareToPlay] && [target play])) _pausedExtraMusic=NO;
        else _pausedExtraMusic=YES;
        return nil;
    }
}
- (NSString *)startGameplayMusicForSceneType:(uint32_t)sceneType map:(uint32_t)mapSelector {
    NSString *name=DCGameplayMusicName(sceneType,mapSelector);
    return [self startGameplayMusicNamed:name?:@""];
}
- (NSString *)startGameplayMusicNamed:(NSString *)name {
    @synchronized(self) {
        BOOL silent=(!name.length || [name caseInsensitiveCompare:@"none"]==NSOrderedSame);
        if(!silent && _gameplayMusic && _gameplayMusicName &&
           [_gameplayMusicName caseInsensitiveCompare:name]==NSOrderedSame &&
           (_gameplayMusic.isPlaying || _pausedGameplayMusic)) {
            return nil;
        }
        if(_gameplayMusic.isPlaying)[_gameplayMusic stop];
        _gameplayMusic=nil;
        _gameplayMusicName=nil;
        _pausedGameplayMusic=NO;
        _resumeGameplayMusicAfterSystem=NO;
        if(silent)return nil;
        NSString *error=nil;
        NSData *data=[self sound:name inArchive:@"RPP_01.pp" directory:_directory error:&error];
        if(!data)return nil;
        NSError *reason=nil;
        _gameplayMusic=[[AVAudioPlayer alloc] initWithData:data error:&reason];
        if(!_gameplayMusic)return nil;
        _gameplayMusicName=[name copy];
        _gameplayMusic.numberOfLoops=-1;
        _gameplayMusic.volume=_musicVolume;
        [_gameplayMusic prepareToPlay];
        if(!_suspendedForSystemPage && [self ensureAudioSession] &&
           ([_gameplayMusic play] || ([_gameplayMusic prepareToPlay] && [_gameplayMusic play]))) {
            _pausedGameplayMusic=NO;
        } else {
            _pausedGameplayMusic=YES;
        }
        return nil;
    }
}
- (BOOL)musicAdvanced {
    @synchronized(self) {
        if((_music.isPlaying && _music.currentTime>.1) ||
           (_extraMusic.isPlaying && _extraMusic.currentTime>.1) ||
           (_gameplayMusic.isPlaying && _gameplayMusic.currentTime>.1))_advanced=YES;
        return _advanced;
    }
}
- (BOOL)playMenuSelection {
    @synchronized(self) {
        if(_selection.isPlaying)[_selection stop];
        _selection.volume=_effectVolume;
        _selection.currentTime=0;
        if([self ensureAudioSession] && ([_selection play] || ([_selection prepareToPlay] && [_selection play])))return YES;
        return _selection!=nil;
    }
}
- (BOOL)selectionBusy { @synchronized(self) { return _selection.isPlaying; } }
- (BOOL)gameplayVoiceBusy {
    @synchronized(self) {
        if (_pausedGameplayVoices.count > 0) return YES;
        for (AVAudioPlayer *player in _gameplayVoices.allValues) if (player.isPlaying) return YES;
        return NO;
    }
}
- (BOOL)gameplayVoiceBusyForPrefix:(char)prefix {
    @synchronized(self) {
        unichar target=(unichar)tolower((unsigned char)prefix);
        for (NSString *paused in _pausedGameplayVoices) {
            if (paused.length && (unichar)tolower([paused characterAtIndex:0])==target) return YES;
        }
        for (NSString *name in _gameplayVoices) {
            if (!name.length || (unichar)tolower([name characterAtIndex:0])!=target) continue;
            if (_gameplayVoices[name].isPlaying) return YES;
        }
        return NO;
    }
}
- (float)gameplayVoiceMouthPhase {
    return [self gameplayVoiceMouthPhaseForPrefix:0];
}
- (float)gameplayVoiceMouthPhaseForPrefix:(char)prefix {
    @synchronized(self) {
        unichar target=prefix?(unichar)tolower((unsigned char)prefix):0;
        for (NSString *name in _gameplayVoices) {
            if (target && (!name.length || (unichar)tolower([name characterAtIndex:0])!=target)) continue;
            AVAudioPlayer *player=_gameplayVoices[name];
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
- (void)stopTitleMusic {
    @synchronized(self) {
        [_music stop];
        _pausedTitleMusic=NO;
        _resumeTitleAfterSystem=NO;
        _suspendedForSystemPage=NO;
    }
}
- (void)stopExtraMusic {
    @synchronized(self) {
        [_extraMusic stop];
        if(_extraMusic)_extraMusic.currentTime=0;
        _pausedExtraMusic=NO;
        _resumeExtraAfterSystem=NO;
        _suspendedForSystemPage=NO;
    }
}
- (void)stopGameplayAudio {
    @synchronized(self) {
        _voiceChainNext=nil;
        _suspendedForSystemPage=NO;
        _pausedGameplayMusic=NO;
        _resumeGameplayMusicAfterSystem=NO;
        if(_gameplayMusic.isPlaying)[_gameplayMusic stop];
        _gameplayMusic=nil;
        _gameplayMusicName=nil;
        [_pausedGameplayEffects removeAllObjects];
        [_pausedGameplayVoices removeAllObjects];
        for(AVAudioPlayer *player in _gameplayEffects.allValues){[player stop];player.numberOfLoops=0;}
        for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
    }
}
- (void)cancelGameplayVoice {
    @synchronized(self) {
        _voiceChainNext=nil;
        [_pausedGameplayVoices removeAllObjects];
        for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
    }
}
- (void)stopActiveGameplayEffectsAndVoice {
    @synchronized(self) {
        _voiceChainNext=nil;
        [_pausedGameplayVoices removeAllObjects];
        for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
        for(NSString *name in _gameplayEffects) {
            if([name caseInsensitiveCompare:@"se101.wav"]==NSOrderedSame)continue;
            AVAudioPlayer *player=_gameplayEffects[name];
            if(player.isPlaying)[player stop];
            player.numberOfLoops=0;
            [_pausedGameplayEffects removeObject:name];
        }
    }
}
- (void)pause {
    @synchronized(self) {
        _pausedTitleMusic=_pausedTitleMusic||_music.isPlaying;
        _pausedExtraMusic=_pausedExtraMusic||_extraMusic.isPlaying;
        _pausedGameplayMusic=_pausedGameplayMusic||_gameplayMusic.isPlaying;
        [_music pause];[_extraMusic pause];[_gameplayMusic pause];[_selection stop];
        if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
        if(!_pausedGameplayVoices)_pausedGameplayVoices=[NSMutableSet set];
        for(NSString *name in _gameplayEffects) {
            AVAudioPlayer *player=_gameplayEffects[name];
            if(player.isPlaying)[_pausedGameplayEffects addObject:name];
            [player pause];
        }
        for(NSString *name in _gameplayVoices) {
            AVAudioPlayer *player=_gameplayVoices[name];
            if(player.isPlaying)[_pausedGameplayVoices addObject:name];
            [player pause];
        }
    }
}
- (void)applyConfiguration:(NSData *)configuration {
    @synchronized(self) {
        dc_config state;if(dc_config_decode(configuration.bytes,configuration.length,&state)!=DC_OK)return;
        float voice,bgm,se;dc_config_slider_value(&state,0,&voice);dc_config_slider_value(&state,1,&bgm);dc_config_slider_value(&state,2,&se);
        _voiceVolume=powf(10,voice/2000);_effectVolume=powf(10,se/2000);_musicVolume=powf(10,bgm/2000);
        _music.volume=_musicVolume;if(_extraMusic)_extraMusic.volume=_musicVolume;
        if(_gameplayMusic)_gameplayMusic.volume=_musicVolume;
        _selection.volume=_effectVolume;
        for(AVAudioPlayer *player in _gameplayEffects.allValues)player.volume=_effectVolume;
        for(AVAudioPlayer *player in _gameplayVoices.allValues)player.volume=_voiceVolume;
    }
}
- (void)suspendForSystemPage {
    @synchronized(self) {
        if(_suspendedForSystemPage)return;
        _suspendedForSystemPage=YES;
        _resumeTitleAfterSystem=_pausedTitleMusic||_music.isPlaying;
        _pausedTitleMusic=NO;[_music pause];
        _resumeExtraAfterSystem=_pausedExtraMusic||_extraMusic.isPlaying;
        _pausedExtraMusic=NO;[_extraMusic pause];
        _resumeGameplayMusicAfterSystem=_pausedGameplayMusic||_gameplayMusic.isPlaying;
        _pausedGameplayMusic=NO;[_gameplayMusic pause];
        [_selection stop];
        if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
        if(!_pausedGameplayVoices)_pausedGameplayVoices=[NSMutableSet set];
        for(NSString *name in _gameplayEffects){AVAudioPlayer *player=_gameplayEffects[name];if(player.isPlaying)[_pausedGameplayEffects addObject:name];[player pause];}
        for(NSString *name in _gameplayVoices){AVAudioPlayer *player=_gameplayVoices[name];if(player.isPlaying)[_pausedGameplayVoices addObject:name];[player pause];}
    }
}
- (BOOL)resumeAfterSystemPage {
    @synchronized(self) {
        _suspendedForSystemPage=NO;
        BOOL sessionReady=[self ensureAudioSession];
        if(_resumeTitleAfterSystem){
            if(sessionReady&&([_music play]||([_music prepareToPlay]&&[_music play])))_pausedTitleMusic=NO;
            else _pausedTitleMusic=YES;
        }
        _resumeTitleAfterSystem=NO;
        if(_resumeExtraAfterSystem){
            AVAudioPlayer *target=_extraMusic?:_music;
            if(sessionReady&&([target play]||([target prepareToPlay]&&[target play])))_pausedExtraMusic=NO;
            else _pausedExtraMusic=YES;
        }
        _resumeExtraAfterSystem=NO;
        if(_resumeGameplayMusicAfterSystem&&_gameplayMusic){
            _gameplayMusic.volume=_musicVolume;
            if(sessionReady&&([_gameplayMusic play]||([_gameplayMusic prepareToPlay]&&[_gameplayMusic play])))_pausedGameplayMusic=NO;
            else _pausedGameplayMusic=YES;
        }
        _resumeGameplayMusicAfterSystem=NO;
        [self resumeGameplayEffects];
        return YES;
    }
}
- (void)dealloc { [_music stop];[_extraMusic stop];[_gameplayMusic stop];[_selection stop];for(AVAudioPlayer *player in _gameplayEffects.allValues)[player stop];for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop]; }
@end
