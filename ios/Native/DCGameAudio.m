#import "DCGameAudio.h"
#import "DCArchive.h"
#import <AVFoundation/AVFoundation.h>

@implementation DCGameAudio {
    AVAudioPlayer *_music,*_selection;
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
- (void)pause { [_music pause];[_selection stop]; }
- (void)dealloc { [_music stop];[_selection stop]; }
@end
