#include "dc_text.h"
#include <math.h>
#include <string.h>

static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
static int32_t signed_bits(uint32_t bits) {
    return bits<=INT32_MAX ? (int32_t)bits : (int32_t)((int64_t)bits-INT64_C(4294967296));
}
static dc_status valid(const dc_text_state *s) {
    if (!s) return DC_ARGUMENT;
    if (!s->columns || s->columns>39 || !s->max_lines || s->max_lines>5 ||
        !s->visible_lines || s->visible_lines>5 || s->body_bytes>DC_TEXT_BYTE_LIMIT ||
        s->current_line < -1 || s->current_line>127 || s->frame < -1 || s->frame>9999 ||
        s->last_frame<0 || s->last_frame>9999 || s->last_fade_row>255 || s->wait_line>255 ||
        s->fade_index>DC_TEXT_GLYPH_LIMIT || s->active!=1 || s->wait_duration>INT32_MAX ||
        s->wait_glyph < -1 || s->wait_glyph>=(int32_t)DC_TEXT_GLYPH_LIMIT ||
        (s->wait_state==1 && s->wait_glyph<0) || s->x < -100000 || s->x>100000 ||
        s->y < -100000 || s->y>100000 || s->font_size<1 || s->font_size>256 ||
        !isfinite(s->scale) || s->scale<=0 || s->scale>64 || s->rgb>0xffffff) return DC_RANGE;
    return DC_OK;
}
static uint8_t byte_at(const uint8_t *body,size_t length,size_t at) {
    return at<length ? body[at] : 0;
}
static void glyph(dc_text_plan *p,const uint8_t scratch[260],uint32_t j,uint32_t row) {
    dc_text_state *s=&p->next;
    dc_text_glyph *g=&p->glyphs[p->count];
    int32_t column=(int32_t)(j/2)-1;
    g->x=s->x+(s->font_size-(int32_t)s->scale)*column;
    g->y=s->y+(s->font_size+(int32_t)(2.0*s->scale))*(int32_t)row;
    g->color=((s->alpha[p->count]&255)<<24)|s->rgb;
    g->bytes[0]=scratch[j-2];g->bytes[1]=scratch[j-1];
    ++p->count;
}
dc_status dc_text_build_plan(const dc_text_state *state,const void *body,size_t length,
        int32_t delta,uint32_t clock,uint32_t fast_lines,dc_text_plan *out) {
    if (!out || (length && !body) || overlap(body,length,out,sizeof(*out))) return DC_ARGUMENT;
    dc_status status=valid(state);if (status!=DC_OK) return status;
    if (length!=state->body_bytes || fast_lines>1) return DC_RANGE;
    dc_text_plan p={0};p.next=*state;dc_text_state *s=&p.next;
    if (s->wait_state==1) {
        if ((int32_t)((double)(uint32_t)(clock-s->wait_stamp)*.001)>=(int32_t)s->wait_duration &&
            s->alpha[s->wait_glyph]==255) s->wait_state=s->current_line>(int32_t)s->max_lines ? -2 : -1;
        else if (s->alpha[s->wait_glyph]!=255) s->wait_stamp=clock;
    }
    size_t at=0;
    if (s->current_line+1<6) {
        for (uint32_t row=0;(int32_t)row<s->current_line+1;++row) {
            uint8_t scratch[260]={0};uint32_t j;
            for (j=0;j<s->columns*2;++j) {
                if (j && !(j&1)) { glyph(&p,scratch,j,row);memset(scratch,0,sizeof(scratch)); }
                scratch[j]=byte_at(body,length,at++);
                if (byte_at(body,length,at)=='\n') {
                    if (s->wait_state==-1 && s->wait_glyph<(int32_t)p.count && fast_lines) {
                        s->wait_state=1;s->wait_line=row;s->wait_glyph=(int32_t)p.count;s->wait_stamp=clock;
                    }
                    s->line_lengths[row]=j/2+1;++at;break;
                }
            }
            if ((s->current_line+1<(int32_t)s->visible_lines || s->columns<s->body_bytes ||
                 (s->current_line<=(int32_t)s->visible_lines && s->visible_lines==1)) &&
                s->current_line+1<(int32_t)s->max_lines && s->wait_state!=1) ++s->current_line;
            if (j>=2) glyph(&p,scratch,j,row);
            if (s->wait_state==1 && s->wait_glyph<(int32_t)p.count) break;
        }
    }
    if (!p.count) s->fade_index=0;
    if (s->current_line>=0 && s->fade_index<=s->body_bytes/2 && s->fade_index<p.count) {
        uint32_t i=s->fade_index;
        s->alpha[i]+=(uint32_t)delta*10u;
        if (signed_bits(s->alpha[i])>=255) {s->alpha[i]=255;++s->fade_index;}
    }
    *out=p;return DC_OK;
}
dc_status dc_text_advance(const dc_text_state *state,uint32_t fast_lines,dc_text_advance_plan *out) {
    if (!out) return DC_ARGUMENT;
    dc_status status=valid(state);if (status!=DC_OK) return status;
    if (fast_lines>1 || state->body_bytes<2 || state->body_bytes>=DC_TEXT_BYTE_LIMIT) return DC_RANGE;
    dc_text_advance_plan p={0};p.next=*state;dc_text_state *s=&p.next;
    uint32_t end=s->body_bytes/2;
    if (s->last_frame<=s->frame && (s->alpha[end-1]==255 || fast_lines)) s->last_fade_row=s->max_lines-1;
    if (s->frame<s->last_frame || s->last_fade_row!=s->max_lines-1) {
        if (s->alpha[end]==255 || fast_lines || s->current_line<0) {
            s->fade_index=0;++s->current_line;++s->frame;
        } else {
            for (uint32_t i=s->fade_index;i<end;++i) s->alpha[i]=255;
            s->fade_index=end;s->wait_state=-2;
            if (s->visible_lines==s->max_lines) s->current_line=(int32_t)s->max_lines;
        }
        if ((int32_t)s->visible_lines<s->current_line &&
            (s->alpha[end]==255 || s->current_line<1 || fast_lines || s->last_fade_row>=s->max_lines-1)) {
            s->current_line=0;s->body_bytes=0;s->wait_state=-1;s->wait_line=255;s->wait_glyph=-1;
            if (s->visible_lines==s->max_lines) ++s->frame;
            memset(s->alpha,0,sizeof(s->alpha));s->fade_index=0;p.load_record=1;
        }
    } else {
        s->current_line=-1;s->active=0;p.finished=1;
    }
    *out=p;return DC_OK;
}
