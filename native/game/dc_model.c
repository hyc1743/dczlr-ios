#include "dc_model.h"
#include <stdlib.h>
#include <string.h>

typedef struct pose_track { uint32_t target,mode,count; dc_pose_key *keys; } pose_track;
typedef struct material_track { uint32_t target,count; dc_material_key *keys; dc_material_value baseline; } material_track;
typedef struct mesh_data { dc_xx_submesh info; dc_mesh_vertex *vertices; uint16_t *indices; } mesh_data;
struct dc_model {
    const void *source_xx,*source_xa;
    size_t xx_length,xa_length;
    dc_xx *xx;
    dc_xx_info info;
    dc_xa_info xa_info;
    dc_animation_state animation;
    dc_animation_clip clips[512];
    dc_animation_timing timing[512];
    dc_scene_node *nodes,*scratch_nodes;
    dc_matrix *globals,*scratch_globals;
    dc_material_value *materials,*scratch_materials;
    pose_track *poses;
    material_track *tracks;
    mesh_data *meshes;
};
static int overlap(const void *a,size_t al,const void *b,size_t bl) {
    uintptr_t aa=(uintptr_t)a,bb=(uintptr_t)b;
    return al && bl && (aa<=bb ? bb-aa<al : aa-bb<bl);
}
static int output_allowed(const dc_model *m,const void *out,size_t length) {
    return out && !overlap(m->source_xx,m->xx_length,out,length) && !overlap(m->source_xa,m->xa_length,out,length);
}
static dc_matrix identity(void) { return (dc_matrix){{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}}; }
void dc_model_close(dc_model *m) {
    if (!m) return;
    if (m->poses) for (uint32_t i=0;i<m->xa_info.bone_tracks;++i) free(m->poses[i].keys);
    if (m->tracks) for (uint32_t i=0;i<m->xa_info.material_tracks;++i) free(m->tracks[i].keys);
    if (m->meshes) for (uint32_t i=0;i<m->info.submeshes;++i) { free(m->meshes[i].vertices); free(m->meshes[i].indices); }
    free(m->nodes);free(m->scratch_nodes);free(m->globals);free(m->scratch_globals);
    free(m->materials);free(m->scratch_materials);free(m->poses);free(m->tracks);free(m->meshes);
    dc_xx_close(m->xx);free(m);
}
#define TRY(expr) do { status=(expr); if(status!=DC_OK) goto failed; } while(0)
#define ALLOC(field,count) do { m->field=calloc((count)?(count):1,sizeof(*m->field)); if(!m->field) {status=DC_MEMORY;goto failed;} } while(0)
dc_status dc_model_open(const void *xx,size_t xx_length,const void *xa,size_t xa_length,dc_model **out) {
    if (!out || overlap(xx,xx_length,out,sizeof(*out)) || overlap(xa,xa_length,out,sizeof(*out))) return DC_ARGUMENT;
    *out=NULL;
    dc_model *m=calloc(1,sizeof(*m));
    if (!m) return DC_MEMORY;
    dc_status status;
    m->source_xx=xx;m->source_xa=xa;m->xx_length=xx_length;m->xa_length=xa_length;
    TRY(dc_xx_open(xx,xx_length,&m->xx));
    TRY(dc_xx_get_info(m->xx,&m->info));TRY(dc_xa_probe(xa,xa_length,&m->xa_info));
    if (m->info.bones || m->xa_info.event_tracks || m->xa_info.morph_tracks ||
        m->xa_info.morph_index_sets || m->xa_info.morph_vector_sets || m->xa_info.bone_tracks>4096 || m->xa_info.material_tracks>4096) { status=DC_FORMAT;goto failed; }
    TRY(dc_xa_load_clips(xa,xa_length,m->clips,m->timing,512));
    ALLOC(nodes,m->info.nodes);ALLOC(scratch_nodes,m->info.nodes);
    ALLOC(globals,m->info.nodes);ALLOC(scratch_globals,m->info.nodes);
    ALLOC(materials,m->info.materials);ALLOC(scratch_materials,m->info.materials);
    ALLOC(poses,m->xa_info.bone_tracks);ALLOC(tracks,m->xa_info.material_tracks);ALLOC(meshes,m->info.submeshes);
    const uint8_t *source=xx,*animation=xa;
    for (uint32_t i=0;i<m->info.nodes;++i) {
        dc_xx_node node;TRY(dc_xx_node_at(m->xx,i,&node));
        m->nodes[i].parent=node.parent;m->nodes[i].extra=identity();
        TRY(dc_xx_node_matrix(m->xx,i,&m->nodes[i].local));
        m->nodes[i].billboard=source[node.matrix_offset+64];
        m->nodes[i].hidden=source[node.matrix_offset+116];
        m->globals[i]=identity();
    }
    m->nodes[0].local=identity();
    for (uint32_t i=0;i<m->info.materials;++i) TRY(dc_xx_material_baseline(m->xx,i,&m->materials[i]));
    for (uint32_t i=0;i<m->xa_info.bone_tracks;++i) {
        dc_xa_pose_track track;TRY(dc_xa_pose_track_at(xa,xa_length,i,&track));
        pose_track *p=&m->poses[i];p->target=UINT32_MAX;p->count=track.key_count;p->mode=track.mode;
        status=dc_xx_find_node_encoded(m->xx,animation+track.name_offset,track.name_length,&p->target);
        if (status!=DC_OK && status!=DC_NOT_FOUND) goto failed;
        if (track.key_count>DC_POSE_KEY_LIMIT || (p->target!=UINT32_MAX && (track.mode || track.key_count<2))) {status=DC_FORMAT;goto failed;}
        p->keys=calloc(track.key_count?track.key_count:1,sizeof(*p->keys));if(!p->keys) {status=DC_MEMORY;goto failed;}
        TRY(dc_xa_load_pose_keys(xa,xa_length,i,p->keys,track.key_count));
    }
    for (uint32_t i=0;i<m->xa_info.material_tracks;++i) {
        dc_xa_material_track track;TRY(dc_xa_material_track_at(xa,xa_length,i,&track));
        material_track *p=&m->tracks[i];p->target=UINT32_MAX;p->count=track.key_count;
        status=dc_xx_find_material_encoded(m->xx,animation+track.name_offset,track.name_length,&p->target);
        if (status!=DC_OK && status!=DC_NOT_FOUND) goto failed;
        if (p->target!=UINT32_MAX) p->baseline=m->materials[p->target];
        if (p->count>1048576) {status=DC_RANGE;goto failed;}
        p->keys=calloc(p->count?p->count:1,sizeof(*p->keys));if(!p->keys) {status=DC_MEMORY;goto failed;}
        TRY(dc_xa_load_material_keys(xa,xa_length,i,p->keys,p->count));
    }
    for (uint32_t i=0;i<m->info.submeshes;++i) {
        mesh_data *mesh=&m->meshes[i];TRY(dc_xx_submesh_at(m->xx,i,&mesh->info));
        if (mesh->info.material>=m->info.materials || mesh->info.vertex_count>1048576 || mesh->info.index_count>1048576) {status=DC_RANGE;goto failed;}
        mesh->vertices=calloc(mesh->info.vertex_count?mesh->info.vertex_count:1,sizeof(*mesh->vertices));
        mesh->indices=calloc(mesh->info.index_count?mesh->info.index_count:1,sizeof(*mesh->indices));
        if (!mesh->vertices || !mesh->indices) {status=DC_MEMORY;goto failed;}
        TRY(dc_xx_load_mesh_vertices(m->xx,i,mesh->vertices,mesh->info.vertex_count));
        TRY(dc_xx_load_mesh_indices(m->xx,i,mesh->indices,mesh->info.index_count));
    }
    m->animation.blend=1;
    TRY(dc_model_request(m,1,0));
    *out=m;return DC_OK;
failed:
    dc_model_close(m);return status;
}

