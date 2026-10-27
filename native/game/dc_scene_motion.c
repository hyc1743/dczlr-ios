#include "dc_scene_motion.h"
#include <math.h>
#include <string.h>

static int overlap(const void *a,size_t an,const void *b,size_t bn) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return an&&bn&&(aa<=bb?bb-aa<an:aa-bb<bn);
}
static int valid_state(const dc_scene_motion_state *s) {
    return s && (s->scene_type==5||s->scene_type==6) && s->stage<3 &&
        s->progress<=2 && s->phase<8 && s->pointer_mode<8 &&
        isfinite(s->metric) && isfinite(s->average_motion) &&
        s->metric>=0 && s->average_motion>=0 &&
        s->release_flag<=1 && s->history_committed<=1 &&
        s->transition_pending<=1 && s->completed<=1;
}
static dc_scene_motion_event empty_event(void) {
    return (dc_scene_motion_event){
        .request_clip=DC_SCENE_MOTION_NO_REQUEST,
        .request_chain_from=DC_SCENE_MOTION_NO_REQUEST,
        .request_chain_to=DC_SCENE_MOTION_NO_REQUEST};
}
static int pressed(uint32_t value) { return value==3; }
static int held(uint32_t value) { return value==1||value==3; }
static int released(uint32_t value) { return value==2; }
static float motion_length(const dc_scene_motion_input *in) {
    double dx=(double)in->dx,dy=(double)in->dy;
    double value=sqrt(dx*dx+dy*dy);
    return isfinite(value)?(float)value:INFINITY;
}
static void request_clip(dc_scene_motion_state *s,dc_scene_motion_event *e,uint32_t clip) {
    s->clip=clip;e->request_clip=clip;
}

dc_status dc_scene_motion_init(dc_scene_motion_state *out,uint32_t type,
        uint32_t stage,uint32_t progress,uint32_t clip) {
    if(!out)return DC_ARGUMENT;
    if((type!=5&&type!=6)||stage>=3||progress>2||clip>0xffu)return DC_RANGE;
    *out=(dc_scene_motion_state){
        .scene_type=type,.stage=stage,.progress=progress,.clip=clip,
        .phase=0,.pointer_mode=0,.release_flag=0};
    return DC_OK;
}

dc_status dc_scene_motion_context(dc_scene_motion_state *state,uint32_t option,
        dc_scene_motion_event *out) {
    if(!state||!out)return DC_ARGUMENT;
    if(!valid_state(state)||option>3)return DC_RANGE;
    dc_scene_motion_state next=*state;dc_scene_motion_event e=empty_event();
    if(next.transition_pending||next.completed)return DC_NOT_FOUND;
    if(next.scene_type==5) {
        /* 005358c0's initial watch context maps the four visible choices to
         * the first four body clips.  The XA table supplies the long chain. */
        static const uint32_t clips[4]={4,5,2,7};
        request_clip(&next,&e,clips[option]);next.phase=2;next.pointer_mode=0;
        next.metric=0;next.average_motion=0;next.sample_count=0;
    } else {
        if(next.clip==1) {
            if(option>1)return DC_RANGE;
            request_clip(&next,&e,option==0?2:6);
            if(option==0){if(next.outcome_a<10000)++next.outcome_a;}
            else {if(next.outcome_b<10000)++next.outcome_b;}
            next.phase=1;next.pointer_mode=0;
        } else if(next.clip==0x1a) {
            if(option>1)return DC_RANGE;
            /* The original installs 1a->1e and 20->37 for this context. */
            request_clip(&next,&e,option==0?0x1e:0x20);
            e.request_chain_from=0x20;e.request_chain_to=0x37;
            next.phase=2;next.pointer_mode=0;
        } else if(next.clip==0x27) {
            if(option>1)return DC_RANGE;
            request_clip(&next,&e,option==0?0x35:0x36);
            next.phase=3;next.pointer_mode=0;
        } else if(next.clip==0x37) {
            if(option<2) {
                request_clip(&next,&e,option==0?0x3a:0x3a);
                e.request_chain_from=0x3a;e.request_chain_to=option==0?2:6;
                next.phase=4;next.pointer_mode=0;
            } else {
                /* This is the only type-6 context action that exits the
                 * scene.  History is committed before the host transition. */
                next.history_committed=1;next.transition_pending=1;
                e.transition_action=2;e.history_commit=1;e.completed=1;
                next.completed=1;
            }
        } else return DC_NOT_FOUND;
    }
    *state=next;*out=e;return DC_OK;
}

