#include "dc_menu.h"
#include <math.h>
#include <string.h>

static int overlaps(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
dc_status dc_menu_step(dc_menu_state *state,const dc_menu_button *buttons,size_t count,
        int32_t x,int32_t y,float scale,uint8_t input_code,int32_t *result) {
    if (!state || !result || (count && !buttons) || count>DC_MENU_LIMIT) return DC_ARGUMENT;
    if (overlaps(state,sizeof(*state),result,sizeof(*result)) ||
        overlaps(buttons,count*sizeof(*buttons),result,sizeof(*result)) ||
        overlaps(buttons,count*sizeof(*buttons),state,sizeof(*state))) return DC_ARGUMENT;
    if (!isfinite(scale) || scale<=0) return DC_RANGE;
    for (size_t i=0;i<count;++i) {
        const dc_menu_button *b=&buttons[i];
        if (!isfinite(b->x)||!isfinite(b->y)||!isfinite(b->width)||!isfinite(b->height)||b->width<0||b->height<0) return DC_RANGE;
        if (!isfinite(b->x*scale)||!isfinite(b->y*scale)||!isfinite(b->width*scale)||!isfinite(b->height*scale)) return DC_RANGE;
    }
    dc_menu_state next=*state;next.active=1;
    int32_t code=-1;
    for (uint32_t i=0;i<count;++i) {
        next.pressed[i]=0;
        const dc_menu_button *b=&buttons[i];
        if (b->x==-1 || b->disabled==1) continue;
        float left=b->x*scale,top=b->y*scale,width=b->width*scale,height=b->height*scale;
        if ((double)x<left || (double)left+width<x || (double)y<top || (double)top+height<y) continue;
        if ((input_code&1) && b->press_activate==1) { next.pressed[i]=1;code=1; }
        else if (input_code!=3) {
            code=next.hover==(int32_t)i ? 0 : 2;
            next.hover=(int32_t)i;
        } else if (b->toggle==1) { next.toggled[i]^=1;code=1; }
        else {
            next.selected=(int32_t)i;
            code=next.hover==(int32_t)i ? 1 : 3;
            next.hover=(int32_t)i;
        }
        *state=next;*result=code;return DC_OK;
    }
    next.active=0;*state=next;*result=code;return DC_OK;
}

static void title_command(dc_title_plan *p,uint32_t kind,uint32_t value) {
    p->commands[p->count++]=(dc_title_command){kind,value};
}

dc_status dc_title_build_plan(const dc_title_state *state,
        const dc_title_input *input,dc_title_plan *out) {
    if (!state || !input || !out) return DC_ARGUMENT;
    if (state->action>6 || state->waiting>1 || (state->hover>4 && state->hover!=255) ||
        input->transition_ready>1 || input->selection_busy>1 || input->escape_code>255 ||
        input->menu_result < -1 || input->menu_result>3 ||
        (input->menu_result!=-1 && (input->menu_row<0 || input->menu_row>4))) return DC_RANGE;
    dc_title_plan p={0};p.next=*state;
    if (p.next.waiting && input->transition_ready) {
        uint32_t action=p.next.action;
        if (!action) p.next.waiting=0;
        else if (action==6 || !input->selection_busy) {
            if (action==5) {
                title_command(&p,DC_TITLE_CLEANUP,0);
                title_command(&p,DC_TITLE_QUIT,0);
            } else if (action==2 || action==6) {
                title_command(&p,DC_TITLE_BACKUP,action==2 ? 1 : 2);
                title_command(&p,DC_TITLE_HIDE,1);
                title_command(&p,DC_TITLE_ENTER,action);
                title_command(&p,DC_TITLE_STOP_MUSIC,0);
                p.next.action=0;
                if (action==2) p.next.hover=255;
            } else {
                title_command(&p,DC_TITLE_CLEANUP,0);
                title_command(&p,DC_TITLE_ENTER,action);
                if (action==1) title_command(&p,DC_TITLE_INIT_GAME,0);
                else title_command(&p,DC_TITLE_HIDE,2);
            }
            p.departed=1;
        }
    }
    if (!p.next.waiting) {
        if (input->escape_code==3) {
            p.next.action=6;p.next.waiting=1;
            title_command(&p,DC_TITLE_TRANSITION,3);
        } else {
            p.next.hover=input->menu_result==-1 ? 255 : (uint32_t)input->menu_row;
            if (input->menu_result==1) {
                p.next.action=(uint32_t)input->menu_row+1;p.next.waiting=1;
                title_command(&p,DC_TITLE_PLAY_SELECTION,0);
                title_command(&p,DC_TITLE_TRANSITION,2);
            }
        }
    }
    memcpy(out,&p,sizeof(p));return DC_OK;
}
