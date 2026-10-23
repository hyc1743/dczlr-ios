#include "dc_save.h"
#include <limits.h>

static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
dc_status dc_save_transform(void *bytes,size_t length) {
    if ((length && !bytes) || length>INT32_MAX) return DC_ARGUMENT;
    uint8_t *p=bytes;
    const uint8_t key[4]={0x2e,0xcd,0xb7,0x32};
    size_t complete=length&~(size_t)3;
    for(size_t i=0;i<complete;++i)p[i]^=key[i%4];
    return DC_OK;
}
dc_status dc_save_get_unlocks(const void *bytes,size_t length,dc_save_unlocks *out) {
    if(!bytes || !out || overlap(bytes,length,out,sizeof(*out))) return DC_ARGUMENT;
    if(length<DC_SAVE_RECORD_BYTES)return DC_FORMAT;
    const uint8_t *p=bytes;
    /* All three offsets are byte index 3 of their respective encoded word. */
    uint8_t a=p[0x23]^0x32,b=p[0x21bb]^0x32,c=p[0x4353]^0x32;
    uint32_t complete=a==2 && b==2 && c==2;
    *out=(dc_save_unlocks){complete,complete || a!=0};
    return DC_OK;
}
