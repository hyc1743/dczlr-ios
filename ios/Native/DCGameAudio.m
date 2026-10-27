#import "DCGameAudio.h"
#import "DCArchive.h"
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
#include "dc_scene_ui.h"

@interface DCGameAudio () <AVAudioPlayerDelegate>
@end

static NSString *DCGameplaySlotName(NSUInteger slot) {
    if(slot>=35)return nil;
    char name[16];
    return dc_scene_effect_name((uint32_t)slot,name,sizeof(name))==DC_OK?[NSString stringWithUTF8String:name]:nil;
}

@implementation DCGameAudio {
    AVAudioPlayer *_music,*_selection;
    NSMutableDictionary<NSString *,AVAudioPlayer *> *_gameplayEffects,*_gameplayVoices;
    NSMutableSet<NSString *> *_pausedGameplayEffects;
    NSString *_directory;
    NSString *_voiceChainNext;
    BOOL _advanced;
}
- (NSData *)sound:(NSString *)name inArchive:(NSString *)file directory:(NSString *)directory error:(NSString **)error {
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file]] error:&reason];
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
    if(!_gameplayEffects)_gameplayEffects=[NSMutableDictionary dictionary];
    return nil;
}
- (BOOL)playGameplayEffectNamed:(NSString *)name {
    if(!_gameplayEffects)_gameplayEffects=[NSMutableDictionary dictionary];
    AVAudioPlayer *player=_gameplayEffects[name];
    if(!player) {
        NSString *error=nil;NSData *data=[self sound:name inArchive:@"RPP_14.pp" directory:_directory error:&error];
        if(!data)return NO;
        NSError *reason=nil;player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
        if(!player || ![player prepareToPlay])return NO;
        _gameplayEffects[name]=player;
    }
    NSError *reason=nil;AVAudioSession *session=AVAudioSession.sharedInstance;
    if(![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&reason] ||
       ![session setActive:YES error:&reason]) return NO;
    player.currentTime=0;return [player play];
}
- (BOOL)playGameplaySlot:(NSUInteger)slot {
    NSString *name=DCGameplaySlotName(slot);
    return name && [self playGameplayEffectNamed:name];
}
- (BOOL)gameplaySlotBusy:(NSUInteger)slot {
    NSString *name=DCGameplaySlotName(slot);
    return name && _gameplayEffects[name].isPlaying;
}
- (BOOL)resumeGameplayEffects {
    if(!_pausedGameplayEffects.count)return YES;
    NSError *error=nil;
    if(![AVAudioSession.sharedInstance setActive:YES error:&error])return NO;
    for(NSString *name in _pausedGameplayEffects)if(![_gameplayEffects[name] play])return NO;
    [_pausedGameplayEffects removeAllObjects];return YES;
}
- (BOOL)playGameplayVoiceNamed:(NSString *)name {
    if (!name.length) return NO;
    AVAudioPlayer *player=_gameplayVoices[name];
    if (!player) {
        NSString *error=nil;NSData *data=[self sound:name inArchive:@"RPP_11.pp" directory:_directory error:&error];
        if (!data) return NO;
        NSError *reason=nil;player=[[AVAudioPlayer alloc] initWithData:data error:&reason];
        if (!player || ![player prepareToPlay]) return NO;
        if (!_gameplayVoices) _gameplayVoices=[NSMutableDictionary dictionary];
        _gameplayVoices[name]=player;
    }
    player.delegate=self;
    _voiceChainNext=[name caseInsensitiveCompare:@"ast001_01.wav"]==NSOrderedSame ? @"ast002_01.wav" : nil;
    NSError *reason=nil;AVAudioSession *session=AVAudioSession.sharedInstance;
    if(![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&reason] ||
       ![session setActive:YES error:&reason]) return NO;
    player.currentTime=0;
    return [player play];
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (!flag || player.delegate!=self) return;
    NSString *next=_voiceChainNext;_voiceChainNext=nil;
    if (next) [self playGameplayVoiceNamed:next];
}
- (NSString *)startTitleMusic {
    if (_music.isPlaying) return nil;
    NSError *reason=nil;
    AVAudioSession *session=AVAudioSession.sharedInstance;
    if(![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&reason] ||
       ![session setActive:YES error:&reason]) return reason.localizedDescription;
    if(![_music play]) return @"Title music did not start";
    return nil;
}
- (BOOL)musicAdvanced {
    if(_music.isPlaying && _music.currentTime>.1)_advanced=YES;
    return _advanced;
}
- (BOOL)playMenuSelection {
    _selection.currentTime=0;
    return [_selection play];
}
- (BOOL)selectionBusy { return _selection.isPlaying; }
- (BOOL)gameplayVoiceBusy {
    for (AVAudioPlayer *player in _gameplayVoices.allValues) if (player.isPlaying) return YES;
    return NO;
}
- (void)stopTitleMusic { [_music stop]; }
- (void)cancelGameplayVoice {
    _voiceChainNext=nil;
    for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
}
- (void)pause {
    _voiceChainNext=nil;[_music pause];[_selection stop];
    if(!_pausedGameplayEffects)_pausedGameplayEffects=[NSMutableSet set];
    for(NSString *name in _gameplayEffects) {
        AVAudioPlayer *player=_gameplayEffects[name];
        if(player.isPlaying)[_pausedGameplayEffects addObject:name];
        [player pause];
    }
    for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop];
}
- (void)dealloc { [_music stop];[_selection stop];for(AVAudioPlayer *player in _gameplayEffects.allValues)[player stop];for(AVAudioPlayer *player in _gameplayVoices.allValues)[player stop]; }
@end
