#include "dc_gameplay.h"
#include <math.h>
#include <string.h>
static int overlap(const void*a,size_t al,const void*b,size_t bl){uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;return al&&bl&&(aa<=bb?bb-aa<al:aa-bb<bl);}
dc_status dc_game_player_step(const dc_game_player *s,const dc_game_input *in,float dt,dc_game_player *out){
    if(!s||!in||!out)return DC_ARGUMENT;
    if(overlap(s,sizeof(*s),out,sizeof(*out))||overlap(in,sizeof(*in),out,sizeof(*out)))return DC_ARGUMENT;
    const float v[]={s->x,s->z,s->min_x,s->max_x,s->min_z,s->max_z,s->speed,in->axis_x,in->axis_z,dt};
    for(unsigned i=0;i<10;++i)if(!isfinite(v[i]))return DC_RANGE;
    if(s->min_x>s->max_x||s->min_z>s->max_z||s->speed<0||dt<0||in->axis_x<-1||in->axis_x>1||in->axis_z<-1||in->axis_z>1)return DC_RANGE;
    dc_game_player next=*s;
    if(in->touching&&dt>0){next.x=fmaxf(s->min_x,fminf(s->max_x,s->x+in->axis_x*s->speed*dt));next.z=fmaxf(s->min_z,fminf(s->max_z,s->z+in->axis_z*s->speed*dt));}
    if(!isfinite(next.x)||!isfinite(next.z))return DC_RANGE;*out=next;return DC_OK;
}
static uint32_t checksum(const uint8_t *p,size_t n){uint32_t h=2166136261u;for(size_t i=0;i<n;++i)h=(h^p[i])*16777619u;return h;}
dc_status dc_game_next_map_selector(uint32_t current,uint32_t *next,uint32_t *finished){
    if(!next||!finished)return DC_ARGUMENT;
    static const uint32_t sequence[DC_GAME_MAP_SEQUENCE_COUNT]={0,1,3,4,5,6,7,8};
    uint32_t index=UINT32_MAX;
    for(uint32_t i=0;i<DC_GAME_MAP_SEQUENCE_COUNT;++i)if(sequence[i]==current){index=i;break;}
    if(index==UINT32_MAX)return DC_RANGE;
    *next=index+1<DC_GAME_MAP_SEQUENCE_COUNT?sequence[index+1]:current;
    *finished=index+1==DC_GAME_MAP_SEQUENCE_COUNT;
    return DC_OK;
}
dc_status dc_game_story_map_selector(uint32_t story_state,uint32_t *selector){
    static const uint8_t table[DC_GAME_STORY_MAP_TABLE_COUNT]={
        0xff,0xff,0xff,0,0xff,1,0xff,3,0xff,0xff,0,0xff,
        1,0xff,6,0xff,0xff,0,0xff,1,0xff,4
    };
    if(!selector)return DC_ARGUMENT;
    if(story_state>=DC_GAME_STORY_MAP_TABLE_COUNT)return DC_RANGE;
    if(table[story_state]==0xff)return DC_NOT_FOUND;
    *selector=table[story_state];return DC_OK;
}
dc_status dc_game_menu_profile(dc_menu_button *buttons,size_t capacity){
    if(!buttons)return DC_ARGUMENT;
    if(capacity<DC_GAME_MENU_COUNT)return DC_RANGE;
    static const dc_menu_button profile[DC_GAME_MENU_COUNT]={
        {-1,0,0,0,1,0,0},
        {920,328,96,96,0,0,0},
        {920,440,96,96,1,0,0},
        {920,552,96,96,0,0,0},
        {920,664,96,96,0,0,0},
        {0,504,352,264,0,0,0}
    };
    memcpy(buttons,profile,sizeof(profile));
    return DC_OK;
}
dc_status dc_game_interaction_step(const dc_game_interaction_state *state,
        const dc_game_interaction_input *input,dc_game_interaction_state *out,
        dc_game_interaction_result *result){
    if(!state||!input||!out||!result)return DC_ARGUMENT;
    if(overlap(state,sizeof(*state),out,sizeof(*out))||overlap(state,sizeof(*state),result,sizeof(*result))||
       overlap(input,sizeof(*input),out,sizeof(*out))||overlap(input,sizeof(*input),result,sizeof(*result))||
       overlap(out,sizeof(*out),result,sizeof(*result)))return DC_ARGUMENT;
    if(state->active>1||state->completed>1||input->new_touch>1||input->near_target>1)return DC_RANGE;
    dc_game_interaction_state next=*state;dc_game_interaction_result event={0};
    if(input->new_touch&&input->near_target&&!state->active&&!state->completed){
        next.active=1;next.start_tick=input->tick;event.begin=1;
    } else if(state->active&&(uint32_t)(input->tick-state->start_tick)>DC_GAME_INTERACTION_DELAY_MS){
        if(state->interaction_count==UINT32_MAX)return DC_RANGE;
        next.active=0;next.interaction_count++;next.completed=1;event.restore=1;event.completed=1;
    }
    *out=next;*result=event;return DC_OK;
}
dc_status dc_game_player_save(const dc_game_player *state,void *bytes,size_t length){
    if(!state||!bytes)return DC_ARGUMENT;if(length<DC_GAME_PLAYER_SAVE_BYTES)return DC_RANGE;
    uint32_t nextSelector=0,finished=0;
    if(!isfinite(state->x)||!isfinite(state->z)||state->min_x>state->max_x||state->min_z>state->max_z||state->speed<0||dc_game_next_map_selector(state->map_selector,&nextSelector,&finished)!=DC_OK)return DC_RANGE;
    uint8_t record[DC_GAME_PLAYER_SAVE_BYTES]={0};memcpy(record,"PLGP",4);record[4]=1;memcpy(record+8,&state->x,4);memcpy(record+12,&state->z,4);memcpy(record+16,&state->speed,4);memcpy(record+20,&state->interaction_count,4);memcpy(record+24,&state->map_selector,4);uint32_t sum=checksum(record,28);memcpy(record+28,&sum,4);memcpy(bytes,record,sizeof(record));return DC_OK;
}
dc_status dc_game_player_load(const void *bytes,size_t length,dc_game_player *out){
    if(!bytes||!out)return DC_ARGUMENT;if(length<DC_GAME_PLAYER_SAVE_BYTES)return DC_RANGE;const uint8_t *record=bytes;uint32_t expected=checksum(record,28),actual;memcpy(&actual,record+28,4);if(memcmp(record,"PLGP",4)||record[4]!=1||expected!=actual)return DC_FORMAT;
    dc_game_player next={0};memcpy(&next.x,record+8,4);memcpy(&next.z,record+12,4);memcpy(&next.speed,record+16,4);memcpy(&next.interaction_count,record+20,4);memcpy(&next.map_selector,record+24,4);
    uint32_t nextSelector=0,finished=0;
    if(!isfinite(next.x)||!isfinite(next.z)||!isfinite(next.speed)||next.speed<0||dc_game_next_map_selector(next.map_selector,&nextSelector,&finished)!=DC_OK)return DC_RANGE;*out=next;return DC_OK;
}
