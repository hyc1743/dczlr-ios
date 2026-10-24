#include "dc_skin.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
static dc_matrix identity(void) {
    return (dc_matrix){{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}};
}
dc_status dc_skin_palette_init(dc_skin_palette *palette) {
    if (!palette) return DC_ARGUMENT;
    for (uint32_t i=0;i<DC_SKIN_PALETTE_LIMIT;++i) palette->world[i]=identity();
    return DC_OK;
}
dc_status dc_skin_palette_update(dc_skin_palette *palette,const dc_skin_bone *bones,size_t count,
        const dc_matrix *globals,size_t global_count) {
    if (!palette || (count && !bones) || (global_count && !globals)) return DC_ARGUMENT;
    if (count>4096 || global_count>4096) return DC_RANGE;
    if (overlap(palette,sizeof(*palette),bones,count*sizeof(*bones)) ||
        overlap(palette,sizeof(*palette),globals,global_count*sizeof(*globals))) return DC_ARGUMENT;
    dc_skin_palette next=*palette;
    for (size_t i=0;i<count;++i) {
        const dc_skin_bone *bone=&bones[i];
        if (bone->index==255) continue;
        if (bone->index>=DC_SKIN_PALETTE_LIMIT || bone->target>=global_count) return DC_RANGE;
        dc_status status=dc_matrix_multiply(&bone->offset,&globals[bone->target],&next.world[bone->index]);
        if (status!=DC_OK) return status;
    }
    *palette=next;return DC_OK;
}

static dc_status affine(const dc_matrix *matrix) {
    for (unsigned i=0;i<16;++i) if (!isfinite(matrix->values[i])) return DC_RANGE;
    const float *m=matrix->values;
    return m[3]==0 && m[7]==0 && m[11]==0 && m[15]==1 ? DC_OK : DC_FORMAT;
}
static dc_status inverse_transpose(const dc_matrix *matrix,float out[9]) {
    const float *m=matrix->values;
    double a=m[0],b=m[1],c=m[2],d=m[4],e=m[5],f=m[6],g=m[8],h=m[9],i=m[10];
    double cofactors[9]={e*i-f*h,f*g-d*i,d*h-e*g,c*h-b*i,a*i-c*g,b*g-a*h,b*f-c*e,c*d-a*f,a*e-b*d};
    double determinant=a*cofactors[0]+b*cofactors[1]+c*cofactors[2];
    if (!isfinite(determinant) || determinant==0) return DC_RANGE;
    for (unsigned j=0;j<9;++j) {
        out[j]=(float)(cofactors[j]/determinant);
        if (!isfinite(out[j])) return DC_RANGE;
    }
    return DC_OK;
}

dc_status dc_skin_apply(const dc_skin_palette *palette,const dc_mesh_vertex *vertices,
        const dc_xx_weights *weights,size_t count,uint32_t normal_mode,dc_mesh_vertex *out,size_t capacity) {
    if (!palette || (count && (!vertices || !weights || !out))) return DC_ARGUMENT;
    if (count>1048576 || capacity<count || normal_mode>DC_SKIN_NORMALIZE) return DC_RANGE;
    size_t bytes=count*sizeof(*out);
    if (overlap(out,bytes,palette,sizeof(*palette)) || overlap(out,bytes,vertices,bytes) ||
        overlap(out,bytes,weights,count*sizeof(*weights))) return DC_ARGUMENT;
    if (!count) return DC_OK;
    dc_mesh_vertex *result=malloc(bytes);
    if (!result) return DC_MEMORY;
    float normals[DC_SKIN_PALETTE_LIMIT][9];
    uint8_t checked[DC_SKIN_PALETTE_LIMIT]={0},normal_ready[DC_SKIN_PALETTE_LIMIT]={0};
    dc_status status=DC_OK;
    for (size_t i=0;i<count;++i) {
        const dc_mesh_vertex *source=&vertices[i];
        for (unsigned j=0;j<3;++j) {
            if (!isfinite(source->position[j]) || !isfinite(source->normal[j]) || !isfinite(weights[i].weights[j])) {status=DC_RANGE;goto done;}
        }
        if (!isfinite(source->uv[0]) || !isfinite(source->uv[1])) {status=DC_RANGE;goto done;}
        volatile float sum01=weights[i].weights[0]+weights[i].weights[1];
        volatile float sum012=sum01+weights[i].weights[2];
        float blend[4]={weights[i].weights[0],weights[i].weights[1],weights[i].weights[2],1-sum012};
        if (!isfinite(blend[3])) {status=DC_RANGE;goto done;}
        dc_mesh_vertex value=*source;
        for (unsigned j=0;j<3;++j) {value.position[j]=0;if (normal_mode) value.normal[j]=0;}
        for (unsigned joint=0;joint<4;++joint) {
            if (blend[joint]==0) continue;
            uint32_t index=weights[i].indices[joint];
            const dc_matrix *matrix=&palette->world[index];
            if (!checked[index]) {
                status=affine(matrix);if (status!=DC_OK) goto done;
                checked[index]=1;
            }
            if (normal_mode && !normal_ready[index]) {
                status=inverse_transpose(matrix,normals[index]);if (status!=DC_OK) goto done;
                normal_ready[index]=1;
            }
            for (unsigned component=0;component<3;++component) {
                float position=0,normal=0;
                for (unsigned row=0;row<4;++row) {
                    float source_value=row==3 ? 1 : source->position[row];
                    volatile float product=source_value*matrix->values[row*4+component];position+=product;
                }
                volatile float product=position*blend[joint];value.position[component]+=product;
                if (normal_mode) {
                    for (unsigned row=0;row<3;++row) {
                        volatile float term=source->normal[row]*normals[index][row*3+component];normal+=term;
                    }
                    volatile float term=normal*blend[joint];value.normal[component]+=term;
                }
            }
        }
        if (normal_mode==DC_SKIN_NORMALIZE) {
            double length=0;
            for (unsigned j=0;j<3;++j) length+=(double)value.normal[j]*value.normal[j];
            length=sqrt(length);
            if (length>0) for (unsigned j=0;j<3;++j) value.normal[j]=(float)(value.normal[j]/length);
        }
        for (unsigned j=0;j<3;++j) if (!isfinite(value.position[j]) || !isfinite(value.normal[j])) {status=DC_RANGE;goto done;}
        result[i]=value;
    }
    memcpy(out,result,bytes);
done:
    free(result);return status;
}
