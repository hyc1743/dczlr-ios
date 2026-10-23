#ifndef DC_TEXT_H
#define DC_TEXT_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_TEXT_GLYPH_LIMIT 200u
#define DC_TEXT_LINE_LIMIT 5u
#define DC_TEXT_BYTE_LIMIT 400u
/* Normal (non-texture/backlog) branch of the original text controller.
 * Byte-pair cells deliberately preserve the original DBCS byte layout;
 * glyph rasterization and font choice belong to the host adapter. */
typedef struct dc_text_state {
    uint32_t columns,max_lines,visible_lines,body_bytes;
    int32_t current_line,wait_state,wait_glyph,frame,last_frame;
    uint32_t last_fade_row,wait_line,wait_duration,wait_stamp,fade_index,active;
    int32_t x,y,font_size;
    float scale;
    uint32_t rgb,alpha[DC_TEXT_GLYPH_LIMIT],line_lengths[DC_TEXT_LINE_LIMIT];
} dc_text_state;
typedef struct dc_text_glyph {
    int32_t x,y;
    uint32_t color;
    uint8_t bytes[2],reserved[2];
} dc_text_glyph;
typedef struct dc_text_plan {
    dc_text_state next;
    uint32_t count;
    dc_text_glyph glyphs[DC_TEXT_GLYPH_LIMIT];
} dc_text_plan;
typedef struct dc_text_advance_plan {
    dc_text_state next;
    uint32_t load_record,finished;
} dc_text_advance_plan;
/* 0x58eb30 normal branch. The original draws with current alpha, then adds
 * delta*10 to at most one cell using wrapping signed-32-bit comparisons.
 * clock is the raw external clock value used by original wait-stamp logic.
 * Input bytes have implicit zero padding beyond length, as in its cleared
 * text buffer. Only LF/CRLF byte handling is performed, not Unicode parsing.
 * fast_lines corresponds to original global flag bit 0. Output is atomic;
 * output may alias state, but cannot overlap body bytes. */
DC_API dc_status dc_text_build_plan(const dc_text_state *state,const void *body,
    size_t length,int32_t delta,uint32_t clock,uint32_t fast_lines,dc_text_plan *out);
/* 0x591310, forward input 0, normal non-backlog branch. A first call with
 * current_line=-1,frame=-1 starts the preloaded record 0. An incomplete record
 * is revealed before advancing. On load_record, the host parses next.frame,
 * installs body_bytes/visible_lines=1 and commits the returned state. finished
 * clears active; chapter dispatch is a separate host action. */
DC_API dc_status dc_text_advance(const dc_text_state *state,uint32_t fast_lines,
    dc_text_advance_plan *out);
#ifdef __cplusplus
}
#endif
#endif
