#include "dc_model.h"
#include "dc_skin.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct pose_track { uint32_t target,mode,count; dc_pose_key *keys; } pose_track;
typedef struct material_track { uint32_t target,count; dc_material_key *keys; dc_material_value baseline; } material_track;
typedef struct event_track {
    uint32_t type,target,key_count;
    uint8_t enabled,reverse,filtered;
    uint32_t mesh_filter;
    float parameter;
} event_track;
typedef struct mesh_data {
    dc_xx_submesh info;
    dc_mesh_vertex *vertices,*deformed,*scratch_deformed;
    dc_mesh_vertex *event_vertices,*scratch_event_vertices;
    dc_xx_weights *weights;
    uint16_t *indices;
} mesh_data;
typedef struct skin_node {
    uint32_t count;
    dc_skin_bone *bones;
    dc_skin_palette *palette,*scratch_palette;
    uint8_t assigned[DC_SKIN_PALETTE_LIMIT];
} skin_node;
struct dc_model {
    const void *source_xx,*source_xa;
    size_t xx_length,xa_length;
    dc_xx *xx;
    dc_xx_info info;
    dc_xa_info xa_info;
    dc_animation_state animation;
    dc_animation_clip clips[512];
    dc_animation_timing timing[512];
    event_track *events;
    dc_scene_node *nodes,*scratch_nodes;
    uint8_t *render_hidden;
    dc_matrix *globals,*scratch_globals;
    dc_material_value *materials,*scratch_materials;
    pose_track *poses;
    material_track *tracks;
    mesh_data *meshes;
    uint32_t static_only;
    skin_node *skins;
};
dc_status dc_model_shift_clock(dc_model *model,uint32_t elapsed) {
    if(!model)return DC_ARGUMENT;
    model->animation.blend_start+=elapsed;model->animation.blend_end+=elapsed;
    return DC_OK;
}
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
    if (m->meshes) for (uint32_t i=0;i<m->info.submeshes;++i) {
        free(m->meshes[i].vertices);free(m->meshes[i].indices);free(m->meshes[i].weights);
        free(m->meshes[i].deformed);free(m->meshes[i].scratch_deformed);
        free(m->meshes[i].event_vertices);free(m->meshes[i].scratch_event_vertices);
    }
    if (m->skins) for (uint32_t i=0;i<m->info.nodes;++i) {
        free(m->skins[i].bones);free(m->skins[i].palette);free(m->skins[i].scratch_palette);
    }
    free(m->nodes);free(m->scratch_nodes);free(m->render_hidden);free(m->globals);free(m->scratch_globals);
    free(m->materials);free(m->scratch_materials);free(m->poses);free(m->tracks);free(m->events);free(m->meshes);
    free(m->skins);dc_xx_close(m->xx);free(m);
}
#define TRY(expr) do { status=(expr); if(status!=DC_OK) goto failed; } while(0)
#define ALLOC(field,count) do { m->field=calloc((count)?(count):1,sizeof(*m->field)); if(!m->field) {status=DC_MEMORY;goto failed;} } while(0)
static dc_status model_open(const void *xx,size_t xx_length,const void *xa,size_t xa_length,
        uint32_t static_only,dc_model **out) {
    if (!out || overlap(xx,xx_length,out,sizeof(*out)) || overlap(xa,xa_length,out,sizeof(*out))) return DC_ARGUMENT;
    *out=NULL;
    dc_model *m=calloc(1,sizeof(*m));
    if (!m) return DC_MEMORY;
    dc_status status;
    m->source_xx=xx;m->source_xa=xa;m->xx_length=xx_length;m->xa_length=xa_length;
    m->static_only=static_only;
    TRY(dc_xx_open(xx,xx_length,&m->xx));
    TRY(dc_xx_get_info(m->xx,&m->info));
    if (!static_only) TRY(dc_xa_probe(xa,xa_length,&m->xa_info));
    /* Event tracks are admitted after full XA framing validation. Type 0/1
     * target UV scrolling is applied during ticks; other event types remain
     * inert while their serialized views stay available to the host. */
    /* Morph sections are parsed and retained by dc_morph. The base model
     * loader keeps its pose/material/event admission independent; callers
     * that render morph resources must apply the persistent local morph
     * buffers before skinning. */
    if (m->xa_info.bone_tracks>4096 || m->xa_info.material_tracks>4096) { status=DC_FORMAT;goto failed; }
    if (!static_only) TRY(dc_xa_load_clips(xa,xa_length,m->clips,m->timing,512));
    ALLOC(nodes,m->info.nodes);ALLOC(scratch_nodes,m->info.nodes);
    ALLOC(render_hidden,m->info.nodes);
    ALLOC(skins,m->info.nodes);
    ALLOC(globals,m->info.nodes);ALLOC(scratch_globals,m->info.nodes);
    ALLOC(materials,m->info.materials);ALLOC(scratch_materials,m->info.materials);
    ALLOC(poses,m->xa_info.bone_tracks);ALLOC(tracks,m->xa_info.material_tracks);
    ALLOC(events,m->xa_info.event_tracks);ALLOC(meshes,m->info.submeshes);
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
    for (uint32_t i=0;i<m->info.nodes;++i) {
        dc_xx_skin metadata;TRY(dc_xx_skin_at(m->xx,i,&metadata));
        if (metadata.vertex_format!=0x111c && metadata.vertex_format!=0x141c) {
            if (metadata.bones && metadata.vertex_format!=0x112 && metadata.vertex_format!=0x412) {status=DC_FORMAT;goto failed;}
            continue;
        }
        skin_node *skin=&m->skins[i];skin->count=metadata.bones;skin->assigned[255]=1;
        skin->bones=calloc(skin->count?skin->count:1,sizeof(*skin->bones));
        skin->palette=malloc(sizeof(*skin->palette));skin->scratch_palette=malloc(sizeof(*skin->scratch_palette));
        if (!skin->bones || !skin->palette || !skin->scratch_palette) {status=DC_MEMORY;goto failed;}
        TRY(dc_skin_palette_init(skin->palette));*skin->scratch_palette=*skin->palette;
        uint32_t *targets=calloc(skin->count?skin->count:1,sizeof(*targets));
        if (!targets) {status=DC_MEMORY;goto failed;}
        status=dc_xx_bind_bones(m->xx,i,targets,skin->count);
        if (status!=DC_OK) {free(targets);goto failed;}
        for (uint32_t j=0;j<skin->count;++j) {
            dc_xx_bone bone;status=dc_xx_bone_at(m->xx,metadata.first_bone+j,&bone);
            if (status!=DC_OK) break;
            if (bone.index>=DC_SKIN_PALETTE_LIMIT || (bone.index!=255 && targets[j]==UINT32_MAX)) {status=DC_FORMAT;break;}
            skin->bones[j].index=bone.index;skin->bones[j].target=targets[j];skin->assigned[bone.index]=1;
            status=dc_xx_bone_matrix(m->xx,metadata.first_bone+j,&skin->bones[j].offset);
            if (status!=DC_OK) break;
        }
        free(targets);if (status!=DC_OK) goto failed;
    }
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
    for (uint32_t i=0;i<m->xa_info.event_tracks;++i) {
        dc_xa_event_track track;TRY(dc_xa_event_track_at(xa,xa_length,i,&track));
        event_track *event=&m->events[i];event->type=track.type;event->target=UINT32_MAX;
        event->key_count=track.key_count;event->enabled=track.flag_d!=0;event->reverse=track.flag_b!=0;
        event->filtered=track.flag_a!=0;event->mesh_filter=track.tail_value;
        uint32_t bits=track.parameter;memcpy(&event->parameter,&bits,sizeof(event->parameter));
        if (!isfinite(event->parameter)) {status=DC_RANGE;goto failed;}
        status=dc_xx_find_node_encoded(m->xx,animation+track.name_offset,track.name_length,&event->target);
        if (status==DC_NOT_FOUND) event->target=UINT32_MAX;
        else if (status!=DC_OK) goto failed;
    }
    for (uint32_t i=0;i<m->info.submeshes;++i) {
        mesh_data *mesh=&m->meshes[i];TRY(dc_xx_submesh_at(m->xx,i,&mesh->info));
        if (mesh->info.material>=m->info.materials || mesh->info.vertex_count>1048576 || mesh->info.index_count>1048576) {status=DC_RANGE;goto failed;}
        mesh->vertices=calloc(mesh->info.vertex_count?mesh->info.vertex_count:1,sizeof(*mesh->vertices));
        mesh->indices=calloc(mesh->info.index_count?mesh->info.index_count:1,sizeof(*mesh->indices));
        if (!mesh->vertices || !mesh->indices) {status=DC_MEMORY;goto failed;}
        TRY(dc_xx_load_mesh_vertices(m->xx,i,mesh->vertices,mesh->info.vertex_count));
        TRY(dc_xx_load_mesh_indices(m->xx,i,mesh->indices,mesh->info.index_count));
        if (m->xa_info.event_tracks) {
            size_t bytes=(size_t)mesh->info.vertex_count*sizeof(*mesh->vertices);
            mesh->event_vertices=malloc(bytes?bytes:sizeof(*mesh->vertices));
            mesh->scratch_event_vertices=malloc(bytes?bytes:sizeof(*mesh->vertices));
            if (!mesh->event_vertices || !mesh->scratch_event_vertices) {status=DC_MEMORY;goto failed;}
            memcpy(mesh->event_vertices,mesh->vertices,bytes);
            memcpy(mesh->scratch_event_vertices,mesh->vertices,bytes);
        }
        skin_node *skin=&m->skins[mesh->info.node];
        if (skin->palette) {
            size_t count=mesh->info.vertex_count?mesh->info.vertex_count:1;
            mesh->weights=calloc(count,sizeof(*mesh->weights));mesh->deformed=calloc(count,sizeof(*mesh->deformed));
            mesh->scratch_deformed=calloc(count,sizeof(*mesh->scratch_deformed));
            if (!mesh->weights || !mesh->deformed || !mesh->scratch_deformed) {status=DC_MEMORY;goto failed;}
            TRY(dc_xx_load_mesh_weights(m->xx,i,mesh->weights,mesh->info.vertex_count));
            for (uint32_t j=0;j<mesh->info.vertex_count;++j) {
                const dc_xx_weights *weights=&mesh->weights[j];
                volatile float sum01=weights->weights[0]+weights->weights[1];
                volatile float sum012=sum01+weights->weights[2];
                float blend[4]={weights->weights[0],weights->weights[1],weights->weights[2],1-sum012};
                for (uint32_t k=0;k<4;++k) if (blend[k]!=0 && !skin->assigned[weights->indices[k]]) {status=DC_FORMAT;goto failed;}
            }
        }
    }
    m->animation.blend=1;
    if (!static_only) TRY(dc_model_request(m,1,0));
    *out=m;return DC_OK;
failed:
    dc_model_close(m);return status;
}

