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

static int prefix(const uint8_t *p,size_t length,size_t at,const char *key,size_t n) {
    return at<=length && n<=length-at && !memcmp(p+at,key,n);
}

static dc_status command_line(const uint8_t *p,size_t length,size_t *at,uint8_t out[20]) {
    dc_script_span span;size_t next;
    if (!line(p,length,*at,&span,&next)) return DC_FORMAT;
    size_t old=0;while (old<20 && out[old]) ++old;
    size_t added=span.length-1; /* Include command identifier after '#'. */
    if (old>19 || added>19-old) return DC_RANGE;
    memcpy(out+old,p+span.offset+1,added);out[old+added]=0;*at=next;
    return DC_OK;
}

dc_status dc_script_decode(const void *bytes,size_t length,size_t cursor,uint32_t frame,
        const dc_script_control *controls,size_t count,dc_script_decoded *out) {
    if (!bytes || !out || (count && !controls) || overlap(bytes,length,out,sizeof(*out)) ||
        (count<=DC_SCRIPT_CONTROL_LIMIT && overlap(controls,count*sizeof(*controls),out,sizeof(*out)))) return DC_ARGUMENT;
    if (length>DC_SCRIPT_BYTE_LIMIT || cursor>length || frame>9999 || count>DC_SCRIPT_CONTROL_LIMIT) return DC_RANGE;
    size_t key_lengths[DC_SCRIPT_CONTROL_LIMIT]={0};
    for (size_t i=0;i<count;++i) {
        while (key_lengths[i]<16 && controls[i].key[key_lengths[i]]) ++key_lengths[i];
        if (!key_lengths[i] || key_lengths[i]==16 || !controls[i].parameter_bytes || controls[i].parameter_bytes>35) return DC_RANGE;
    }
    const uint8_t *p=bytes;
    if (memchr(p,0,length)) return DC_FORMAT;
    dc_script_decoded decoded={0};
    uint8_t marker[6]={'#','T',(uint8_t)('0'+frame/1000),(uint8_t)('0'+frame/100%10),
        (uint8_t)('0'+frame/10%10),(uint8_t)('0'+frame%10)};
    size_t at=cursor;dc_status status;
    for (;;) {
        if (prefix(p,length,at,"#cg",3)) {
            status=command_line(p,length,&at,decoded.background);if (status!=DC_OK) return status;
        }
        if (prefix(p,length,at,"#MS",3)) {
            status=command_line(p,length,&at,decoded.message);if (status!=DC_OK) return status;
        }
        if (prefix(p,length,at,"%C",2)) return DC_FORMAT;
        if (prefix(p,length,at,"#bg",3)) {
            status=command_line(p,length,&at,decoded.music);if (status!=DC_OK) return status;
        }
        if (prefix(p,length,at,"#SE",3)) {
            status=command_line(p,length,&at,decoded.sound);if (status!=DC_OK) return status;
        }
        if (at>length || length-at<6) return DC_NOT_FOUND;
        if (!memcmp(p+at,marker,6)) break;
        ++at;
    }
    status=dc_script_find(bytes,length,at,frame,&decoded.record);
    if (status!=DC_OK) return status;
    at=decoded.record.header.offset;
    size_t end=at+decoded.record.header.length;
    while (at<end) {
        size_t advanced=1;
        for (size_t i=0;i<count;++i) {
            size_t key=key_lengths[i],n=controls[i].parameter_bytes;
            if (key>end-at || memcmp(p+at,controls[i].key,key)) continue;
            if (n>end-at-key) return DC_FORMAT;
            memcpy(decoded.controls[i],p+at+key,n);
            size_t suffix=at+key+n;
            if (suffix<end && (p[suffix]=='A' || p[suffix]=='B' || p[suffix]=='C')) {
                decoded.controls[i][n]=p[suffix];decoded.controls[i][n+1]=0;
            }
            advanced=key+n;break;
        }
        at+=advanced;
    }
    *out=decoded;return DC_OK;
}
