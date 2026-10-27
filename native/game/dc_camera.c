#include "dc_camera.h"
#include <math.h>
#include <string.h>
#include <stdio.h>

dc_status dc_camera_secondary_viewport(const dc_viewport *main,dc_viewport *out) {
    if(!main||!out)return DC_ARGUMENT;
    const float values[]={main->x,main->y,main->width,main->height,main->min_z,main->max_z};
    for(unsigned i=0;i<6;++i)if(!isfinite(values[i]))return DC_RANGE;
    if(main->x<0||main->y<0||main->width<=0||main->height<=0)return DC_RANGE;
    float scale=main->width/1024.f;
    double y=504.*scale,w=352.*scale,h=264.*scale;
    if(y>=4294967296.||w>=4294967296.||h>=4294967296.||w<1||h<1)return DC_RANGE;
    dc_viewport next={main->x,main->y+(float)(uint32_t)y,(float)(uint32_t)w,(float)(uint32_t)h,0,1};
    if(next.width>main->width||next.y+next.height>main->y+main->height)return DC_RANGE;
    *out=next;return DC_OK;
}

dc_status dc_camera_secondary_pointer(const dc_camera_orbit *source,
        const dc_camera_pointer_limits *limits,const dc_camera_pointer_input *in,dc_camera_orbit *out) {
    if(!source||!limits||!in||!out)return DC_ARGUMENT;
    if(in->left>3||in->right>3||in->middle>3||in->fast>1)return DC_RANGE;
    const float bounds[]={limits->far_distance,limits->near_distance,limits->high,limits->low,limits->wheel_step};
    for(unsigned i=0;i<5;++i)if(!isfinite(bounds[i]))return DC_RANGE;
    if(limits->near_distance<=0||limits->far_distance<limits->near_distance||limits->high<limits->low||limits->wheel_step<0)return DC_RANGE;
    dc_camera_matrices camera;dc_camera_lens lens={.3f,.5f,10000,1024,768};
    dc_status status=dc_camera_build(source,&lens,&camera);if(status!=DC_OK)return status;
    dc_camera_orbit next=*source;double speed=in->fast?2.:1.;
    int operation=(in->left&1)?((in->right&1)?2:0):((in->right&1)?1:((in->middle&1)?2:(in->wheel?3:-1)));
    if(operation==0) {
        next.pitch=(float)((double)next.pitch-(double)in->dy*.01f*speed);
        next.yaw=(float)((double)next.yaw-(double)in->dx*.01f*speed);
        float *angles[]={&next.pitch,&next.yaw};
        for(unsigned i=0;i<2;++i) {
            if(*angles[i]<0)*angles[i]+=6.2831854820251465f;
            else if(*angles[i]>6.2831854820251465f)*angles[i]-=6.2831854820251465f;
        }
    } else if(operation==1) {
        next.stored_distance=(float)((double)next.stored_distance-(double)in->dx*.1f*speed);
        next.height=(float)((double)next.height-(double)in->dy*.1f*speed);
        if(next.stored_distance>-limits->near_distance)next.stored_distance=-limits->near_distance;
        else if(next.stored_distance<-limits->far_distance)next.stored_distance=-limits->far_distance;
        if(next.height<limits->low)next.height=limits->low;
        else if(next.height>limits->high)next.height=limits->high;
    } else if(operation==2||operation==3) {
        float x=operation==2?(float)((double)in->dx*.1f*speed):0;
        float z=operation==2?(float)((double)in->dy*.1f*speed):(float)((in->wheel>0?-1.:1.)*limits->wheel_step*speed);
        for(unsigned i=0;i<3;++i) {
            float movement=(float)((double)x*camera.world.values[i]+(double)z*camera.world.values[8+i]);
            float value=next.base.values[12+i]+movement;
            next.base.values[12+i]=fmaxf(-50,fminf(50,value));
        }
    }
    *out=next;return DC_OK;
}

dc_status dc_camera_scene_node(uint32_t stage,uint32_t binding,char *out,size_t capacity) {
    if(!out)return DC_ARGUMENT;
    if(stage>2||binding>3)return DC_RANGE;
    const char *suffix=binding==0?"_On_namida":"_Kn_kosi";
    char name[32];
    int n=binding<2?snprintf(name,sizeof(name),"%c%s","bca"[stage],suffix):
        snprintf(name,sizeof(name),"%s",binding==2?"z_Nz_light":"z_Nz_cam");
    if(n<0||(size_t)n>=capacity)return DC_RANGE;
    memcpy(out,name,(size_t)n+1);return DC_OK;
}

static int normalize3(float *v) {
    float length=sqrtf(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
    if(!isfinite(length)||length==0)return 0;
    for(unsigned i=0;i<3;++i)v[i]/=length;
    return 1;
}
static void cross3(const float *a,const float *b,float *out) {
    float value[3]={a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]};
    memcpy(out,value,sizeof(value));
}
dc_status dc_camera_look_at(const dc_matrix *source,const dc_matrix *target,dc_matrix *out) {
    if(!source||!target||!out)return DC_ARGUMENT;
    for(unsigned i=0;i<16;++i)if(!isfinite(source->values[i])||!isfinite(target->values[i]))return DC_RANGE;
    if(source->values[3]!=0||source->values[7]!=0||source->values[11]!=0||source->values[15]!=1||
       target->values[3]!=0||target->values[7]!=0||target->values[11]!=0||target->values[15]!=1)return DC_FORMAT;
    dc_matrix next=*source;
    float back[3],right[3],up[3]={0,1,0};
    for(unsigned i=0;i<3;++i)back[i]=target->values[12+i]-source->values[12+i];
    if(!normalize3(back))return DC_RANGE;
    for(unsigned i=0;i<3;++i)back[i]*=-1;
    cross3(up,back,right);if(!normalize3(right))return DC_RANGE;
    cross3(back,right,up);if(!normalize3(up))return DC_RANGE;
    for(unsigned i=0;i<3;++i){next.values[i]=right[i];next.values[4+i]=up[i];next.values[8+i]=back[i];}
    *out=next;return DC_OK;
}

