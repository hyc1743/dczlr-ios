#ifndef DC_SCRIPT_H
#define DC_SCRIPT_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_SCRIPT_BYTE_LIMIT 1048576u
typedef struct dc_script_span { size_t offset,length; } dc_script_span;
typedef struct dc_script_record {
    dc_script_span header,speaker,body;
    size_t marker_offset,next_offset;
    uint32_t frame;
} dc_script_record;
/* Bounded numbered-record framing for #Tdddd ... newline, speaker newline,
 * then opaque bytes through the first $END delimiter. Searches from caller's
 * cursor and keeps first exact six-byte marker, including duplicate IDs later
 * in the same script. LF/CRLF, non-NUL bytes, speaker <=32 bytes admitted.
 * Header commands, text encoding/layout and body semantics remain opaque.
 * Records borrow immutable source spans. No allocation, original text export,
 * control-flow execution or rendering. Failure leaves output unchanged. */
DC_API dc_status dc_script_find(const void *bytes,size_t length,size_t cursor,
    uint32_t frame,dc_script_record *out);
#ifdef __cplusplus
}
#endif
#endif
