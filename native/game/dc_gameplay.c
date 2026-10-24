#include "dc_gameplay.h"
#include <math.h>
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
