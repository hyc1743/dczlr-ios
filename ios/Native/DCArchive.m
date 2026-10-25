#import "DCArchive.h"
#include "dc_pp.h"
#include "dc_image.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

static int read_at(void *context, uint64_t offset, void *out, size_t length) {
    FILE *file = context;
    if (offset > INT64_MAX || length > (uint64_t)INT64_MAX - offset) return 0;
    size_t done = 0;
    while (done < length) {
        size_t count = MIN(length - done, (size_t)SSIZE_MAX);
        ssize_t got = pread(fileno(file), (uint8_t *)out + done, count, (off_t)(offset + done));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return 0;
        done += (size_t)got;
    }
    return 1;
}

static void report_error(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"PortLab.NativeArchive" code:code
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Archive operation failed (%ld)", (long)code]}];
}
static void report_context_error(NSError **error, NSInteger code, NSString *context) {
    if (error) *error = [NSError errorWithDomain:@"PortLab.NativeArchive" code:code
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Archive operation failed (%ld): %@", (long)code, context]}];
}

@interface DCDecodedImage ()
- (instancetype)initWithInfo:(dc_image_info)info pixels:(void *)pixels;
@end

@implementation DCDecodedImage
- (instancetype)initWithInfo:(dc_image_info)info pixels:(void *)pixels {
    self = [super init];
    if (self) {
        _width = info.width;
        _height = info.height;
        _rgba = [NSData dataWithBytesNoCopy:pixels length:info.rgba_bytes freeWhenDone:YES];
    } else {
        free(pixels);
    }
    return self;
}
@end

@implementation DCArchive {
    FILE *_file;
    dc_pp *_archive;
    NSString *_path;
}
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (!url.isFileURL) { report_error(error, DC_ARGUMENT); return nil; }
    _path = [url.path copy];
    _file = fopen(url.fileSystemRepresentation, "rb");
    struct stat info;
    if (!_file || fstat(fileno(_file), &info) || !S_ISREG(info.st_mode) || info.st_size < 0) {
        report_context_error(error, DC_IO, [NSString stringWithFormat:@"open %@", _path]); return nil;
    }
    dc_source source = {_file, (uint64_t)info.st_size, read_at};
    dc_status status = dc_pp_open(&source, &_archive);
    if (status != DC_OK) { report_context_error(error, status, [NSString stringWithFormat:@"open %@", _path]); return nil; }
    return self;
}
- (void)dealloc {
    dc_pp_close(_archive);
    if (_file) fclose(_file);
}
- (uint32_t)entryCount { return dc_pp_count(_archive); }
- (NSString *)asciiNameAtIndex:(uint32_t)index {
    dc_pp_entry entry;
    if (dc_pp_entry_at(_archive, index, &entry) != DC_OK) return nil;
    return [[NSString alloc] initWithBytes:entry.name length:entry.name_length encoding:NSASCIIStringEncoding];
}
- (NSData *)readEntryAtIndex:(uint32_t)index limit:(NSUInteger)limit error:(NSError **)error {
    dc_pp_entry entry;
    dc_status status = dc_pp_entry_at(_archive, index, &entry);
    if (status != DC_OK) { report_context_error(error, status, [NSString stringWithFormat:@"%@ entry=%u metadata", _path, index]); return nil; }
    if (entry.size > limit) { report_error(error, DC_RANGE); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:entry.size];
    status = dc_pp_read(_archive, index, 0, data.mutableBytes, entry.size);
    if (status != DC_OK) { report_context_error(error, status, [NSString stringWithFormat:@"%@ entry=%u read size=%llu", _path, index, (unsigned long long)entry.size]); return nil; }
    return data;
}
- (NSData *)readPrefixAtIndex:(uint32_t)index length:(NSUInteger)length error:(NSError **)error {
    dc_pp_entry entry;
    dc_status status = dc_pp_entry_at(_archive, index, &entry);
    if (status != DC_OK) { report_error(error, status); return nil; }
    NSUInteger count = MIN(length, (NSUInteger)entry.size);
    NSMutableData *data = [NSMutableData dataWithLength:count];
    status = dc_pp_read(_archive, index, 0, data.mutableBytes, count);
    if (status != DC_OK) { report_error(error, status); return nil; }
    return data;
}
- (DCDecodedImage *)decodeImageAtIndex:(uint32_t)index inputLimit:(NSUInteger)inputLimit
                           outputLimit:(NSUInteger)outputLimit error:(NSError **)error {
    dc_pp_entry entry;
    dc_status status = dc_pp_entry_at(_archive, index, &entry);
    if (status != DC_OK) { report_error(error, status); return nil; }
    NSString *name = [self asciiNameAtIndex:index];
    NSString *extension = name.pathExtension.lowercaseString;
    dc_image_format format;
    if ([extension isEqualToString:@"bmp"]) format = DC_IMAGE_BMP;
    else if ([extension isEqualToString:@"tga"]) format = DC_IMAGE_TGA;
    else if ([extension isEqualToString:@"ema"]) format = DC_IMAGE_EMA;
    else { report_error(error, DC_FORMAT); return nil; }
    NSData *source = [self readEntryAtIndex:index limit:inputLimit error:error];
    if (!source) return nil;
    dc_image_info info;
    status = dc_image_probe(source.bytes, source.length, format, &info);
    if (status != DC_OK) { report_error(error, status); return nil; }
    if (info.rgba_bytes > outputLimit) { report_error(error, DC_RANGE); return nil; }
    void *pixels = malloc(info.rgba_bytes);
    if (!pixels) { report_error(error, DC_MEMORY); return nil; }
    status = dc_image_decode(source.bytes, source.length, format, pixels, info.rgba_bytes, &info);
    if (status != DC_OK) { free(pixels); report_error(error, status); return nil; }
    return [[DCDecodedImage alloc] initWithInfo:info pixels:pixels];
}
@end
