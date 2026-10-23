#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Serial read-only adapter over the reconstructed portable archive module. */
@interface DCArchive : NSObject
@property(nonatomic, readonly) uint32_t entryCount;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(init(url:));
- (nullable NSString *)asciiNameAtIndex:(uint32_t)index;
- (nullable NSData *)readEntryAtIndex:(uint32_t)index
                               limit:(NSUInteger)limit
                               error:(NSError **)error NS_SWIFT_NAME(readEntry(at:limit:));
- (nullable NSData *)readPrefixAtIndex:(uint32_t)index
                               length:(NSUInteger)length
                                error:(NSError **)error NS_SWIFT_NAME(readPrefix(at:length:));
@end
NS_ASSUME_NONNULL_END
