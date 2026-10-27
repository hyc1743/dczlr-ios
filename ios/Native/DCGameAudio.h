#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Archive-backed Apple audio adapter. Startup/title identifiers and the
 * chapter-3 RPP14 slot table are taken from the original setup; playback is
 * native AVFoundation. */
@interface DCGameAudio : NSObject
@property(nonatomic,readonly) BOOL musicAdvanced;
@property(nonatomic,readonly) BOOL selectionBusy;
- (BOOL)gameplayVoiceBusy;
- (void)cancelGameplayVoice;
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error;
- (nullable NSString *)startTitleMusic;
- (nullable NSString *)prepareGameplayAudio;
- (BOOL)playGameplayEffectNamed:(NSString *)name;
- (BOOL)playGameplaySlot:(NSUInteger)slot;
- (BOOL)gameplaySlotBusy:(NSUInteger)slot;
- (BOOL)resumeGameplayEffects;
- (BOOL)playGameplayVoiceNamed:(NSString *)name;
- (BOOL)playMenuSelection;
- (void)pause;
- (void)stopTitleMusic;
@end
NS_ASSUME_NONNULL_END
