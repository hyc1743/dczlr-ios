#include "dc_flow.h"
#include <string.h>

static const uint8_t maps[DC_FLOW_CHAPTERS]={
    255,255,255,0,255,1,255,3,255,255,0,255,1,255,6,255,255,0,255,1,255,4,255,255,255,255,255,255,255};
static const uint8_t stages[DC_FLOW_CHAPTERS]={
    255,255,255,2,255,2,255,2,255,255,1,255,1,255,1,255,255,0,255,0,255,0,255,255,255,255,255,255,255};
static const uint8_t scripts[DC_FLOW_CHAPTERS][2]={
    {0,2},{1,31},{2,9},{255,255},{15,2},{255,255},{3,38},{255,255},
    {4,31},{5,5},{255,255},{16,2},{255,255},{6,42},{255,255},{7,43},
    {8,4},{255,255},{9,4},{255,255},{10,51},{255,255},{11,74},{13,4},
    {255,255},{12,13},{14,4},{17,1},{18,2}};
static const uint32_t callbacks[DC_FLOW_CHAPTERS]={
    0x605510,0x605510,0x605510,0x512cc0,0x605510,0x489f20,0x605510,0x483510,
    0x605510,0x605510,0x512cc0,0x605510,0x489f20,0x605510,0x483510,0x605510,
    0x605510,0x512cc0,0x605510,0x489f20,0x605510,0x483510,0x605510,0x605510,
    0x51abb0,0x605510,0x605510,0x605510,0x605510};
static const uint8_t types[DC_FLOW_CHAPTERS]={
    3,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,2,3,3,3,3};

static int overlaps(const void *a,size_t an,const void *b,size_t bn) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return an&&bn&&(aa<=bb?bb-aa<an:aa-bb<bn);
}
static int valid_meta(const dc_save_slot_meta *m) {
    return m->chapter<DC_FLOW_CHAPTERS && m->scene_type<=13 && m->previous_type<=13 &&
        (m->map<=8||m->map==255) && (m->stage<3||m->stage==255) &&
        (m->selector0<3||m->selector0==255) && (m->selector1<3||m->selector1==255);
}
static uint16_t read16(const uint8_t *p) {return (uint16_t)((uint16_t)p[0]|(uint16_t)p[1]<<8);}
static void write16(uint8_t *p,uint16_t n) {p[0]=(uint8_t)n;p[1]=(uint8_t)(n>>8);}
static void add_cap16(uint8_t *p,uint32_t n) {
    uint32_t sum=(uint32_t)read16(p)+n;write16(p,(uint16_t)(sum>10000?10000:sum));
}
static dc_flow_result empty_result(void) {
    dc_flow_result r={0};r.script=-1;r.last_frame=-1;return r;
}
static void chapter_route(dc_flow_state *s,dc_flow_result *r) {
    uint32_t c=s->meta.chapter;
    s->meta.map=maps[c];s->meta.stage=stages[c];
    r->callback=callbacks[c];r->destination_type=types[c];r->flags=DC_FLOW_DEPART;
    r->script=scripts[c][0]==255?-1:scripts[c][0];
    r->last_frame=scripts[c][1]==255?-1:scripts[c][1];
}
static uint32_t scheduler_core(uint8_t *raw) {
    uint32_t result=0;
    for(unsigned i=0;i<3;++i) {
        uint8_t *p=raw+i*DC_FLOW_STAGE_BYTES;
        if(!p[0x34])continue;
        p[0x35]=(uint8_t)(p[0x35]+1);
        if(p[0x35]>29)p[0x35]=30;
        uint8_t n=p[0x35];
        if(p[0x36]==255||p[0x37]==255) {
            if(n==30) {if(p[0x22]!=5){p[0x35]=23;p[0x22]=5;}}
            else if(n==29)result=2;
            else if(n==22){p[0x22]=5;result=1;}
            else if(n<23)p[0x22]=n<6?0:n<15?3:4;
        } else if(n<p[0x37]) {
            if(p[0x36]==n)p[0x22]=1;
            else if(n<3) {
                if(p[0x24]){p[0x37]=255;p[0x36]=255;p[0x35]=0;p[0x22]=0;}
                else if(n+1>2)p[0x22]=0;
            } else p[0x22]=0;
        } else {p[0x35]=0;p[0x37]=9;p[0x36]=6;p[0x22]=2;}
    }
    if(result==1)for(unsigned i=0;i<3;++i) {
        uint8_t *p=raw+i*DC_FLOW_STAGE_BYTES;
        if(p[0x22]>2){p[0x22]=5;p[0x35]=23;p[0x37]=255;p[0x36]=255;}
    }
    return result;
}

