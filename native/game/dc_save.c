#include "dc_save.h"
#include <limits.h>
#include <string.h>

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
static void write_word(uint8_t *p,size_t at,uint32_t value) {
    for(unsigned i=0;i<4;++i)p[at+i]=(uint8_t)(value>>(i*8));
}
dc_status dc_game_state_init(void *bytes,size_t capacity) {
    if(!bytes)return DC_ARGUMENT;
    if(capacity<DC_GAME_STATE_BYTES)return DC_RANGE;
    uint8_t *p=bytes;
    memset(p,0,DC_GAME_STATE_BYTES);
    p[4]=1;p[2]=1;p[0x219b]=1;p[0x219a]=1;p[0x2198]=1;
    write_word(p,0x30,100000);write_word(p,0x21c8,100000);write_word(p,0x4360,100000);
    const uint32_t values[3]={0x3f000000,0x3fc00000,0x40200000};
    for(unsigned record=0;record<3;++record)for(unsigned group=0;group<7;++group)for(unsigned lane=0;lane<3;++lane) {
        for(unsigned i=0;i<100;++i) {
            write_word(p,record*0x2198+0xc8+group*0x4b0+lane*400+i*4,values[lane]);
            write_word(p,0x6554+record*0x215c+group*0x4b0+lane*400+i*4,values[lane]);
        }
        write_word(p,record*0x2198+0x74+group*12+lane*4,values[lane]);
        write_word(p,0x6500+record*0x215c+group*12+lane*4,values[lane]);
    }
    for(unsigned group=0;group<7;++group)for(unsigned lane=0;lane<3;++lane) {
        for(unsigned i=0;i<100;++i)write_word(p,0xc968+group*0x4b0+lane*400+i*4,values[lane]);
        write_word(p,0xc914+group*12+lane*4,values[lane]);
    }
    return DC_OK;
}