dc_status dc_model_open(const void *xx,size_t xx_length,const void *xa,size_t xa_length,dc_model **out) {
    return model_open(xx,xx_length,xa,xa_length,0,out);
}
dc_status dc_model_open_static(const void *xx,size_t xx_length,dc_model **out) {
    return model_open(xx,xx_length,NULL,0,1,out);
}

dc_status dc_model_request(dc_model *m,uint32_t clip,uint32_t now) {
    if (!m) return DC_ARGUMENT;
    if (m->static_only) return clip<512 ? DC_NOT_FOUND : DC_ARGUMENT;
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
    if (m->static_only) {
        if (clip) *clip=DC_MODEL_NO_ANIMATION;
        *ready=1;return DC_OK;
    }
    return dc_animation_query(&m->animation,m->clips,512,clip,ready);
}
dc_status dc_model_set_chain(dc_model *m,uint32_t clip,int32_t next_clip) {
    if(!m)return DC_ARGUMENT;
    if(m->static_only)return DC_NOT_FOUND;
    return dc_animation_set_chain(m->timing,512,clip,next_clip);
}
dc_status dc_model_set_loop(dc_model *m,uint32_t clip,int32_t limit) {
    if(!m)return DC_ARGUMENT;
    if(m->static_only)return DC_NOT_FOUND;
    return dc_animation_set_loop(m->clips,m->timing,512,clip,limit);
}
dc_status dc_model_get_animation(const dc_model *m,dc_animation_state *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    if (m->static_only) return DC_NOT_FOUND;
    *out=m->animation;return DC_OK;
}
dc_status dc_model_tick(dc_model *m,uint32_t delta,uint32_t now,const dc_matrix *world) {
    if (!m || !world) return DC_ARGUMENT;
    dc_animation_state state=m->animation;
    dc_animation_clip clips[512];dc_animation_tick_result update={0};
    dc_status status=DC_OK;
    if (!m->static_only) {
        memcpy(clips,m->clips,sizeof(clips));
        status=dc_animation_tick(&state,clips,m->timing,512,delta,1,now,&update);
        if (status!=DC_OK) return status;
        if (update.sample_count!=1 || state.blend<1) return DC_FORMAT;
    }
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
    if (m->xa_info.event_tracks) {
        float elapsed=(float)delta/33.0f;
        if (!isfinite(elapsed)) return DC_RANGE;
        for (uint32_t i=0;i<m->info.submeshes;++i) {
            mesh_data *mesh=&m->meshes[i];
            if (!mesh->event_vertices) continue;
            size_t bytes=(size_t)mesh->info.vertex_count*sizeof(*mesh->event_vertices);
            memcpy(mesh->scratch_event_vertices,mesh->event_vertices,bytes);
        }
        for (uint32_t i=0;i<m->xa_info.event_tracks;++i) {
            event_track *event=&m->events[i];
            if (!event->enabled || event->target==UINT32_MAX || event->key_count || event->filtered ||
                (event->type!=0 && event->type!=1)) continue;
            float step=elapsed*event->parameter*0.001f;
            if (event->reverse) step=-step;
            if (!isfinite(step)) return DC_RANGE;
            for (uint32_t mesh_index=0;mesh_index<m->info.submeshes;++mesh_index) {
                mesh_data *mesh=&m->meshes[mesh_index];
                if (!mesh->event_vertices || mesh->info.node!=event->target) continue;
                for (uint32_t vertex=0;vertex<mesh->info.vertex_count;++vertex) {
                    float *coordinate=&mesh->scratch_event_vertices[vertex].uv[event->type==0 ? 1 : 0];
                    *coordinate+=step;
                    if (!isfinite(*coordinate)) return DC_RANGE;
                }
            }
        }
    }
    status=dc_scene_update(m->scratch_nodes,m->info.nodes,world,m->scratch_globals,m->info.nodes);
    if(status!=DC_OK) return status;
    for (uint32_t i=0;i<m->info.nodes;++i) {
        skin_node *skin=&m->skins[i];if (!skin->palette) continue;
        *skin->scratch_palette=*skin->palette;
        status=dc_skin_palette_update(skin->scratch_palette,skin->bones,skin->count,m->scratch_globals,m->info.nodes);
        if (status!=DC_OK) return status;
    }
    for (uint32_t i=0;i<m->info.submeshes;++i) {
        mesh_data *mesh=&m->meshes[i];if (!mesh->deformed) continue;
        const dc_mesh_vertex *source_vertices=mesh->event_vertices ? mesh->scratch_event_vertices : mesh->vertices;
        status=dc_skin_apply(m->skins[mesh->info.node].scratch_palette,source_vertices,mesh->weights,
            mesh->info.vertex_count,DC_SKIN_TRANSFORM_NORMAL,mesh->scratch_deformed,mesh->info.vertex_count);
        if (status!=DC_OK) return status;
    }
    memcpy(m->nodes,m->scratch_nodes,m->info.nodes*sizeof(*m->nodes));
    memcpy(m->globals,m->scratch_globals,m->info.nodes*sizeof(*m->globals));
    memcpy(m->materials,m->scratch_materials,m->info.materials*sizeof(*m->materials));
    for (uint32_t i=0;i<m->info.nodes;++i) if (m->skins[i].palette) *m->skins[i].palette=*m->skins[i].scratch_palette;
    for (uint32_t i=0;i<m->info.submeshes;++i) if (m->meshes[i].event_vertices) {
        size_t bytes=(size_t)m->meshes[i].info.vertex_count*sizeof(*m->meshes[i].event_vertices);
        memcpy(m->meshes[i].event_vertices,m->meshes[i].scratch_event_vertices,bytes);
    }
    for (uint32_t i=0;i<m->info.submeshes;++i) if (m->meshes[i].deformed)
        memcpy(m->meshes[i].deformed,m->meshes[i].scratch_deformed,m->meshes[i].info.vertex_count*sizeof(dc_mesh_vertex));
    m->animation=state;
    if (!m->static_only) memcpy(m->clips,clips,sizeof(clips));
    return DC_OK;
}
dc_status dc_model_get_info(const dc_model *m,dc_xx_info *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    *out=m->info;
    return DC_OK;
}
dc_status dc_model_material(const dc_model *m,uint32_t index,dc_material_value *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    if (index>=m->info.materials) return DC_RANGE;
    *out=m->materials[index];
    return DC_OK;
}
dc_status dc_model_global(const dc_model *m,uint32_t index,dc_matrix *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    if (index>=m->info.nodes) return DC_RANGE;
    *out=m->globals[index];
    return DC_OK;
}

