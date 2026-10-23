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

#define DC_SCRIPT_CONTROL_LIMIT 11u
typedef struct dc_script_control {
    uint8_t key[16]; /* NUL terminated, nonempty; matched in caller order. */
    uint32_t parameter_bytes; /* 1..35; original fixed-size header copy. */
} dc_script_control;
typedef struct dc_script_decoded {
    dc_script_record record;
    uint8_t background[20],music[20],sound[20],message[20];
    uint8_t controls[DC_SCRIPT_CONTROL_LIMIT][37];
} dc_script_decoded;
/* Normal sequential branch of original 0x592590: scans pre-record #cg,
 * #MS, #bg (three-byte comparison), #SE in their original per-iteration
 * order, accumulating names after '#'. Header controls copy fixed bytes
 * plus an optional A/B/C suffix. Command names have 19-byte capacity;
 * configured control results have 36-byte capacity plus NUL. Malformed or
 * overflowing input fails atomically. %C actor commands are not admitted.
 * Encoded text stays opaque. Playback/backlog branches and glyph/body
 * interpretation remain outside this API. Input/output cannot overlap. */
DC_API dc_status dc_script_decode(const void *bytes,size_t length,size_t cursor,
    uint32_t frame,const dc_script_control *controls,size_t count,dc_script_decoded *out);
#ifdef __cplusplus
}
#endif
#endif