dc_status dc_flow_state_init(dc_flow_state *out,const dc_save_slot_meta *meta) {
    if(!out||!meta||overlaps(out,sizeof(*out),meta,sizeof(*meta)))return DC_ARGUMENT;
    if(!valid_meta(meta))return DC_RANGE;
    dc_flow_state next;dc_status status=dc_game_state_init(next.raw,sizeof(next.raw));
    if(status!=DC_OK)return status;
    next.meta=*meta;*out=next;return DC_OK;
}
dc_status dc_flow_chapter_profile(uint32_t chapter,dc_flow_chapter *out) {
    if(!out)return DC_ARGUMENT;
    if(chapter>=DC_FLOW_CHAPTERS)return DC_RANGE;
    *out=(dc_flow_chapter){callbacks[chapter],types[chapter],
        scripts[chapter][0]==255?-1:scripts[chapter][0],
        scripts[chapter][1]==255?-1:scripts[chapter][1],maps[chapter],stages[chapter]};return DC_OK;
}
dc_status dc_flow_scheduler(dc_flow_state *state,uint32_t *result) {
    if(!state||!result||overlaps(state,sizeof(*state),result,sizeof(*result)))return DC_ARGUMENT;
    if(!valid_meta(&state->meta))return DC_RANGE;
    uint32_t value=scheduler_core(state->raw);*result=value;return DC_OK;
}
dc_status dc_flow_scene_exit(dc_flow_state *state,const dc_flow_exit_metrics *metrics,dc_flow_result *out) {
    if(!state||!metrics||!out||overlaps(state,sizeof(*state),metrics,sizeof(*metrics))||
       overlaps(state,sizeof(*state),out,sizeof(*out))||overlaps(metrics,sizeof(*metrics),out,sizeof(*out)))return DC_ARGUMENT;
    if(!valid_meta(&state->meta)||state->meta.stage>=3||state->meta.scene_type<4||state->meta.scene_type>6||
       metrics->level>255||metrics->flag_b>255||metrics->count>65535||metrics->outcome_a>65535||metrics->outcome_b>65535)return DC_RANGE;
    uint32_t type=state->meta.scene_type,stage=state->meta.stage;
    uint32_t chapter=state->meta.chapter;
    uint8_t progress=state->raw[stage*DC_FLOW_STAGE_BYTES+0x23];
    if((type==6||progress==0)&&chapter+1>=DC_FLOW_CHAPTERS)return DC_RANGE;
    dc_flow_state next=*state;dc_flow_result result=empty_result();
    uint8_t *p=next.raw+stage*DC_FLOW_STAGE_BYTES;
    if(metrics->level>1&&p[0]==0)p[0]=1;
    if(type==4) {
        if(metrics->flag_b&&p[1]==0)p[1]=1;
        if(progress==0)++next.meta.chapter;
        else {write16(p+0x1e,(uint16_t)(read16(p+0x1e)+metrics->count));next.meta.chapter=24;}
    } else if(type==5) {
        if(metrics->count)add_cap16(p+0x12,1);
        if(metrics->flag_b&&p[1]==0)p[1]=1;
        next.meta.chapter=progress==0?(uint8_t)(chapter+1):24;
    } else {
        if(metrics->flag_b&&p[1]==0)p[1]=1;
        if(metrics->outcome_a)p[0]=1;
        else if(metrics->outcome_b)p[1]=1;
        ++next.meta.chapter;
    }
    if(type!=6)result.scheduler=scheduler_core(next.raw);
    if(result.scheduler==1){result.callback=0x606910;result.destination_type=13;result.flags=DC_FLOW_DEPART;}
    else {if(result.scheduler==2)next.meta.chapter=25;chapter_route(&next,&result);}
    *state=next;*out=result;return DC_OK;
}
dc_status dc_flow_night_commit(dc_flow_state *state,uint32_t count_a,uint32_t count_b) {
    if(!state)return DC_ARGUMENT;
    if(!valid_meta(&state->meta)||state->meta.scene_type!=6||state->meta.stage>=3||count_a>65535||count_b>65535)return DC_RANGE;
    uint8_t *p=state->raw+state->meta.stage*DC_FLOW_STAGE_BYTES;
    add_cap16(p+0x26,1);add_cap16(p+0xc,count_a);add_cap16(p+0xe,count_b);
    if(count_a||count_b)add_cap16(p+0x10,1);
    if(p[0x22]==2&&count_a)p[0x24]=1;
    return DC_OK;
}
dc_status dc_flow_script_finish(dc_flow_state *state,dc_flow_result *out) {
    if(!state||!out||overlaps(state,sizeof(*state),out,sizeof(*out)))return DC_ARGUMENT;
    if(!valid_meta(&state->meta)||scripts[state->meta.chapter][0]==255)return DC_RANGE;
    dc_flow_state next=*state;dc_flow_result result=empty_result();
    uint32_t chapter=next.meta.chapter;
    if(chapter==25||chapter==26){result.callback=0x512370;result.destination_type=10;result.flags=DC_FLOW_DEPART|DC_FLOW_CLEAR_SPECIAL;}
    else {
        next.meta.chapter=chapter>=25?24:(uint8_t)(chapter+1);
        uint32_t script=scripts[next.meta.chapter][0];
        if(script==255) {
            chapter_route(&next,&result);
            if(next.meta.chapter==24&&next.raw[0x23]==0)
                for(unsigned i=0;i<3;++i)next.raw[i*DC_FLOW_STAGE_BYTES+0x23]=1;
        } else {
            result.destination_type=3;result.flags=DC_FLOW_LOAD_SCRIPT;result.script=(int32_t)script;
            result.last_frame=scripts[next.meta.chapter][1];
            if(script==1||script==5||script==8||script==13)result.flags|=DC_FLOW_SCRIPT_FADE;
        }
    }
    *state=next;*out=result;return DC_OK;
}
dc_status dc_flow_selector_admission(const dc_flow_state *state,dc_flow_selector_masks *out) {
    if(!state||!out||overlaps(state,sizeof(*state),out,sizeof(*out)))return DC_ARGUMENT;
    if(!valid_meta(&state->meta))return DC_RANGE;
    dc_flow_selector_masks result={0,{126,125,0,4,4,4},{0,0,0,0,0,0}};
    unsigned n=0,k=0,overlap=0;
    for(unsigned i=0;i<3;++i) {
        const uint8_t *p=state->raw+i*DC_FLOW_STAGE_BYTES;
        n+=p[0x23]==2;k+=p[0x22]==5;overlap+=(p[0x23]==2&&p[0x22]==5);
        if(p[0x23]!=2||p[0x22]==5)result.disabled_stages[4]|=1u<<(2-i);
    }
    if(n<3)result.disabled_categories|=1u<<5;
    if(n<2||k>=2||(n==2&&k==1&&overlap))result.disabled_categories|=1u<<4;
    *out=result;return DC_OK;
}
dc_status dc_flow_selector_route(dc_flow_state *state,const dc_flow_selection *selection,dc_flow_result *out) {
    if(!state||!selection||!out||overlaps(state,sizeof(*state),selection,sizeof(*selection))||
       overlaps(state,sizeof(*state),out,sizeof(*out))||overlaps(selection,sizeof(*selection),out,sizeof(*out)))return DC_ARGUMENT;
    if(!valid_meta(&state->meta)||state->meta.scene_type!=2||selection->category>5||selection->map_index>6||selection->stage_mask>7)return DC_RANGE;
    uint32_t category=selection->category,mask=selection->stage_mask;
    if(category<4) {if(mask==0||(mask&(mask-1)))return DC_RANGE;}
    else if(category==4) {
        if(selection->first>=3||selection->second>=3||selection->first==selection->second||
           mask!=((1u<<selection->first)|(1u<<selection->second)))return DC_RANGE;
    } else if(mask!=7)return DC_RANGE;
    dc_flow_state next=*state;dc_flow_result result=empty_result();
    const uint8_t map_values[7]={0,1,3,4,5,7,8},modes[4]={0,6,2,4};
    unsigned first=0;while(first<3&&!(mask&(1u<<first)))++first;
    next.meta.stage=(uint8_t)(2-first);
    if(category==4){next.meta.stage=(uint8_t)(2-selection->first);next.meta.selector0=(uint8_t)(2-selection->second);}
    else if(category==5){next.meta.stage=2;next.meta.selector0=1;next.meta.selector1=0;}
    if(category>=2)next.meta.script_frame=modes[category-2];
    next.meta.map=map_values[selection->map_index];next.meta.chapter=24;
    result.callback=category==0?0x512cc0:category==1?0x489f20:0x4cce80;
    result.destination_type=category==0?4:category==1?5:7;result.flags=DC_FLOW_DEPART;
    *state=next;*out=result;return DC_OK;
}
dc_status dc_flow_prompt_route(dc_flow_state *state,uint32_t row,dc_flow_result *out) {
    if(!state||!out||overlaps(state,sizeof(*state),out,sizeof(*out)))return DC_ARGUMENT;
    if(!valid_meta(&state->meta)||state->meta.scene_type!=13||row>1)return DC_RANGE;
    dc_flow_state next=*state;dc_flow_result result=empty_result();
    next.meta.chapter=(uint8_t)(27+row);next.meta.stage=stages[next.meta.chapter];
    if(row==1)for(unsigned i=0;i<3;++i) {
        uint8_t *p=next.raw+i*DC_FLOW_STAGE_BYTES;
        if(p[0x24]){p[0x22]=0;p[0x35]=2;p[0x37]=10;p[0x36]=6;p[0x24]=0;p[0x38]=0;}
    }
    result.callback=callbacks[next.meta.chapter];result.destination_type=3;result.flags=DC_FLOW_DEPART;
    result.script=scripts[next.meta.chapter][0];result.last_frame=scripts[next.meta.chapter][1];
    *state=next;*out=result;return DC_OK;
}
