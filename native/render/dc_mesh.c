#include "dc_mesh.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
dc_status dc_mesh_project(const dc_mesh_vertex *vertices,size_t vertex_count,
        const uint16_t *indices,size_t index_count,const dc_matrix *mvp,
        const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity) {
    if (!vertices || !indices || !mvp || !viewport || !out) return DC_ARGUMENT;
    if (!vertex_count || vertex_count>1048576 || !index_count || index_count>1048576 || index_count%3 || capacity<index_count) return DC_RANGE;
    size_t bytes=index_count*sizeof(*out);
    if (overlap(vertices,vertex_count*sizeof(*vertices),out,bytes) || overlap(indices,index_count*sizeof(*indices),out,bytes) ||
        overlap(mvp,sizeof(*mvp),out,bytes) || overlap(viewport,sizeof(*viewport),out,bytes)) return DC_ARGUMENT;
    const float *view=&viewport->x;
    for (unsigned i=0;i<6;++i) if (!isfinite(view[i])) return DC_RANGE;
    if (viewport->width<=0 || viewport->height<=0 || viewport->min_z<0 || viewport->max_z>1 || viewport->min_z>viewport->max_z) return DC_RANGE;
    for (unsigned i=0;i<16;++i) if (!isfinite(mvp->values[i])) return DC_RANGE;
    dc_sprite_vertex *result=malloc(bytes);
    if (!result) return DC_MEMORY;
    dc_status status=DC_OK;
    for (size_t i=0;i<index_count;++i) {
        if (indices[i]>=vertex_count) { status=DC_RANGE; break; }
        const dc_mesh_vertex *v=&vertices[indices[i]];
        if (!isfinite(v->uv[0]) || !isfinite(v->uv[1])) { status=DC_RANGE; break; }
        float position[4]={v->position[0],v->position[1],v->position[2],1},clip[4];
        for (unsigned c=0;c<4;++c) {
            float sum=0;
            for (unsigned k=0;k<4;++k) {
                volatile float product=position[k]*mvp->values[k*4+c];
                sum+=product;
            }
            clip[c]=sum;
        }
        if (!isfinite(clip[3]) || clip[3]<=0) { status=DC_RANGE; break; }
        float rhw=1/clip[3];
        dc_sprite_vertex vertex={.x=viewport->x+(clip[0]*rhw+1)*viewport->width*.5f,
            .y=viewport->y+(1-clip[1]*rhw)*viewport->height*.5f,
            .z=viewport->min_z+clip[2]*rhw*(viewport->max_z-viewport->min_z),.rhw=rhw,
            .diffuse=diffuse,.u=v->uv[0],.v=v->uv[1]};
        if (!isfinite(vertex.x) || !isfinite(vertex.y) || !isfinite(vertex.z) || !isfinite(vertex.rhw)) { status=DC_RANGE; break; }
        result[i]=vertex;
    }
    if (status==DC_OK) memcpy(out,result,bytes);
    free(result);
    return status;
}