dc_status dc_camera_scene_resource(uint32_t type,uint32_t map,uint32_t stage,char *out,size_t capacity) {
    if(!out)return DC_ARGUMENT;
    if(stage>2||map>8||map==2)return DC_RANGE;
    if(type<4||type>6)return DC_NOT_FOUND;
    static const char *prefix[]={"home_","trai_",NULL,"toil_","hote_","roji_","park_","park_","mana_"};
    static const char *night[]={"tb.cam","tc.cam","ta.cam"};
    const char *suffix=type==4?"sh.cam":(type==5?"ch.cam":night[stage]);
    char result[32];int n=snprintf(result,sizeof(result),"%s%s",prefix[map],suffix);
    if(n<0||(size_t)n>=capacity)return DC_RANGE;
    memcpy(out,result,(size_t)n+1);return DC_OK;
}

static float point_distance(const float *a,const float *b) {
    float x=a[0]-b[0],y=a[1]-b[1],z=a[2]-b[2];
    return sqrtf(x*x+y*y+z*z);
}
static dc_status point_angle(const float *a,const float *origin,const float *b,float *out) {
    float u[3],v[3];for(unsigned i=0;i<3;++i){u[i]=a[i]-origin[i];v[i]=b[i]-origin[i];}
    float ul=sqrtf(u[0]*u[0]+u[1]*u[1]+u[2]*u[2]),vl=sqrtf(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
    if(ul==0||vl==0){*out=0;return DC_OK;}
    float cosine=(u[0]*v[0]+u[1]*v[1]+u[2]*v[2])/(ul*vl);
    *out=acosf(fmaxf(-1,fminf(1,cosine)))*57.29577951308232f;return DC_OK;
}
dc_status dc_camera_retarget(const dc_camera_orbit *source,const dc_matrix *target,uint32_t primary,dc_camera_orbit *out) {
    if(!source||!target||!out)return DC_ARGUMENT;
    if(primary>1)return DC_RANGE;
    for(unsigned i=0;i<16;++i)if(!isfinite(target->values[i]))return DC_RANGE;
    if(target->values[3]!=0||target->values[7]!=0||target->values[11]!=0||target->values[15]!=1)return DC_FORMAT;
    dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices matrices;
    dc_status status=dc_camera_build(source,&lens,&matrices);if(status!=DC_OK)return status;
    dc_camera_orbit result=*source;
    float pivot[3],eye[3],point[3],flatEye[3],flatTarget[3],flatPivot[3];
    for(unsigned i=0;i<3;++i) {
        pivot[i]=source->base.values[12+i]+(primary?source->height*source->base.values[4+i]:0);
        eye[i]=matrices.world.values[12+i];
        flatEye[i]=i==1?0:eye[i];flatTarget[i]=i==1?0:target->values[12+i];flatPivot[i]=i==1?0:pivot[i];
    }
    const float *targetPoint=&target->values[12];
    result.stored_distance=-point_distance(eye,targetPoint);
    float distance=point_distance(pivot,targetPoint);
    if(distance>1) {
        const float radians=.01745329238474369f;
        float yawAngles[2],sideDistances[2];
        for(unsigned probe=0;probe<2;++probe) {
            float angle=probe?-radians:radians,c=cosf(angle),s=sinf(angle);
            float x=matrices.world.values[8],z=matrices.world.values[10];
            point[0]=eye[0]+(x*c+z*s)*.01f;point[1]=0;
            point[2]=eye[2]+(-x*s+z*c)*.01f;
            if(point_angle(point,flatEye,flatTarget,&yawAngles[probe])!=DC_OK)return DC_RANGE;
            for(unsigned i=0;i<3;++i)point[i]=eye[i]+(probe?-1.f:1.f)*matrices.world.values[i];
            sideDistances[probe]=point_distance(point,targetPoint);
        }
        float yawCorrection=sideDistances[1]>sideDistances[0]?180.f-yawAngles[0]:
            (sideDistances[1]<sideDistances[0]?-(180.f-yawAngles[1]):0.f);
        if(!primary||point_distance(flatPivot,flatTarget)<point_distance(flatPivot,flatEye))
            result.yaw-=yawCorrection*radians;
        float pitchCorrection=0;
        if(point_angle(pivot,eye,targetPoint,&pitchCorrection)!=DC_OK)return DC_RANGE;
        if(primary) {
            if(targetPoint[1]>pivot[1])pitchCorrection=-pitchCorrection;
            else if(targetPoint[1]==pivot[1])pitchCorrection=0;
        } else {
            if(eye[1]>pivot[1])pitchCorrection=-pitchCorrection;
            else if(eye[1]==pivot[1])pitchCorrection=0;
        }
        result.pitch-=pitchCorrection*radians;
    }
    result.height=0;
    for(unsigned i=0;i<3;++i)result.base.values[12+i]=targetPoint[i];
    if(!isfinite(result.stored_distance)||!isfinite(result.pitch)||!isfinite(result.yaw))return DC_RANGE;
    *out=result;return DC_OK;
}

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
