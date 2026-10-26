#include "dc_camera.h"
#include <math.h>
#include <string.h>

dc_status dc_camera_read_preset(const void *data, size_t length, uint32_t record,
        dc_camera_orbit *out) {
    if (!data || !out) return DC_ARGUMENT;
    if (length!=28 && length!=252) return DC_FORMAT;
    if (record>=length/28) return DC_RANGE;
    const uint8_t *bytes=data;
    float values[63];
    for (size_t i=0;i<length/4;++i) {
        uint32_t bits=(uint32_t)bytes[i*4] | (uint32_t)bytes[i*4+1]<<8 |
            (uint32_t)bytes[i*4+2]<<16 | (uint32_t)bytes[i*4+3]<<24;
        memcpy(&values[i],&bits,4);
        if (!isfinite(values[i])) return DC_RANGE;
    }
    const float *p=values+record*7;
    dc_camera_orbit result={{{1,0,0,0, 0,1,0,0, 0,0,1,0, p[4],p[5],p[6],1}},
        p[1],p[0],p[2],p[3]};
    *out=result;
    return DC_OK;
}

dc_status dc_matrix_inverse_affine(const dc_matrix *source, dc_matrix *out) {
    if(!source||!out)return DC_ARGUMENT;
    for(unsigned j=0;j<16;++j)if(!isfinite(source->values[j]))return DC_RANGE;
    const float *m=source->values;
    if (m[3]!=0 || m[7]!=0 || m[11]!=0 || m[15]!=1) return DC_FORMAT;
    double a=m[0], b=m[1], c=m[2], d=m[4], e=m[5], f=m[6],
        g=m[8], h=m[9], i=m[10];
    double cof[9]={e*i-f*h, c*h-b*i, b*f-c*e,
        f*g-d*i, a*i-c*g, c*d-a*f,
        d*h-e*g, b*g-a*h, a*e-b*d};
    double det=a*cof[0]+b*cof[3]+c*cof[6];
    if (!isfinite(det) || det==0) return DC_RANGE;
    dc_matrix result={{0}};
    for (unsigned r=0;r<3;++r) for (unsigned col=0;col<3;++col)
        result.values[r*4+col]=(float)(cof[r*3+col]/det);
    for (unsigned col=0;col<3;++col) {
        double sum=0;
        for (unsigned r=0;r<3;++r) sum-=(double)m[12+r]*result.values[r*4+col];
        result.values[12+col]=(float)sum;
    }
    result.values[15]=1;
    for (unsigned j=0;j<16;++j) if (!isfinite(result.values[j])) return DC_RANGE;
    *out=result;
    return DC_OK;
}

dc_status dc_camera_build(const dc_camera_orbit *orbit, const dc_camera_lens *lens,
        dc_camera_matrices *out) {
    if (!orbit || !lens || !out) return DC_ARGUMENT;
    if (!isfinite(orbit->stored_distance) || !isfinite(orbit->height) ||
        !isfinite(orbit->pitch) || !isfinite(orbit->yaw) ||
        !isfinite(lens->fov_y) || !isfinite(lens->near_z) || !isfinite(lens->far_z) ||
        lens->fov_y<=0 || (double)lens->fov_y>=3.14159265358979323846 ||
        lens->near_z<=0 || lens->far_z<=lens->near_z ||
        !lens->viewport_width || !lens->viewport_height) return DC_RANGE;
    for (unsigned j=0;j<16;++j) if (!isfinite(orbit->base.values[j])) return DC_RANGE;
    if (orbit->base.values[3]!=0 || orbit->base.values[7]!=0 ||
        orbit->base.values[11]!=0 || orbit->base.values[15]!=1) return DC_FORMAT;
    float sx=sinf(orbit->pitch), cx=cosf(orbit->pitch),
        sy=sinf(orbit->yaw), cy=cosf(orbit->yaw);
    dc_matrix rx={{1,0,0,0, 0,cx,sx,0, 0,-sx,cx,0, 0,0,0,1}},
        ry={{cy,0,-sy,0, 0,1,0,0, sy,0,cy,0, 0,0,0,1}},
        tz={{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,-orbit->stored_distance,1}},
        ty={{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,orbit->height,0,1}}, rotation, translated, lifted;
    dc_camera_matrices result;
    dc_status status=dc_matrix_multiply(&rx,&ry,&rotation);
    if (status==DC_OK) status=dc_matrix_multiply(&tz,&rotation,&translated);
    if (status==DC_OK) status=dc_matrix_multiply(&translated,&ty,&lifted);
    if (status==DC_OK) status=dc_matrix_multiply(&lifted,&orbit->base,&result.world);
    if (status==DC_OK) status=dc_matrix_inverse_affine(&result.world,&result.view);
    if (status!=DC_OK) return status;
    float aspect=(float)((double)lens->viewport_width/lens->viewport_height);
    float ys=(float)(1.0/tan((double)lens->fov_y*.5));
    float zs=lens->far_z/(lens->near_z-lens->far_z);
    result.projection=(dc_matrix){{ys/aspect,0,0,0, 0,ys,0,0, 0,0,zs,-1,
        0,0,lens->near_z*zs,0}};
    status=dc_matrix_multiply(&result.view,&result.projection,&result.view_projection);
    if (status==DC_OK) *out=result;
    return status;
}