dc_status dc_model_mesh(const dc_model *m,uint32_t index,dc_xx_submesh *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    if (index>=m->info.submeshes) return DC_RANGE;
    *out=m->meshes[index].info;
    return DC_OK;
}

dc_status dc_model_vertex_space(const dc_model *m,uint32_t mesh,uint32_t *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes) return DC_RANGE;
    *out=m->meshes[mesh].deformed ? DC_MODEL_SPACE_WORLD : DC_MODEL_SPACE_LOCAL;return DC_OK;
}
dc_status dc_model_mesh_visible(const dc_model *m,uint32_t mesh,uint32_t *out) {
    if (!m || !output_allowed(m,out,sizeof(*out))) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes) return DC_RANGE;
    uint32_t node=m->meshes[mesh].info.node;
    if(m->render_hidden[node]==1){*out=0;return DC_OK;}
    while (node!=DC_XX_NO_PARENT) {
        if (m->nodes[node].hidden) {*out=0;return DC_OK;}
        node=m->nodes[node].parent;
    }
    *out=1;return DC_OK;
}
dc_status dc_model_hide_node(dc_model *m,uint32_t node,uint32_t hidden) {
    if(!m)return DC_ARGUMENT;
    if(node>=m->info.nodes||hidden>1)return DC_RANGE;
    /* Original 0x412450 recursively writes render byte +0x1f0. The
     * independent +0x1f8 transform-suppression byte must stay unchanged. */
    uint8_t *subtree=calloc(m->info.nodes,1);if(!subtree)return DC_MEMORY;
    subtree[node]=1;
    for(uint32_t i=node+1;i<m->info.nodes;++i)
        if(m->nodes[i].parent!=DC_SCENE_NO_PARENT&&subtree[m->nodes[i].parent])subtree[i]=1;
    for(uint32_t i=node;i<m->info.nodes;++i)if(subtree[i])m->render_hidden[i]=(uint8_t)hidden;
    free(subtree);
    return DC_OK;
}
dc_status dc_model_load_vertices(const dc_model *m,uint32_t mesh,dc_mesh_vertex *out,size_t capacity) {
    if (!m) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes) return DC_RANGE;
    const mesh_data *data=&m->meshes[mesh];size_t bytes=data->info.vertex_count*sizeof(*out);
    if (!output_allowed(m,out,bytes)) return DC_ARGUMENT;
    if (capacity<data->info.vertex_count) return DC_RANGE;
    memcpy(out,data->deformed ? data->deformed : (data->event_vertices ? data->event_vertices : data->vertices),bytes);return DC_OK;
}
dc_status dc_model_load_source_vertices(const dc_model *m,uint32_t mesh,dc_mesh_vertex *out,size_t capacity) {
    if (!m) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes) return DC_RANGE;
    const mesh_data *data=&m->meshes[mesh];size_t bytes=data->info.vertex_count*sizeof(*out);
    if (!output_allowed(m,out,bytes)) return DC_ARGUMENT;
    if (capacity<data->info.vertex_count) return DC_RANGE;
    memcpy(out,data->vertices,bytes);return DC_OK;
}
dc_status dc_model_project(const dc_model *m,uint32_t mesh,const dc_matrix *vp,const dc_viewport *viewport,
        uint32_t diffuse,dc_sprite_vertex *out,size_t capacity) {
    if (!m || !vp) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes) return DC_RANGE;
    const mesh_data *data=&m->meshes[mesh];dc_matrix mvp;
    if (!output_allowed(m,out,data->info.index_count*sizeof(*out))) return DC_ARGUMENT;
    dc_status status;
    if (data->deformed) mvp=*vp;
    else {
        status=dc_matrix_multiply(&m->globals[data->info.node],vp,&mvp);
        if(status!=DC_OK)return status;
    }
    const dc_mesh_vertex *vertices=data->deformed ? data->deformed : (data->event_vertices ? data->event_vertices : data->vertices);
    return dc_mesh_project(vertices,data->info.vertex_count,data->indices,data->info.index_count,&mvp,viewport,diffuse,out,capacity);
}

