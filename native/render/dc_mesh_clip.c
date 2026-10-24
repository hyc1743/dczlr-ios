#include "dc_mesh.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct clip_vertex { double p[4],uv[2]; } clip_vertex;

static int overlaps(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}

static double distance_to_plane(const clip_vertex *v,unsigned plane) {
    unsigned axis=plane/2;
    if (plane==4) return v->p[2];
    return (plane&1) ? v->p[3]-v->p[axis] : v->p[3]+v->p[axis];
}

static dc_status clip_triangle(clip_vertex *polygon,size_t *count) {
    clip_vertex scratch[10];
    for (unsigned plane=0;plane<6 && *count;++plane) {
        size_t produced=0;
        clip_vertex previous=polygon[*count-1];
        double pd=distance_to_plane(&previous,plane);
        for (size_t j=0;j<*count;++j) {
            clip_vertex current=polygon[j];
            double cd=distance_to_plane(&current,plane);
            if ((pd>=0)!=(cd>=0)) {
                if (produced>=10) return DC_RANGE;
                double t=pd/(pd-cd);
                clip_vertex v;
                for (unsigned k=0;k<4;++k) v.p[k]=(1-t)*previous.p[k]+t*current.p[k];
                for (unsigned k=0;k<2;++k) v.uv[k]=(1-t)*previous.uv[k]+t*current.uv[k];
                /* Put the intersection exactly on its clipping plane. */
                v.p[plane/2]=plane==4 ? 0 : (plane&1) ? v.p[3] : -v.p[3];
                scratch[produced++]=v;
            }
            if (cd>=0) {
                if (produced>=10) return DC_RANGE;
                scratch[produced++]=current;
            }
            previous=current;pd=cd;
        }
        memcpy(polygon,scratch,produced*sizeof(*polygon));
        *count=produced;
    }
    return DC_OK;
}

dc_status dc_mesh_clip_project(const dc_mesh_vertex *vertices,size_t vertex_count,
        const uint16_t *indices,size_t index_count,const dc_matrix *mvp,
        const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity,
        size_t *written) {
    if (!vertices || !indices || !mvp || !viewport || !written || (!out && capacity)) return DC_ARGUMENT;
    if (!vertex_count || vertex_count>1048576 || !index_count || index_count>1048576 ||
        index_count%3 || capacity>1048576) return DC_RANGE;
    const void *inputs[]={vertices,indices,mvp,viewport};
    size_t lengths[]={vertex_count*sizeof(*vertices),index_count*sizeof(*indices),sizeof(*mvp),sizeof(*viewport)};
    size_t bytes=capacity*sizeof(*out);
    if (out && overlaps(out,bytes,written,sizeof(*written))) return DC_ARGUMENT;
    for (unsigned i=0;i<4;++i) if ((out && overlaps(inputs[i],lengths[i],out,bytes)) ||
        overlaps(inputs[i],lengths[i],written,sizeof(*written))) return DC_ARGUMENT;
    const float *view=&viewport->x;
    for (unsigned i=0;i<6;++i) if (!isfinite(view[i])) return DC_RANGE;
    if (viewport->width<=0 || viewport->height<=0 || viewport->min_z<0 || viewport->max_z>1 ||
        viewport->min_z>viewport->max_z) return DC_RANGE;
    for (unsigned i=0;i<16;++i) if (!isfinite(mvp->values[i])) return DC_RANGE;
    dc_sprite_vertex *result=out && bytes ? malloc(bytes) : NULL;
    if (out && bytes && !result) return DC_MEMORY;
    dc_status status=DC_OK;
    size_t total=0;
    for (size_t triangle=0;triangle<index_count && status==DC_OK;triangle+=3) {
        clip_vertex polygon[10];
        for (unsigned j=0;j<3;++j) {
            uint16_t index=indices[triangle+j];
            if (index>=vertex_count) { status=DC_RANGE;break; }
            const dc_mesh_vertex *v=&vertices[index];
            if (!isfinite(v->uv[0]) || !isfinite(v->uv[1])) { status=DC_RANGE;break; }
            float p[4]={v->position[0],v->position[1],v->position[2],1};
            for (unsigned k=0;k<4;++k) if (!isfinite(p[k])) status=DC_RANGE;
            if (status!=DC_OK) break;
            for (unsigned col=0;col<4;++col) {
                float sum=0;
                for (unsigned k=0;k<4;++k) {
                    volatile float product=p[k]*mvp->values[k*4+col];
                    sum+=product;
                }
                if (!isfinite(sum)) { status=DC_RANGE;break; }
                polygon[j].p[col]=sum;
            }
            polygon[j].uv[0]=v->uv[0];polygon[j].uv[1]=v->uv[1];
        }
        if (status!=DC_OK) break;
        size_t count=3;
        status=clip_triangle(polygon,&count);
        if (status!=DC_OK || count<3) continue;
        size_t added=(count-2)*3;
        if (added>1048576-total || (out && added>capacity-total)) { status=DC_RANGE;break; }
        dc_sprite_vertex projected[10];
        for (size_t j=0;j<count;++j) {
            const clip_vertex *v=&polygon[j];
            if (!(v->p[3]>0)) { status=DC_RANGE;break; }
            double rw=1/v->p[3];
            projected[j]=(dc_sprite_vertex){
                .x=(float)(viewport->x+(v->p[0]*rw+1)*viewport->width*.5),
                .y=(float)(viewport->y+(1-v->p[1]*rw)*viewport->height*.5),
                .z=(float)(viewport->min_z+v->p[2]*rw*(viewport->max_z-viewport->min_z)),
                .rhw=(float)rw,.diffuse=diffuse,.u=(float)v->uv[0],.v=(float)v->uv[1]};
            const dc_sprite_vertex *p=&projected[j];
            if (!isfinite(p->x) || !isfinite(p->y) || !isfinite(p->z) || !isfinite(p->rhw) ||
                p->rhw<=0 || !isfinite(p->u) || !isfinite(p->v)) { status=DC_RANGE;break; }
        }
        if (status!=DC_OK) break;
        if (out) for (size_t j=1;j+1<count;++j) {
            result[total++]=projected[0];result[total++]=projected[j];result[total++]=projected[j+1];
        }
        else total+=added;
    }
    if (status==DC_OK) {
        if (total && out) memcpy(out,result,total*sizeof(*out));
        *written=total;
    }
    free(result);
    return status;
}
