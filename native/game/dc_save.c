#include "dc_save.h"
#include <limits.h>
#include <string.h>
#include <stdio.h>

_Static_assert(0x64c8u+0x6414u+0x215cu==DC_GAME_STATE_BYTES,"Original state windows must stay contiguous");

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
dc_status dc_save_slot_name(uint32_t slot,char *out,size_t capacity) {
    if(!out)return DC_ARGUMENT;
    if(slot>=80)return DC_RANGE;
    char name[16];int length=snprintf(name,sizeof(name),"RP_%02u.sav",slot);
    if(length<0||(size_t)length>=capacity)return DC_RANGE;
    memcpy(out,name,(size_t)length+1);return DC_OK;
}
dc_status dc_save_slot_encode(const void *state,size_t state_bytes,const dc_save_slot_meta *meta,void *slot,size_t capacity) {
    if(!state||!meta||!slot||overlap(state,state_bytes,slot,capacity)||overlap(meta,sizeof(*meta),slot,capacity))return DC_ARGUMENT;
    if(state_bytes<DC_GAME_STATE_BYTES||capacity<DC_SAVE_SLOT_BYTES)return DC_RANGE;
    const uint8_t *src=state;uint8_t *dst=slot;
    memcpy(dst,src,0x64c8);dc_save_transform(dst,0x64c8);dst[0x64c8]=meta->chapter;
    memcpy(dst+0x64c9,src+0x64c8,0x6414);dc_save_transform(dst+0x64c9,0x6414);
    memcpy(dst+0xc8dd,src+0xc8dc,0x215c);dc_save_transform(dst+0xc8dd,0x215c);
    uint8_t tail[]={meta->scene_type,meta->previous_type,meta->map,meta->stage,meta->selector0,meta->selector1,meta->script_frame};
    memcpy(dst+0xea39,tail,sizeof(tail));return DC_OK;
}
dc_status dc_save_slot_decode(const void *slot,size_t slot_bytes,void *state,size_t capacity,dc_save_slot_meta *meta) {
    if(!slot||!state||!meta||overlap(slot,slot_bytes,state,capacity)||overlap(slot,slot_bytes,meta,sizeof(*meta))||
       overlap(state,capacity,meta,sizeof(*meta)))return DC_ARGUMENT;
    if(slot_bytes<DC_SAVE_SLOT_BYTES||capacity<DC_GAME_STATE_BYTES)return DC_RANGE;
    const uint8_t *src=slot;uint8_t *dst=state;
    memcpy(dst,src,0x64c8);dc_save_transform(dst,0x64c8);
    memcpy(dst+0x64c8,src+0x64c9,0x6414);dc_save_transform(dst+0x64c8,0x6414);
    memcpy(dst+0xc8dc,src+0xc8dd,0x215c);dc_save_transform(dst+0xc8dc,0x215c);
    *meta=(dc_save_slot_meta){src[0x64c8],src[0xea39],src[0xea3a],src[0xea3b],src[0xea3c],src[0xea3d],src[0xea3e],src[0xea3f]};
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