dc_status dc_model_request(dc_model *m,uint32_t clip,uint32_t now) {
    if (!m) return DC_ARGUMENT;
    dc_animation_state state=m->animation;
    dc_animation_clip clips[512];memcpy(clips,m->clips,sizeof(clips));
    dc_status status=dc_animation_request(&state,clips,512,clip,0,now);
    if (status!=DC_OK) return status;
    if (state.blend<1) return DC_FORMAT;
    m->animation=state;memcpy(m->clips,clips,sizeof(clips));return DC_OK;
}
dc_status dc_model_query(const dc_model *m,uint32_t *clip,uint32_t *ready) {
    if (!m) return DC_ARGUMENT;
    if ((clip && !output_allowed(m,clip,sizeof(*clip))) || !output_allowed(m,ready,sizeof(*ready))) return DC_ARGUMENT;
    return dc_animation_query(&m->animation,m->clips,512,clip,ready);
}
dc_status dc_model_tick(dc_model *m,uint32_t delta,uint32_t now,const dc_matrix *world) {
    if (!m || !world) return DC_ARGUMENT;
    dc_animation_state state=m->animation;
    dc_animation_clip clips[512];memcpy(clips,m->clips,sizeof(clips));
    dc_animation_tick_result update;
    dc_status status=dc_animation_tick(&state,clips,m->timing,512,delta,1,now,&update);
    if (status!=DC_OK) return status;
    if (update.sample_count!=1 || state.blend<1) return DC_FORMAT;
    memcpy(m->scratch_nodes,m->nodes,m->info.nodes*sizeof(*m->nodes));
    memcpy(m->scratch_globals,m->globals,m->info.nodes*sizeof(*m->globals));
    memcpy(m->scratch_materials,m->materials,m->info.materials*sizeof(*m->materials));
    for (uint32_t i=0;i<m->xa_info.bone_tracks;++i) {
        pose_track *p=&m->poses[i];if(p->target==UINT32_MAX) continue;
        status=dc_pose_sample(p->keys,p->count,p->mode,update.samples[0],&m->scratch_nodes[p->target].local);
        if(status!=DC_OK) return status;
    }
    for (uint32_t i=0;i<m->xa_info.material_tracks;++i) {
        material_track *p=&m->tracks[i];if(p->target==UINT32_MAX) continue;
        status=dc_material_sample(p->keys,p->count,&p->baseline,state.frame,&m->scratch_materials[p->target]);
        if(status!=DC_OK) return status;
    }
    status=dc_scene_update(m->scratch_nodes,m->info.nodes,world,m->scratch_globals,m->info.nodes);
    if(status!=DC_OK) return status;
    memcpy(m->nodes,m->scratch_nodes,m->info.nodes*sizeof(*m->nodes));
    memcpy(m->globals,m->scratch_globals,m->info.nodes*sizeof(*m->globals));
    memcpy(m->materials,m->scratch_materials,m->info.materials*sizeof(*m->materials));
    m->animation=state;memcpy(m->clips,clips,sizeof(clips));return DC_OK;
}
dc_status dc_model_get_info(const dc_model *m,dc_xx_info *out) { if(!m||!output_allowed(m,out,sizeof(*out)))return DC_ARGUMENT;*out=m->info;return DC_OK; }
dc_status dc_model_material(const dc_model *m,uint32_t index,dc_material_value *out) {
    if(!m||!output_allowed(m,out,sizeof(*out)))return DC_ARGUMENT;if(index>=m->info.materials)return DC_RANGE;*out=m->materials[index];return DC_OK;
}
dc_status dc_model_global(const dc_model *m,uint32_t index,dc_matrix *out) {
    if(!m||!output_allowed(m,out,sizeof(*out)))return DC_ARGUMENT;if(index>=m->info.nodes)return DC_RANGE;*out=m->globals[index];return DC_OK;
}
dc_status dc_model_mesh(const dc_model *m,uint32_t index,dc_xx_submesh *out) {
    if(!m||!output_allowed(m,out,sizeof(*out)))return DC_ARGUMENT;if(index>=m->info.submeshes)return DC_RANGE;*out=m->meshes[index].info;return DC_OK;
}
dc_status dc_model_project(const dc_model *m,uint32_t mesh,const dc_matrix *vp,const dc_viewport *viewport,
        uint32_t diffuse,dc_sprite_vertex *out,size_t capacity) {
    if(!m||!vp)return DC_ARGUMENT;if(mesh>=m->info.submeshes)return DC_RANGE;
    const mesh_data *data=&m->meshes[mesh];dc_matrix mvp;
    if (!output_allowed(m,out,data->info.index_count*sizeof(*out))) return DC_ARGUMENT;
    dc_status status=dc_matrix_multiply(&m->globals[data->info.node],vp,&mvp);
    if(status!=DC_OK)return status;
    return dc_mesh_project(data->vertices,data->info.vertex_count,data->indices,data->info.index_count,&mvp,viewport,diffuse,out,capacity);
}