static dc_status step_type5(dc_scene_motion_state *s,
        const dc_scene_motion_input *in,dc_scene_motion_event *e) {
    float amount=motion_length(in);if(!isfinite(amount))return DC_RANGE;
    if(s->phase==0) {
        if(pressed(in->left)&&in->hit_index>=0&&in->hit_index<7) {
            request_clip(s,e,(uint32_t)in->hit_index+2);s->phase=2;
            s->metric=0;s->average_motion=0;s->sample_count=0;
        } else if(pressed(in->right)||in->wheel) {
            s->pointer_mode=2;
        }
    } else if(s->phase==2) {
        if(held(in->left)&&amount>0) {
            /* 004ae840 writes the local metric from relative pointer motion;
             * keep the gate input-driven and bounded instead of timing it. */
            s->metric=fminf(10000.f,s->metric+amount);
            s->average_motion=.8f*s->average_motion+.2f*amount;
            if(s->sample_count<UINT32_MAX)++s->sample_count;
            e->metric=s->metric;e->average_motion=s->average_motion;
            if(s->metric>=75.f) {
                request_clip(s,e,1);s->phase=1;s->pointer_mode=0;
                e->metric_ready=1;
            }
        }
        if(released(in->left)||(!held(in->left)&&amount==0))s->pointer_mode=0;
    } else if(s->phase==1) {
        /* 0048aa40 waits for the actual voice/audio query to become idle. */
        if(in->audio_ready) {
            s->transition_pending=1;s->completed=1;
            e->transition_action=2;e->completed=1;
        }
    }
    return DC_OK;
}

static dc_status step_type6(dc_scene_motion_state *s,
        const dc_scene_motion_input *in,dc_scene_motion_event *e) {
    float amount=motion_length(in);if(!isfinite(amount))return DC_RANGE;
    if(s->transition_pending||s->completed)return DC_OK;
    switch(s->clip) {
    case 0x0a:
        if(held(in->left)) { request_clip(s,e,0x0b);s->pointer_mode=3;s->phase=2; }
        break;
    case 0x0b:
        if(held(in->left)&&amount>0)request_clip(s,e,0x0d);
        else if(released(in->left)||!held(in->left))request_clip(s,e,0x0c);
        break;
    case 0x0d:
    case 0x13:
    case 0x15:
        if(held(in->left)&&amount>0) {
            s->metric=fminf(10000.f,s->metric+fminf(amount,4.f));
            s->average_motion=.8f*s->average_motion+.2f*amount;
            if(s->sample_count<UINT32_MAX)++s->sample_count;
            e->metric=s->metric;e->average_motion=s->average_motion;
            if(s->clip==0x15&&s->metric>=39.f) {
                request_clip(s,e,0x19);s->phase=3;e->metric_ready=1;
            }
        }
        if(released(in->left))s->pointer_mode=0;
        break;
    default:
        if(pressed(in->right)||in->wheel)s->pointer_mode=2;
        break;
    }
    return DC_OK;
}

dc_status dc_scene_motion_step(const dc_scene_motion_state *state,
        const dc_scene_motion_input *input,dc_scene_motion_state *out,
        dc_scene_motion_event *event) {
    if(!state||!input||!out||!event)return DC_ARGUMENT;
    if(overlap(state,sizeof(*state),out,sizeof(*out))||
       overlap(state,sizeof(*state),event,sizeof(*event))||
       overlap(input,sizeof(*input),out,sizeof(*out))||
       overlap(input,sizeof(*input),event,sizeof(*event))||
       overlap(out,sizeof(*out),event,sizeof(*event)))return DC_ARGUMENT;
    if(!valid_state(state)||input->audio_ready>1||input->left>3||input->right>3||
       input->middle>3||input->ctrl>1||input->hit_index<-1||input->hit_index>6)return DC_RANGE;
    dc_scene_motion_state next=*state;dc_scene_motion_event e=empty_event();
    next.last_tick=input->tick;
    dc_status status=next.scene_type==5?step_type5(&next,input,&e):step_type6(&next,input,&e);
    if(status!=DC_OK)return status;
    *out=next;*event=e;return DC_OK;
}
