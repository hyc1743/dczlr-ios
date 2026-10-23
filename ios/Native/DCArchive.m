#import "DCArchive.h"
#include "dc_pp.h"
#include <stdio.h>
#include <sys/stat.h>

static int read_at(void *context, uint64_t offset, void *out, size_t length) {
    FILE *file = context;
    if (offset > INT64_MAX || fseeko(file, (off_t)offset, SEEK_SET)) return 0;
    return fread(out, 1, length, file) == length;
}

static void report_error(NSError **error, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"PortLab.NativeArchive" code:code
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Archive operation failed (%ld)", (long)code]}];
}

@implementation DCArchive {
    FILE *_file;
    dc_pp *_archive;
}
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (!url.isFileURL) { report_error(error, DC_ARGUMENT); return nil; }
    _file = fopen(url.fileSystemRepresentation, "rb");
    struct stat info;
    if (!_file || fstat(fileno(_file), &info) || !S_ISREG(info.st_mode) || info.st_size < 0) {
        report_error(error, DC_IO); return nil;
    }
    dc_source source = {_file, (uint64_t)info.st_size, read_at};
    dc_status status = dc_pp_open(&source, &_archive);
    if (status != DC_OK) { report_error(error, status); return nil; }
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
    if (status != DC_OK) { report_error(error, status); return nil; }
    if (entry.size > limit) { report_error(error, DC_RANGE); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:entry.size];
    status = dc_pp_read(_archive, index, 0, data.mutableBytes, entry.size);
    if (status != DC_OK) { report_error(error, status); return nil; }
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
@end
