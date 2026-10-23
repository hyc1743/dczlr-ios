#include "dc_script.h"
#include <string.h>

static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
static int line(const uint8_t *p,size_t length,size_t at,dc_script_span *span,size_t *next) {
    size_t start=at;
    while(at<length && p[at]!='\n' && p[at]!='\r')++at;
    if(at==length)return 0;
    *span=(dc_script_span){start,at-start};
    if(p[at]=='\r') {
        if(at+1==length || p[at+1]!='\n')return 0;
        ++at;
    }
    *next=at+1;return 1;
}
dc_status dc_script_find(const void *bytes,size_t length,size_t cursor,uint32_t frame,dc_script_record *out) {
    if(!bytes || !out || overlap(bytes,length,out,sizeof(*out))) return DC_ARGUMENT;
    if(length>DC_SCRIPT_BYTE_LIMIT || cursor>length || frame>9999)return DC_RANGE;
    const uint8_t *p=bytes;
    if(memchr(p,0,length))return DC_FORMAT;
    uint8_t marker[6]={'#','T',(uint8_t)('0'+frame/1000),(uint8_t)('0'+frame/100%10),
        (uint8_t)('0'+frame/10%10),(uint8_t)('0'+frame%10)};
    size_t at=cursor;
    while(length-at>=6 && memcmp(p+at,marker,6))++at;
    if(length-at<6)return DC_NOT_FOUND;
    dc_script_record record={.marker_offset=at,.frame=frame};
    at+=6;
    if(!line(p,length,at,&record.header,&at) || !line(p,length,at,&record.speaker,&at))return DC_FORMAT;
    if(record.speaker.length>32)return DC_RANGE;
    record.body.offset=at;
    while(length-at>=4 && memcmp(p+at,"$END",4))++at;
    if(length-at<4)return DC_FORMAT;
    record.body.length=at-record.body.offset;record.next_offset=at+4;
    *out=record;return DC_OK;
}
