#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* Archive-backed Apple audio adapter. Startup/title identifiers are taken
 * from the original setup; playback behavior is native AVFoundation. */
@interface DCGameAudio : NSObject
@property(nonatomic,readonly) BOOL musicAdvanced;
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSString **)error;
- (nullable NSString *)startTitleMusic;
- (BOOL)playMenuSelection;
- (void)pause;
@end
NS_ASSUME_NONNULL_END
