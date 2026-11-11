#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Archive-backed Apple audio adapter. Startup/title identifiers and the
 * chapter-3 RPP14 slot table are taken from the original setup; playback is
 * native AVFoundation. */
@interface DCGameAudio : NSObject
@property(nonatomic,readonly) BOOL musicAdvanced;
@property(nonatomic,readonly) BOOL selectionBusy;
- (BOOL)gameplayVoiceBusy;
- (float)gameplayVoiceMouthPhase;
- (void)cancelGameplayVoice;
- (void)stopActiveGameplayEffectsAndVoice;
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error;
- (nullable NSString *)startTitleMusic;
- (nullable NSString *)startExtraMusic;
- (nullable NSString *)startGameplayMusicForSceneType:(uint32_t)sceneType map:(uint32_t)mapSelector;
- (nullable NSString *)prepareGameplayAudio;
- (BOOL)playGameplayEffectNamed:(NSString *)name;
- (BOOL)playGameplaySlot:(NSUInteger)slot;
- (void)setGameplayLoopSlot:(NSUInteger)slot active:(BOOL)active;
- (BOOL)gameplaySlotBusy:(NSUInteger)slot;
- (BOOL)resumeGameplayEffects;
- (BOOL)playGameplayVoiceNamed:(NSString *)name;
- (BOOL)playMenuSelection;
- (void)pause;
- (void)suspendForSystemPage;
- (BOOL)resumeAfterSystemPage;
- (void)applyConfiguration:(NSData *)configuration;
- (void)stopTitleMusic;
- (void)stopExtraMusic;
- (void)stopGameplayAudio;
@end
NS_ASSUME_NONNULL_END
