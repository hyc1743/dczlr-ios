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

#define DC_INTRO_CHAPTERS 29u
typedef struct dc_intro_descriptor { int32_t script,last_frame; } dc_intro_descriptor;
typedef struct dc_intro_state { uint32_t chapter,action,waiting,progress; } dc_intro_state;
enum dc_intro_operation {
    DC_INTRO_RESET_TEXT=1,DC_INTRO_TRANSITION=2,DC_INTRO_LOAD_SCRIPT=3,
    DC_INTRO_CLEAR_FINISH=4,DC_INTRO_CLEANUP=5,DC_INTRO_ENTER_CHAPTER=6,
    DC_INTRO_BACKUP=7,DC_INTRO_ENTER_AUX=8,DC_INTRO_STOP_AUDIO=9,
    DC_INTRO_QUIT=10,DC_INTRO_UNLOCK_PROGRESS=11
};
typedef struct dc_intro_command { uint32_t kind,value; } dc_intro_command;
typedef struct dc_intro_plan {
    dc_intro_state next;
    uint32_t count,departed;
    dc_intro_command commands[6];
} dc_intro_plan;
/* End-of-script branch of 0x606440. LOAD_SCRIPT value is chapter index; host
 * resolves its descriptor and resets the text controller. Transition cases
 * continue through 0x52bcf0 below. finish is admitted only while not waiting. */
DC_API dc_status dc_intro_finish(const dc_intro_state *state,
    const dc_intro_descriptor *table,size_t count,dc_intro_plan *out);
/* Original pending-action helper. BACKUP value1 is the root callback bank,
 * value2 is the temporary-screen bank. ENTER_AUX values:2 configuration,
 * 5 dummy/boss screen,6 title,7 save/load. STOP_AUDIO order is
 * 2 music,0 voice,1 effects. ENTER_CHAPTER installs callback/selector/stage
 * from the host's chapter table and clears active callbacks. Progress refers
 * to context+0x1355b; chapter 24 promotes all three corresponding flags from
 * zero to one. CLEAR_FINISH clears separate context bytes +0x21f70..72.
 * Only departed replaces the update callback. Host operations execute in
 * order before committing next; failures require scene recovery. */
DC_API dc_status dc_intro_transition(const dc_intro_state *state,
    const dc_intro_descriptor *table,size_t count,uint32_t ready,dc_intro_plan *out);
#ifdef __cplusplus
}
#endif
#endif
