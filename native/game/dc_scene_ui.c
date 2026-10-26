#include "dc_scene_ui.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

dc_status dc_scene_icon_uv(uint32_t stage,uint32_t icon,float *u0,float *u1) {
    if(!u0||!u1||u0==u1)return DC_ARGUMENT;
    if(stage>2||icon<1||icon>4)return DC_RANGE;
    float left=icon==2?(2-stage)*.25f:0.f;
    *u0=left;*u1=icon==2?left+.25f:1.f;return DC_OK;
}

dc_status dc_scene_action_build(uint32_t type,uint32_t icon,uint32_t option,uint32_t mode,uint32_t secondary,dc_scene_action_plan *out) {
    if(!out)return DC_ARGUMENT;
    if(type!=4)return DC_NOT_FOUND;
    if(icon<1||icon>4||mode>2||secondary>2)return DC_RANGE;
    if(icon<3)return DC_NOT_FOUND;
    dc_scene_action_plan plan={.camera_mode=mode,.secondary_camera_mode=secondary};
    if(icon==4) {
        if(option>1)return DC_RANGE;
        plan.commands[plan.count++]=(dc_scene_action_command){option==0?DC_SCENE_ENTER_SAVE_MENU:DC_SCENE_ENTER_EDIT_MENU,0};
    } else {
        if(option>6)return DC_RANGE;
        if(option<3)plan.camera_mode=(mode==2&&option==2)?0:option;
        else if(option<6)plan.secondary_camera_mode=(secondary==2&&option==5)?0:option%3;
        else plan.camera_mode=plan.secondary_camera_mode=0;
        if(option<2)plan.commands[plan.count++]=(dc_scene_action_command){DC_SCENE_CAMERA_RETARGET_PRIMARY,option};
        else if(option==2)plan.commands[plan.count++]=(dc_scene_action_command){DC_SCENE_CAMERA_RESET_PRIMARY,0};
        else if(option<5)plan.commands[plan.count++]=(dc_scene_action_command){DC_SCENE_CAMERA_RETARGET_SECONDARY,option%3};
        else if(option==5)plan.commands[plan.count++]=(dc_scene_action_command){DC_SCENE_CAMERA_RESET_SECONDARY,0};
        else {
            plan.commands[plan.count++]=(dc_scene_action_command){DC_SCENE_CAMERA_RESET_PRIMARY,0};
            plan.commands[plan.count++]=(dc_scene_action_command){DC_SCENE_CAMERA_RESET_SECONDARY,0};
        }
    }
    *out=plan;return DC_OK;
}

dc_status dc_scene_context_build(const dc_scene_context_input *in,dc_scene_context *out) {
    if(!in||!out)return DC_ARGUMENT;
    if(in->scene_type!=4)return DC_NOT_FOUND;
    if(in->icon<1||in->icon>4||in->stage_progress>2||in->camera_mode>2||in->secondary_camera_mode>2||!isfinite(in->x)||!isfinite(in->y))return DC_RANGE;
    dc_scene_context menu={.icon=in->icon,.opening_right=1,.hover=-1};
    for(unsigned i=0;i<7;++i)menu.items[i].resource_id=-1;
    if(in->icon==1) {
        if(in->stage_progress)return DC_NOT_FOUND;
        if(in->animation==1||in->animation==11||in->animation==13) {
            menu.count=2;menu.items[0]=(dc_scene_context_item){1,6,0,0};menu.items[1]=(dc_scene_context_item){2,0,0,0};
        }
    } else if(in->icon==2) {
        if(in->stage_progress)return DC_NOT_FOUND;
        /* Original type 4 has no outfit context while progress is zero. */
    } else if(in->icon==3) {
        static const int32_t ids[]={1,2,4,8,5,7,9};menu.count=7;
        for(unsigned i=0;i<7;++i)menu.items[i]=(dc_scene_context_item){ids[i],i,0,0};
        if(in->camera_mode==2){menu.items[0].resource_id=menu.items[1].resource_id=-1;menu.items[2].resource_id=44;}
        if(in->secondary_camera_mode==2){menu.items[3].resource_id=menu.items[4].resource_id=-1;menu.items[5].resource_id=47;}
    } else {
        menu.count=2;menu.items[0]=(dc_scene_context_item){1,3,0,0};menu.items[1]=(dc_scene_context_item){2,0,0,0};
    }
    /* The original computes 105 * (float)(1/3), then its multiples. */
    float unit=105.f*.3333333432674408f;
    float dx[]={0,unit,unit+unit,105,unit+unit,unit,0};
    float dy[]={-105,-(unit+unit),-unit,0,unit,unit+unit,105};
    for(unsigned i=0;i<menu.count;++i) {
        dc_scene_context_item *item=&menu.items[i];
        item->x=in->x-dx[item->arrangement];item->y=in->y+dy[item->arrangement];
    }
    *out=menu;return DC_OK;
}
dc_status dc_scene_context_hit(const dc_scene_context *menu,float x,float y,int32_t *out) {
    if(!menu||!out)return DC_ARGUMENT;
    if(menu->count>7||!isfinite(x)||!isfinite(y))return DC_RANGE;
    int32_t hit=-1;
    for(unsigned i=0;i<menu->count;++i) {
        const dc_scene_context_item *b=&menu->items[i];
        if(b->resource_id<0)continue;
        float left=b->x-240.f*.9f,top=b->y-32.f*.5f;
        if(x>=left&&x<=left+240.f&&y>=top&&y<=top+32.f){hit=(int32_t)i;break;}
    }
    *out=hit;return DC_OK;
}
dc_status dc_scene_context_step(dc_scene_context *menu,float x,float y,uint32_t left,uint32_t right,dc_scene_context_event *out) {
    if(!menu||!out)return DC_ARGUMENT;
    if(menu->icon<1||menu->icon>4||left>3||right>3)return DC_RANGE;
    int32_t hit;dc_status status=dc_scene_context_hit(menu,x,y,&hit);if(status!=DC_OK)return status;
    dc_scene_context next=*menu;next.hover=hit;
    dc_scene_context_event event={.selected=-1};
    if(right==2)next.opening_right=0;
    if(left==3) {
        event.selected=hit;
        event.close_code=hit<0?1:((menu->icon==1&&hit>1)?1:2);
    } else if(right==3&&!next.opening_right)event.close_code=1;
    *menu=next;*out=event;return DC_OK;
}
dc_status dc_scene_context_resource(uint32_t type,uint32_t icon,int32_t id,uint32_t state,char *out,size_t capacity) {
    if(!out)return DC_ARGUMENT;
    if(type!=4)return DC_NOT_FOUND;
    if(icon<1||icon>4||id<0||id>999||state>1)return DC_RANGE;
    char buffer[32];int n=snprintf(buffer,sizeof(buffer),"M_%c%03d%c.ema","kacs"[icon-1],id,"SN"[state]);
    if(n<0||(size_t)n>=capacity)return DC_RANGE;
    memcpy(out,buffer,(size_t)n+1);return DC_OK;
}
