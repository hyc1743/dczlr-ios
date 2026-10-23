#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Tightly packed top-left RGBA8 with straight alpha, ready for texture upload. */
@interface DCDecodedImage : NSObject
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) NSData *rgba;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* Serial read-only adapter over the reconstructed portable archive module. */
@interface DCArchive : NSObject
@property(nonatomic, readonly) uint32_t entryCount;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(init(url:));
- (nullable NSString *)asciiNameAtIndex:(uint32_t)index NS_SWIFT_NAME(asciiName(at:));
- (nullable NSData *)readEntryAtIndex:(uint32_t)index
                               limit:(NSUInteger)limit
                               error:(NSError **)error NS_SWIFT_NAME(readEntry(at:limit:));
- (nullable NSData *)readPrefixAtIndex:(uint32_t)index
                               length:(NSUInteger)length
                                error:(NSError **)error NS_SWIFT_NAME(readPrefix(at:length:));
/* Both caps are mandatory; format is selected from the original entry name. */
- (nullable DCDecodedImage *)decodeImageAtIndex:(uint32_t)index
                                    inputLimit:(NSUInteger)inputLimit
                                   outputLimit:(NSUInteger)outputLimit
                                         error:(NSError **)error
    NS_SWIFT_NAME(decodeImage(at:inputLimit:outputLimit:));
@end
NS_ASSUME_NONNULL_END
