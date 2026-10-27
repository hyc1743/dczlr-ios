#include "dc_morph.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct morph_index {
    const uint8_t *name;
    size_t name_length;
    uint16_t *destination,*source;
    uint32_t count,max_source;
    uint8_t selector;
} morph_index;
typedef struct morph_vector {
    const uint8_t *name,*positions,*normals;
    size_t name_length;
    uint32_t count;
} morph_vector;
typedef struct morph_key {
    int32_t frame;
    uint32_t vector;
    uint8_t flag,weight;
} morph_key;
typedef struct morph_track {
    uint32_t type,mesh,index,key_count;
    morph_key *keys;
    uint32_t vectors[3];
    float manual_frame,weights[2];
    uint8_t enabled,manual_mode;
} morph_track;
struct dc_morph {
    const void *source_xx,*source_xa;
    size_t xx_length,xa_length;
    dc_morph_info info;
    dc_morph_controls controls;
    uint32_t *mesh_counts;
    morph_index *indices;
    morph_vector *vectors;
    morph_track *tracks;
};
typedef struct morph_write { uint32_t mesh,vertex;float position[3],normal[3]; } morph_write;
typedef struct morph_sample { uint32_t vectors[4];float factor,blend;uint8_t mode; } morph_sample;

static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
static uint32_t word(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static float real(const uint8_t *p) { uint32_t bits=word(p);float value;memcpy(&value,&bits,4);return value; }
static uint16_t half(const uint8_t *p) { return (uint16_t)((uint32_t)p[0]|(uint32_t)p[1]<<8); }
static int named_length(const uint8_t *p,size_t length,size_t *out) {
    for(size_t i=0;i<length;++i)if(p[i]==255){*out=i;return 1;}
    return 0;
}
static int same_name(const uint8_t *a,size_t al,const uint8_t *b,size_t bl) {
    return al==bl && !memcmp(a,b,al);
}
static int protected_span(const dc_morph *m,const void *out,size_t length) {
    if(overlap(m,sizeof(*m),out,length)||overlap(m->source_xx,m->xx_length,out,length)||
       overlap(m->source_xa,m->xa_length,out,length)||
       overlap(m->mesh_counts,(size_t)m->info.meshes*sizeof(*m->mesh_counts),out,length)||
       overlap(m->indices,(size_t)m->info.index_sets*sizeof(*m->indices),out,length)||
       overlap(m->vectors,(size_t)m->info.vector_sets*sizeof(*m->vectors),out,length)||
       overlap(m->tracks,(size_t)m->info.tracks*sizeof(*m->tracks),out,length))return 1;
    for(uint32_t i=0;i<m->info.index_sets;++i) {
        size_t bytes=(size_t)m->indices[i].count*sizeof(uint16_t);
        if(overlap(m->indices[i].source,bytes,out,length)||overlap(m->indices[i].destination,bytes,out,length))return 1;
    }
    for(uint32_t i=0;i<m->info.tracks;++i)
        if(overlap(m->tracks[i].keys,(size_t)m->tracks[i].key_count*sizeof(morph_key),out,length))return 1;
    return 0;
}
static int controls_valid(const dc_morph_controls *c) {
    const float values[]={c->mouth.blend,c->eyes.blend,c->mouth_phase,c->left_phase,c->right_phase,
        c->eye_min,c->eye_max,c->mouth_min,c->mouth_max};
    for(size_t i=0;i<sizeof(values)/sizeof(values[0]);++i)if(!isfinite(values[i]))return 0;
    return c->mouth.state<=2 && c->eyes.state<=2 && c->eye_min<=c->eye_max &&
        c->mouth_min<=c->mouth_max && c->scheduler_mode<=3 && c->link_eyes<=1;
}
dc_status dc_morph_reset_controls(dc_morph *m) {
    if(!m)return DC_ARGUMENT;
    m->controls.eye_max=m->controls.mouth_max=9;
    m->controls.eye_min=m->controls.mouth_min=0;
    m->controls.scheduler_mode=0;m->controls.link_eyes=1;return DC_OK;
}
void dc_morph_close(dc_morph *m) {
    if(!m)return;
    if(m->indices)for(uint32_t i=0;i<m->info.index_sets;++i){free(m->indices[i].destination);free(m->indices[i].source);}
    if(m->tracks)for(uint32_t i=0;i<m->info.tracks;++i)free(m->tracks[i].keys);
    free(m->mesh_counts);free(m->indices);free(m->vectors);free(m->tracks);free(m);
}
static uint32_t find_vector(const dc_morph *m,const uint8_t *name,size_t length) {
    for(uint32_t i=0;i<m->info.vector_sets;++i)
        if(same_name(name,length,m->vectors[i].name,m->vectors[i].name_length))return i;
    return DC_MORPH_NO_TARGET;
}
static dc_status vector_fits(const dc_morph *m,const morph_track *t,uint32_t vector) {
    if(vector==DC_MORPH_NO_TARGET || t->index==DC_MORPH_NO_TARGET || t->mesh==DC_MORPH_NO_TARGET)return DC_OK;
    if(vector>=m->info.vector_sets)return DC_RANGE;
    const morph_index *index=&m->indices[t->index];
    return index->count && index->max_source>=m->vectors[vector].count ? DC_RANGE : DC_OK;
}
dc_status dc_morph_open(const dc_xx *xx,const void *xx_bytes,size_t xx_length,
        const void *xa_bytes,size_t xa_length,dc_morph **out) {
    if(!xx||!xx_bytes||!xa_bytes||!out||overlap(xx_bytes,xx_length,out,sizeof(*out))||
       overlap(xa_bytes,xa_length,out,sizeof(*out)))return DC_ARGUMENT;
    *out=NULL;dc_xa_info xa;dc_xx_info info,source_info;
    dc_status status=dc_xa_probe(xa_bytes,xa_length,&xa);if(status!=DC_OK)return status;
    status=dc_xx_get_info(xx,&info);if(status!=DC_OK)return status;
    status=dc_xx_probe(xx_bytes,xx_length,&source_info);if(status!=DC_OK)return status;
    if(info.nodes!=source_info.nodes||info.submeshes!=source_info.submeshes||info.parsed_bytes!=source_info.parsed_bytes)return DC_ARGUMENT;
    if(xa.morph_tracks>DC_MORPH_TRACK_LIMIT||xa.morph_index_sets>DC_MORPH_TRACK_LIMIT||
       xa.morph_vector_sets>DC_MORPH_ELEMENT_LIMIT)return DC_RANGE;
    dc_morph *m=calloc(1,sizeof(*m));if(!m)return DC_MEMORY;
    m->source_xx=xx_bytes;m->xx_length=xx_length;m->source_xa=xa_bytes;m->xa_length=xa_length;
    m->info=(dc_morph_info){xa.morph_tracks,xa.morph_index_sets,xa.morph_vector_sets,info.submeshes,1};
    m->indices=calloc(xa.morph_index_sets?xa.morph_index_sets:1,sizeof(*m->indices));
    m->vectors=calloc(xa.morph_vector_sets?xa.morph_vector_sets:1,sizeof(*m->vectors));
    m->tracks=calloc(xa.morph_tracks?xa.morph_tracks:1,sizeof(*m->tracks));
    m->mesh_counts=calloc(info.submeshes?info.submeshes:1,sizeof(*m->mesh_counts));
    if(!m->indices||!m->vectors||!m->tracks||!m->mesh_counts){status=DC_MEMORY;goto failed;}
    for(uint32_t i=0;i<info.submeshes;++i){dc_xx_submesh mesh;status=dc_xx_submesh_at(xx,i,&mesh);if(status!=DC_OK)goto failed;
        if(mesh.vertex_count>DC_MORPH_ELEMENT_LIMIT){status=DC_RANGE;goto failed;}m->mesh_counts[i]=mesh.vertex_count;}
    const uint8_t *bytes=xa_bytes;size_t total_indices=0,total_keys=0;
    for(uint32_t i=0;i<xa.morph_index_sets;++i) {
        dc_xa_morph_index_set view;status=dc_xa_morph_index_set_at(bytes,xa_length,i,&view);if(status!=DC_OK)goto failed;
        morph_index *index=&m->indices[i];index->count=view.count;index->selector=view.selector;
        index->name=bytes+view.data_offset;
        if(!named_length(index->name,view.data_length,&index->name_length)){status=DC_FORMAT;goto failed;}
        if(view.count>DC_MORPH_ELEMENT_LIMIT-total_indices){status=DC_RANGE;goto failed;}total_indices+=view.count;
        index->destination=calloc(view.count?view.count:1,sizeof(uint16_t));index->source=calloc(view.count?view.count:1,sizeof(uint16_t));
        if(!index->destination||!index->source){status=DC_MEMORY;goto failed;}
        for(uint32_t j=0;j<view.count;++j){index->destination[j]=half(bytes+view.indices_offset+(size_t)j*2);
            index->source[j]=half(bytes+view.indices_offset+(size_t)view.count*2+(size_t)j*2);
            if(index->source[j]>index->max_source)index->max_source=index->source[j];}
    }
    for(uint32_t i=0;i<xa.morph_vector_sets;++i) {
        dc_xa_morph_vector_set view;status=dc_xa_morph_vector_set_at(bytes,xa_length,i,&view);if(status!=DC_OK)goto failed;
        morph_vector *v=&m->vectors[i];v->name=bytes+view.data_offset;v->count=view.count;
        if(view.count>DC_MORPH_ELEMENT_LIMIT){status=DC_RANGE;goto failed;}
        if(!named_length(v->name,view.data_length,&v->name_length)){status=DC_FORMAT;goto failed;}
        v->positions=bytes+view.vectors_offset;v->normals=v->positions+(size_t)v->count*12;
        for(size_t j=0;j<(size_t)v->count*6;++j)if(!isfinite(real(v->positions+j*4))){status=DC_RANGE;goto failed;}
    }
    for(uint32_t i=0;i<xa.morph_tracks;++i) {
        dc_xa_morph_track view;status=dc_xa_morph_track_at(bytes,xa_length,i,&view);if(status!=DC_OK)goto failed;
        morph_track *t=&m->tracks[i];t->type=word(bytes+view.tail_offset);t->mesh=t->index=DC_MORPH_NO_TARGET;
        t->key_count=view.key_count;t->enabled=1;for(unsigned j=0;j<3;++j)t->vectors[j]=DC_MORPH_NO_TARGET;
        size_t index_length,node_length;
        if(!named_length(bytes+view.target_offset,view.target_length,&index_length)||
           !named_length(bytes+view.name_offset,view.name_length,&node_length)){status=DC_FORMAT;goto failed;}
        for(uint32_t j=0;j<xa.morph_index_sets;++j)if(same_name(bytes+view.target_offset,index_length,m->indices[j].name,m->indices[j].name_length)){t->index=j;break;}
        if(t->index!=DC_MORPH_NO_TARGET) {
            status=dc_xx_morph_mesh(xx,bytes+view.name_offset,view.name_length,m->indices[t->index].selector,&t->mesh);
            if(status==DC_NOT_FOUND){t->mesh=DC_MORPH_NO_TARGET;status=DC_OK;}else if(status!=DC_OK)goto failed;
        }
        (void)node_length;
        if(t->mesh!=DC_MORPH_NO_TARGET) {
            if(t->type!=0&&t->type!=1&&t->type!=3&&t->type!=4&&t->type!=5){status=DC_FORMAT;goto failed;}
            const morph_index *index=&m->indices[t->index];
            for(uint32_t j=0;j<index->count;++j)if(index->destination[j]>=m->mesh_counts[t->mesh]){status=DC_RANGE;goto failed;}
        }
        if(view.key_count>DC_MORPH_ELEMENT_LIMIT-total_keys){status=DC_RANGE;goto failed;}total_keys+=view.key_count;
        t->keys=calloc(view.key_count?view.key_count:1,sizeof(*t->keys));if(!t->keys){status=DC_MEMORY;goto failed;}
        for(uint32_t j=0;j<view.key_count;++j) {
            dc_xa_morph_key key;status=dc_xa_morph_key_at(bytes,xa_length,i,j,&key);if(status!=DC_OK)goto failed;
            uint32_t bits=word(key.raw+1);memcpy(&t->keys[j].frame,&bits,4);t->keys[j].flag=key.raw[0];t->keys[j].weight=key.raw[5];
            size_t length;if(!named_length(bytes+key.value_offset,key.value_length,&length)){status=DC_FORMAT;goto failed;}
            t->keys[j].vector=find_vector(m,bytes+key.value_offset,length);
            status=vector_fits(m,t,t->keys[j].vector);if(status!=DC_OK)goto failed;
        }
    }
    dc_morph_reset_controls(m);*out=m;return DC_OK;
failed:dc_morph_close(m);return status;
}
dc_status dc_morph_get_info(const dc_morph *m,dc_morph_info *out) {
    if(!m||!out||protected_span(m,out,sizeof(*out)))return DC_ARGUMENT;*out=m->info;return DC_OK;
}
dc_status dc_morph_get_track_info(const dc_morph *m,uint32_t track,dc_morph_track_info *out) {
    if(!m||!out||protected_span(m,out,sizeof(*out)))return DC_ARGUMENT;if(track>=m->info.tracks)return DC_RANGE;
    const morph_track *t=&m->tracks[track];
    *out=(dc_morph_track_info){t->type,t->mesh,t->index,t->key_count,t->index==DC_MORPH_NO_TARGET?0:m->indices[t->index].count,t->enabled,t->manual_mode,{0,0}};
    return DC_OK;
}
dc_status dc_morph_get_controls(const dc_morph *m,dc_morph_controls *out) {
    if(!m||!out||protected_span(m,out,sizeof(*out)))return DC_ARGUMENT;*out=m->controls;return DC_OK;
}
dc_status dc_morph_set_controls(dc_morph *m,const dc_morph_controls *controls) {
    if(!m||!controls)return DC_ARGUMENT;dc_morph_controls next=*controls;
    if(!controls_valid(&next))return DC_RANGE;m->controls=next;return DC_OK;
}
dc_status dc_morph_set_track_enabled(dc_morph *m,uint32_t track,uint32_t enabled) {
    if(!m)return DC_ARGUMENT;if(track>=m->info.tracks||enabled>1)return DC_RANGE;m->tracks[track].enabled=(uint8_t)enabled;return DC_OK;
}
dc_status dc_morph_set_manual_frame(dc_morph *m,uint32_t track,float frame) {
    if(!m)return DC_ARGUMENT;if(track>=m->info.tracks||!isfinite(frame))return DC_RANGE;
    if(m->tracks[track].type!=1)return DC_FORMAT;m->tracks[track].manual_frame=frame;m->tracks[track].manual_mode=0;return DC_OK;
}
dc_status dc_morph_set_three_vectors(dc_morph *m,uint32_t track,const uint32_t vectors[3],const float weights[2]) {
    if(!m||!vectors||!weights)return DC_ARGUMENT;if(track>=m->info.tracks)return DC_RANGE;
    morph_track next=m->tracks[track];if(next.type!=1)return DC_FORMAT;
    for(unsigned i=0;i<2;++i){if(!isfinite(weights[i]))return DC_RANGE;next.weights[i]=weights[i];}
    for(unsigned i=0;i<3;++i){if(vectors[i]!=DC_MORPH_NO_TARGET&&vectors[i]>=m->info.vector_sets)return DC_RANGE;
        dc_status status=vector_fits(m,&next,vectors[i]);if(status!=DC_OK)return status;next.vectors[i]=vectors[i];}
    next.manual_mode=1;m->tracks[track]=next;return DC_OK;
}
dc_status dc_morph_find_vector_encoded(const dc_morph *m,const void *name,size_t length,uint32_t *out) {
    if(!m||!name||!out||protected_span(m,out,sizeof(*out)))return DC_ARGUMENT;
    size_t n;if(!named_length(name,length,&n))return DC_FORMAT;uint32_t index=find_vector(m,name,n);
    if(index==DC_MORPH_NO_TARGET)return DC_NOT_FOUND;*out=index;return DC_OK;
}
static uint32_t interval(const morph_track *t,float frame,int inclusive) {
    for(uint32_t i=0;i+1<t->key_count;++i)
        if((float)t->keys[i].frame<=frame && (inclusive ? frame<=(float)t->keys[i+1].frame : frame<(float)t->keys[i+1].frame))return i;
    return DC_MORPH_NO_TARGET;
}
static float expression_frame(int32_t expression,float phase) {
    uint32_t bits=(uint32_t)expression*10u;int32_t value;memcpy(&value,&bits,4);
    return (float)((double)(float)value+phase);
}
static dc_status select_sample(const morph_track *t,dc_morph_controls *controls,float frame,morph_sample *sample,int *active) {
    *active=0;memset(sample,0,sizeof(*sample));
    if(t->type==1&&t->manual_mode==1){sample->mode=2;sample->factor=t->weights[0];sample->blend=t->weights[1];
        for(unsigned i=0;i<3;++i){sample->vectors[i]=t->vectors[i];if(t->vectors[i]==DC_MORPH_NO_TARGET)return DC_OK;}
        *active=1;return DC_OK;}
    const dc_morph_expression *group=NULL;int inclusive=1;
    if(t->type==1)frame=t->manual_frame;
    else if(t->type==3||t->type==4||t->type==5) {
        float *phase=t->type==3?&controls->left_phase:(t->type==4?&controls->right_phase:&controls->mouth_phase);
        float low=t->type==5?controls->mouth_min:controls->eye_min,high=t->type==5?controls->mouth_max:controls->eye_max;
        if(*phase>high)*phase=high;else if(*phase<low)*phase=low;
        group=t->type==5?&controls->mouth:&controls->eyes;frame=expression_frame(group->current,*phase);inclusive=0;
    }
    if(!isfinite(frame))return DC_RANGE;
    uint32_t left=interval(t,frame,inclusive);if(left==DC_MORPH_NO_TARGET)return DC_OK;
    uint32_t previous=left;
    if(group&&group->state){float phase=t->type==3?controls->left_phase:(t->type==4?controls->right_phase:controls->mouth_phase);
        float previous_frame=expression_frame(group->previous,phase);if(!isfinite(previous_frame))return DC_RANGE;
        previous=interval(t,previous_frame,0);if(previous==DC_MORPH_NO_TARGET)return DC_OK;}
    float span=(float)((double)t->keys[left+1].frame-t->keys[left].frame);
    sample->factor=(float)(((double)frame-(float)t->keys[left].frame)/span);
    if(!isfinite(sample->factor))return DC_RANGE;
    sample->vectors[0]=t->keys[left].vector;sample->vectors[1]=t->keys[left+1].vector;
    if(group&&group->state==2){sample->mode=1;sample->blend=group->blend;
        sample->vectors[2]=t->keys[previous].vector;sample->vectors[3]=t->keys[previous+1].vector;}
    unsigned n=sample->mode==1?4:2;for(unsigned i=0;i<n;++i)if(sample->vectors[i]==DC_MORPH_NO_TARGET)return DC_OK;
    *active=1;return DC_OK;
}
static float lerp(float left,float right,float factor) {
    volatile double difference=(double)right-left;volatile double product=difference*factor;return (float)(product+left);
}
static dc_status component(const dc_morph *m,const morph_sample *sample,uint32_t source,unsigned coordinate,int normal,float *out) {
    float values[4];unsigned n=sample->mode==1?4:(sample->mode==2?3:2);
    for(unsigned i=0;i<n;++i){const morph_vector *v=&m->vectors[sample->vectors[i]];
        values[i]=real((normal?v->normals:v->positions)+(size_t)source*12+coordinate*4);}
    float value=lerp(values[0],values[1],sample->factor);
    if(sample->mode==2)value=lerp(value,values[2],sample->blend);
    else if(sample->mode==1){float old=lerp(values[2],values[3],sample->factor);
        volatile double newer=(double)value*sample->blend;volatile double older=(1.0-(double)sample->blend)*old;value=(float)(newer+older);}
    if(!isfinite(value))return DC_RANGE;*out=value;return DC_OK;
}
static void advance_expression(dc_morph_expression *group,uint32_t now) {
    if(group->blend>=1){group->state=0;return;}
    if(now<group->blend_end){uint32_t span=group->blend_end-group->blend_start,elapsed=now-group->blend_start;
        group->blend=span?(float)((double)(float)elapsed/(float)span):0;group->state=2;}
    else group->state=1;
}
static dc_status apply(dc_morph *m,float frame,uint32_t now,int advance,const dc_morph_mesh_buffer *buffers,size_t count) {
    if(!m||(count&&!buffers))return DC_ARGUMENT;
    if(!isfinite(frame))return DC_RANGE;if(count!=m->info.meshes)return DC_RANGE;
    if(protected_span(m,buffers,count*sizeof(*buffers)))return DC_ARGUMENT;
    for(size_t i=0;i<count;++i){const dc_morph_mesh_buffer *b=&buffers[i];
        if((!b->vertices&&b->count)||(b->vertices&&b->count!=m->mesh_counts[i]))return DC_RANGE;
        if(b->count>DC_MORPH_ELEMENT_LIMIT)return DC_RANGE;size_t bytes=b->count*sizeof(*b->vertices);
        if(protected_span(m,b->vertices,bytes)||overlap(buffers,count*sizeof(*buffers),b->vertices,bytes))return DC_ARGUMENT;
        for(size_t j=0;j<i;++j)if(overlap(buffers[j].vertices,buffers[j].count*sizeof(dc_mesh_vertex),b->vertices,bytes))return DC_ARGUMENT;}
    dc_morph_controls controls=m->controls;if(!controls_valid(&controls))return DC_RANGE;
    if(advance){advance_expression(&controls.mouth,now);advance_expression(&controls.eyes,now);if(!controls_valid(&controls))return DC_RANGE;}
    morph_sample *samples=calloc(m->info.tracks?m->info.tracks:1,sizeof(*samples));
    uint8_t *active=calloc(m->info.tracks?m->info.tracks:1,1);
    if(!samples||!active){free(samples);free(active);return DC_MEMORY;}
    size_t writes=0;dc_status status=DC_OK;
    for(uint32_t i=0;i<m->info.tracks;++i){const morph_track *t=&m->tracks[i];if(!t->enabled||t->mesh==DC_MORPH_NO_TARGET||t->index==DC_MORPH_NO_TARGET)continue;
        int selected=0;status=select_sample(t,&controls,frame,&samples[i],&selected);if(status!=DC_OK)goto failed;
        if(!selected)continue;const morph_index *index=&m->indices[t->index];
        if(index->count&&!buffers[t->mesh].vertices){status=DC_RANGE;goto failed;}
        if(index->count>DC_MORPH_ELEMENT_LIMIT-writes){status=DC_RANGE;goto failed;}writes+=index->count;active[i]=1;}
    morph_write *pending=calloc(writes?writes:1,sizeof(*pending));if(!pending){status=DC_MEMORY;goto failed;}
    size_t at=0;
    for(uint32_t i=0;i<m->info.tracks;++i)if(active[i]){const morph_track *t=&m->tracks[i];const morph_index *index=&m->indices[t->index];
        for(uint32_t j=0;j<index->count;++j){morph_write *write=&pending[at++];write->mesh=t->mesh;write->vertex=index->destination[j];
            for(unsigned k=0;k<3;++k){status=component(m,&samples[i],index->source[j],k,0,&write->position[k]);if(status!=DC_OK)goto pending_failed;
                status=component(m,&samples[i],index->source[j],k,1,&write->normal[k]);if(status!=DC_OK)goto pending_failed;}}}
    if(controls.mouth.state==1)controls.mouth.blend=1;if(controls.eyes.state==1)controls.eyes.blend=1;
    for(size_t i=0;i<writes;++i){morph_write *write=&pending[i];dc_mesh_vertex *out=&buffers[write->mesh].vertices[write->vertex];
        memcpy(out->position,write->position,sizeof(write->position));memcpy(out->normal,write->normal,sizeof(write->normal));}
    m->controls=controls;free(pending);free(samples);free(active);return DC_OK;
pending_failed:free(pending);
failed:free(samples);free(active);return status;
}
dc_status dc_morph_apply(dc_morph *m,float frame,const dc_morph_mesh_buffer *buffers,size_t count) { return apply(m,frame,0,0,buffers,count); }
dc_status dc_morph_tick(dc_morph *m,float frame,uint32_t now,const dc_morph_mesh_buffer *buffers,size_t count) { return apply(m,frame,now,1,buffers,count); }
