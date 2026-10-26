#include "dc_touch_controls.h"
#include <math.h>
#include <string.h>

static int contains(dc_touch_rect r,float x,float y) {
    return r.width>0 && r.height>0 && x>=r.x && x<=r.x+r.width && y>=r.y && y<=r.y+r.height;
}
static dc_touch_rect centered(float x,float y,float w,float h) {
    return (dc_touch_rect){x-w*.5f,y-h*.5f,w,h};
}
dc_status dc_touch_make_layout(float w,float h,float l,float t,float r,float b,
        uint32_t gameplay,dc_touch_layout *out) {
    if(!out)return DC_ARGUMENT;
    const float values[]={w,h,l,t,r,b};
    for(unsigned i=0;i<6;++i)if(!isfinite(values[i]))return DC_RANGE;
    if(w<600||h<280||l<0||t<0||r<0||b<0||w-l-r<540||h-t-b<240||gameplay>3)return DC_RANGE;
    float scale=fminf(1.25f,fmaxf(.8f,(h-t-b)/430.f)),right=w-r,bottom=h-b;
    dc_touch_layout layout={.width=w,.height=h,.gameplay=gameplay};
    layout.controls[DC_TOUCH_MENU]=(dc_touch_rect){l+10,t+8,64,44};
    layout.controls[DC_TOUCH_SAVE]=(dc_touch_rect){l+82,t+8,64,44};
    layout.controls[DC_TOUCH_RESET]=(dc_touch_rect){l+154,t+8,88,44};
    layout.controls[DC_TOUCH_PRIMARY]=centered(right-58*scale,bottom-76*scale,76*scale,76*scale);
    layout.controls[DC_TOUCH_BACK]=centered(right-58*scale,bottom-158*scale,64*scale,fmaxf(44,52*scale));
    if(gameplay) {
        /* Point/select + interaction is the default. Movement is an explicit
         * optional position-adjustment mode, not a permanent console pad. */
        if(gameplay&2) {
            layout.controls[DC_TOUCH_MOVE]=centered(l+82*scale,bottom-92*scale,120*scale,120*scale);
            layout.controls[DC_TOUCH_PRIMARY]=centered(l+220*scale,bottom-70*scale,112*scale,64*scale);
            layout.controls[DC_TOUCH_BACK]=centered(l+220*scale,bottom-142*scale,112*scale,44);
            layout.controls[DC_TOUCH_NEXT]=centered(l+220*scale,bottom-198*scale,112*scale,44);
        } else {
            layout.controls[DC_TOUCH_PRIMARY]=centered(l+80*scale,bottom-66*scale,120*scale,64*scale);
            layout.controls[DC_TOUCH_BACK]=centered(l+80*scale,bottom-132*scale,112*scale,44);
            layout.controls[DC_TOUCH_NEXT]=centered(l+214*scale,bottom-66*scale,112*scale,44);
        }
        layout.controls[DC_TOUCH_LOOK]=centered(right-90*scale,bottom-126*scale,128*scale,144*scale);
        layout.controls[DC_TOUCH_ZOOM_IN]=centered(right-124*scale,bottom-30*scale,48,44);
        layout.controls[DC_TOUCH_ZOOM_OUT]=centered(right-64*scale,bottom-30*scale,48,44);
    } else {
        layout.controls[DC_TOUCH_SAVE]=(dc_touch_rect){0};
        layout.controls[DC_TOUCH_RESET]=(dc_touch_rect){0};
    }
    *out=layout;return DC_OK;
}
uint32_t dc_touch_hit(const dc_touch_layout *l,float x,float y) {
    if(!l||!isfinite(x)||!isfinite(y)||x<0||y<0||x>l->width||y>l->height)return DC_TOUCH_NONE;
    for(uint32_t i=DC_TOUCH_PRIMARY;i<DC_TOUCH_COUNT;++i)
        if(contains(l->controls[i],x,y))return i;
    for(uint32_t i=DC_TOUCH_MOVE;i<=DC_TOUCH_LOOK;++i) {
        dc_touch_rect r=l->controls[i];
        if(i==DC_TOUCH_LOOK?contains(r,x,y):
            (r.width>0&&hypotf(x-r.x-r.width*.5f,y-r.y-r.height*.5f)<=r.width*.6f))return i;
    }
    return DC_TOUCH_POINTER;
}
static dc_touch_contact *find(dc_touch_controls *s,uint64_t id) {
    for(unsigned i=0;i<16;++i)if(s->fingers[i].id==id)return &s->fingers[i];
    return NULL;
}
dc_status dc_touch_begin(dc_touch_controls *s,uint64_t id,float x,float y) {
    if(!s||!id)return DC_ARGUMENT;
    uint32_t control=dc_touch_hit(&s->layout,x,y);
    if(!control)return DC_RANGE;
    if(find(s,id))return DC_ARGUMENT;
    dc_touch_contact *free_slot=NULL;
    for(unsigned i=0;i<16;++i) {
        if(!s->fingers[i].id){if(!free_slot)free_slot=&s->fingers[i];}
        else if((control==DC_TOUCH_MOVE||control==DC_TOUCH_LOOK)&&s->fingers[i].control==control)
            return DC_RANGE;
    }
    if(!free_slot)return DC_RANGE;
    *free_slot=(dc_touch_contact){id,control,x,y,x,y};return DC_OK;
}
dc_status dc_touch_move(dc_touch_controls *s,uint64_t id,float x,float y) {
    if(!s||!id)return DC_ARGUMENT;
    if(!isfinite(x)||!isfinite(y))return DC_RANGE;
    dc_touch_contact *f=find(s,id);if(!f)return DC_NOT_FOUND;
    if(f->control==DC_TOUCH_LOOK) {
        s->look_dx=fmaxf(-100,fminf(100,s->look_dx+x-f->x));
        s->look_dy=fmaxf(-100,fminf(100,s->look_dy+y-f->y));
    }
    f->x=x;f->y=y;
    return DC_OK;
}
uint32_t dc_touch_end(dc_touch_controls *s,uint64_t id,uint32_t cancelled) {
    if(!s||!id)return 0;
    dc_touch_contact *f=find(s,id);if(!f)return 0;
    uint32_t action=!cancelled && f->control==DC_TOUCH_MENU &&
        contains(s->layout.controls[DC_TOUCH_MENU],f->x,f->y)?DC_TOUCH_MENU:0;
    memset(f,0,sizeof(*f));return action;
}
void dc_touch_clear_motion(dc_touch_controls *s) { if(s)s->look_dx=s->look_dy=0; }
void dc_touch_reset(dc_touch_controls *s) {
    if(s){memset(s->fingers,0,sizeof(s->fingers));dc_touch_clear_motion(s);}
}
dc_touch_snapshot dc_touch_read(const dc_touch_controls *s) {
    dc_touch_snapshot out={0};if(!s)return out;
    out.pad.rx=(int32_t)lrintf(fmaxf(-32767,fminf(32767,s->look_dx*1800)));
    out.pad.ry=(int32_t)lrintf(fmaxf(-32767,fminf(32767,-s->look_dy*1800)));
    for(unsigned i=0;i<16;++i) {
        const dc_touch_contact *f=&s->fingers[i];if(!f->id)continue;
        switch(f->control) {
        case DC_TOUCH_MOVE: {
            dc_touch_rect r=s->layout.controls[DC_TOUCH_MOVE];
            dc_pad_stick(f->x-r.x-r.width*.5f,f->y-r.y-r.height*.5f,r.width*.5f,&out.pad.lx,&out.pad.ly);break;
        }
        case DC_TOUCH_LOOK:break;
        case DC_TOUCH_PRIMARY:out.pad.buttons|=DC_PAD_A;break;
        case DC_TOUCH_BACK:out.pad.buttons|=DC_PAD_B;break;
        case DC_TOUCH_SAVE:out.pad.buttons|=DC_PAD_X;break;
        case DC_TOUCH_RESET:out.pad.buttons|=DC_PAD_Y;break;
        case DC_TOUCH_NEXT:out.pad.buttons|=DC_PAD_PLUS;break;
        case DC_TOUCH_ZOOM_IN:out.pad.buttons|=DC_PAD_ZR;break;
        case DC_TOUCH_ZOOM_OUT:out.pad.buttons|=DC_PAD_ZL;break;
        case DC_TOUCH_MENU:out.held_ui|=1u<<DC_TOUCH_MENU;break;
        case DC_TOUCH_POINTER:
            out.touches[out.touch_count++]=(dc_pad_touch){i,
                fminf(1,fmaxf(0,f->x/s->layout.width)),fminf(1,fmaxf(0,f->y/s->layout.height))};break;
        default:break;
        }
    }
    return out;
}