dc_status dc_model_project_clipped(const dc_model *m,uint32_t mesh,const dc_matrix *vp,const dc_viewport *viewport,
        uint32_t diffuse,dc_sprite_vertex *out,size_t capacity,size_t *written) {
    if (!m || !vp || !output_allowed(m,written,sizeof(*written))) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes) return DC_RANGE;
    if (capacity>1048576) return DC_RANGE;
    if (out && !output_allowed(m,out,capacity*sizeof(*out))) return DC_ARGUMENT;
    const mesh_data *data=&m->meshes[mesh];dc_matrix mvp;
    dc_status status;
    if (data->deformed) mvp=*vp;
    else {
        status=dc_matrix_multiply(&m->globals[data->info.node],vp,&mvp);
        if(status!=DC_OK)return status;
    }
    /* vp is copied/composed above, so reject its output alias explicitly. */
    if ((out && overlap(vp,sizeof(*vp),out,capacity*sizeof(*out))) ||
        overlap(vp,sizeof(*vp),written,sizeof(*written))) return DC_ARGUMENT;
    const dc_mesh_vertex *vertices=data->deformed ? data->deformed : (data->event_vertices ? data->event_vertices : data->vertices);
    return dc_mesh_clip_project(vertices,data->info.vertex_count,
        data->indices,data->info.index_count,&mvp,viewport,diffuse,out,capacity,written);
}

