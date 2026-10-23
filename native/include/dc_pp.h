/* Original PortLab implementation of the observed indexed PP container. */
#ifndef DC_PP_H
#define DC_PP_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(DC_NATIVE_SHARED)
#define DC_API __declspec(dllexport)
#else
#define DC_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum dc_status {
    DC_OK = 0,
    DC_ARGUMENT = 1,
    DC_IO = 2,
    DC_FORMAT = 3,
    DC_RANGE = 4,
    DC_MEMORY = 5,
    DC_NOT_FOUND = 6
} dc_status;

/* Return 1 only when exactly length bytes were read. The caller owns context
 * and must keep the source alive until the archive is closed. */
typedef int (*dc_read_at_fn)(void *context, uint64_t offset, void *out, size_t length);
typedef struct dc_source {
    void *context;
    uint64_t length;
    dc_read_at_fn read_at;
} dc_source;

typedef struct dc_pp dc_pp;
typedef struct dc_pp_entry {
    uint8_t name[32]; /* Original name bytes; not converted to UTF-8. */
    uint64_t offset;
    uint32_t size;
    uint32_t name_length;
} dc_pp_entry;

/* Strict observed profile: 8-byte header, count*32 names, count*4 sizes,
 * followed by exactly the declared payload. Unknown profiles are rejected. */
DC_API dc_status dc_pp_open(const dc_source *source, dc_pp **out);
DC_API void dc_pp_close(dc_pp *archive);
DC_API uint32_t dc_pp_count(const dc_pp *archive);
DC_API dc_status dc_pp_entry_at(const dc_pp *archive, uint32_t index, dc_pp_entry *out);
DC_API dc_status dc_pp_find_exact(const dc_pp *archive, const void *name, size_t length, uint32_t *index);
/* Original 0x00423250 scans until the first dot, remembers backslashes and
 * skips two bytes for bytes >= 0x80. This bounded equivalent rejects missing
 * dots and incomplete multibyte prefixes instead of reading past the input. */
DC_API dc_status dc_pp_basename_offset(const void *name, size_t length, size_t *offset);
/* Matches the observed archive loader for ASCII paths, preserving first-match
 * ordering. High-byte comparisons require a separately verified locale rule. */
DC_API dc_status dc_pp_find_ascii_path(const dc_pp *archive, const void *name, size_t length, uint32_t *index);
DC_API dc_status dc_pp_read(const dc_pp *archive, uint32_t index, uint64_t offset, void *out, size_t length);
DC_API dc_status dc_pp_decode_bytes(void *bytes, size_t length);

#ifdef __cplusplus
}
#endif
#endif
