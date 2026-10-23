/* Exercise the actual Apple file adapter using only an original test fixture. */
#import <Foundation/Foundation.h>
#import "DCArchive.h"
#include <stdio.h>
#include <string.h>

#define REQUIRE(condition) do { if (!(condition)) { \
    fprintf(stderr, "Archive adapter check failed at line %d\n", __LINE__); return 1; \
} } while (0)

int main(void) {
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error = nil;
        REQUIRE([[NSFileManager defaultManager] createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:&error]);
        NSURL *file = [directory URLByAppendingPathComponent:@"synthetic.pp"];
        uint8_t fixture[47] = {1, 0, 0, 0, 3, 0, 0, 0};
        const char *name = "sample.bin";
        for (size_t i = 0; i < strlen(name); ++i) fixture[8 + i] = (uint8_t)(0u - (uint8_t)name[i]);
        fixture[40] = 3;
        fixture[44] = (uint8_t)-'a'; fixture[45] = (uint8_t)-'b'; fixture[46] = (uint8_t)-'c';
        REQUIRE([[NSData dataWithBytes:fixture length:sizeof(fixture)] writeToURL:file options:0 error:&error]);
        DCArchive *archive = [[DCArchive alloc] initWithURL:file error:&error];
        REQUIRE(archive && !error && archive.entryCount == 1);
        REQUIRE([[archive asciiNameAtIndex:0] isEqualToString:@"sample.bin"]);
        NSData *expected = [@"abc" dataUsingEncoding:NSASCIIStringEncoding];
        REQUIRE([[archive readEntryAtIndex:0 limit:3 error:&error] isEqualToData:expected]);
        REQUIRE([[archive readPrefixAtIndex:0 length:2 error:&error]
            isEqualToData:[@"ab" dataUsingEncoding:NSASCIIStringEncoding]]);
        REQUIRE([[archive readPrefixAtIndex:0 length:100 error:&error] isEqualToData:expected]);
        REQUIRE([archive readPrefixAtIndex:0 length:0 error:&error].length == 0);
        REQUIRE([archive readEntryAtIndex:0 limit:2 error:&error] == nil && error.code == 4);
        error = nil;
        REQUIRE([archive readEntryAtIndex:1 limit:10 error:&error] == nil && error.code == 4);
        archive = nil;
        // A truncated backing file must produce IO failure rather than zero-filled success.
        REQUIRE([[NSData dataWithBytes:fixture length:sizeof(fixture)] writeToURL:file options:0 error:&error]);
        error = nil;
        archive = [[DCArchive alloc] initWithURL:file error:&error];
        REQUIRE(archive != nil);
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:&error];
        REQUIRE(handle != nil);
        [handle truncateFileAtOffset:44];
        [handle closeFile];
        REQUIRE([archive readEntryAtIndex:0 limit:3 error:&error] == nil && error.code == 2);
        archive = nil;
        error = nil;
        REQUIRE([[DCArchive alloc] initWithURL:file error:&error] == nil && error.code == 3);
        error = nil;
        REQUIRE([[DCArchive alloc] initWithURL:directory error:&error] == nil && error.code == 2);
        REQUIRE([[NSFileManager defaultManager] removeItemAtURL:directory error:&error]);
        puts("PORTLAB_APPLE_ARCHIVE_ADAPTER_OK");
    }
    return 0;
}