dc_status dc_model_project_vertices_clipped(const dc_model *m,uint32_t mesh,
        const dc_mesh_vertex *vertices,size_t vertex_count,const dc_matrix *vp,
        const dc_viewport *viewport,uint32_t diffuse,dc_sprite_vertex *out,size_t capacity,size_t *written) {
    if (!m || !vertices || !vp || !viewport || !written) return DC_ARGUMENT;
    if (mesh>=m->info.submeshes || vertex_count!=m->meshes[mesh].info.vertex_count) return DC_RANGE;
    const mesh_data *data=&m->meshes[mesh];
    if (out && !output_allowed(m,out,capacity*sizeof(*out))) return DC_ARGUMENT;
    if (overlap(vertices,vertex_count*sizeof(*vertices),out,capacity*sizeof(*out)) ||
        overlap(vertices,vertex_count*sizeof(*vertices),written,sizeof(*written))) return DC_ARGUMENT;
    dc_mesh_vertex *projected= (dc_mesh_vertex *)vertices;
    dc_mesh_vertex *owned=NULL;
    dc_matrix mvp;
    dc_status status;
    if (data->deformed) {
        if (!data->weights || !m->skins[data->info.node].palette) return DC_FORMAT;
        owned=calloc(vertex_count,sizeof(*owned));
        if (!owned) return DC_MEMORY;
        status=dc_skin_apply(m->skins[data->info.node].palette,vertices,data->weights,vertex_count,
            DC_SKIN_TRANSFORM_NORMAL,owned,vertex_count);
        if (status!=DC_OK) { free(owned); return status; }
        projected=owned;
        mvp=*vp;
    } else {
        status=dc_matrix_multiply(&m->globals[data->info.node],vp,&mvp);
        if (status!=DC_OK) return status;
    }
    status=dc_mesh_clip_project(projected,vertex_count,data->indices,data->info.index_count,
        &mvp,viewport,diffuse,out,capacity,written);
    free(owned);
    return status;
}
