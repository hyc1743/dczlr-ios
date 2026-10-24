#import "DCGameScene.h"
#import "DCArchive.h"
#include "dc_camera.h"
#include "dc_eyeneck.h"
#include "dc_gameplay.h"
#include "dc_model.h"
#include "dc_xl.h"
#include <math.h>
#include <float.h>
#include <stdio.h>
#include <string.h>

typedef struct dc_game_model {
    __strong NSData *xxData,*xaData;
    dc_model *model;
    dc_xx *xx;
    dc_xx_info info;
    dc_xa_info xaInfo;
    struct dc_morph_track_cache *morphTracks;
    uint32_t morphTrackCount;
    uintptr_t *textures;
    uint32_t textureCount;
    dc_matrix world;
} dc_game_model;
typedef struct dc_morph_key_cache { uint32_t frame; size_t vectorsOffset; uint32_t count; } dc_morph_key_cache;
typedef struct dc_morph_track_cache {
    uint32_t meshIndex, indexCount;
    uint32_t *indices;
    uint32_t keyCount;
    dc_morph_key_cache *keys;
} dc_morph_track_cache;
typedef struct dc_walk_surface { float x[3],y[3],z[3]; } dc_walk_surface;

static dc_matrix gameIdentity(void) { return (dc_matrix){{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}}; }
static uint32_t gameColor(const dc_material_value *value) {
    uint32_t out=0;
    for(uint32_t i=0;i<4;++i) {
        float v=fminf(1,fmaxf(0,value->components[i]));
        uint32_t c=(uint32_t)(v*255);
        out|=c<<(i==3?24:16-i*8);
    }
    return out;
}
static void freeMorphCaches(dc_game_model *slot) {
    if(!slot || !slot->morphTracks)return;
    for(uint32_t i=0;i<slot->morphTrackCount;++i) {
        free(slot->morphTracks[i].indices);
        free(slot->morphTracks[i].keys);
    }
    free(slot->morphTracks);slot->morphTracks=NULL;slot->morphTrackCount=0;
}

@implementation DCGameScene {
    NSString *_directory;
    NSData *_eyesData,*_neckData;
    NSData *_lightData;
    dc_xl_info _lightInfo;
    dc_xl_light _mapLight;
    NSData *_mapVariantLightData;
    dc_xl_info _mapVariantLightInfo;
    dc_xl_light _mapVariantLight;
    dc_vk_sprite *_renderer;
    dc_game_model _map,_actor;
    dc_game_model _face;
    dc_matrix _cameraBase,_actorWorld;
    float _cameraOriginX,_cameraOriginZ,_actorOriginX,_actorOriginZ;
    float _cameraDistance,_cameraHeight,_cameraPitch,_cameraYaw;
    uint32_t _cameraPreset;
    BOOL _cameraAutoSelected;
    NSMutableDictionary<NSNumber *, NSValue *> *_cameraFallbacks;
    uint32_t _actorHeadNode;
    uint32_t _lastTick; BOOL _tickInitialized;
    float _lastInputX,_lastInputY; BOOL _inputInitialized;
    float _walkMinX,_walkMaxX,_walkMinZ,_walkMaxZ;
    dc_game_player _player;
    BOOL _playerSaveDirty;
    dc_game_interaction_state _interactionState;
    BOOL _interactionActive;uint32_t _interactionStartTick;
    uint32_t _interactionCount;BOOL _interactionCompleted;
    BOOL _mapAdvanced;uint32_t _mapSelector;
    BOOL _gameFinished;
    uint32_t _actorSkinMeshCount;
    BOOL _actorSkinAdvanced;
    dc_walk_surface *_surfaces;size_t _surfaceCount,_surfaceCapacity;
    BOOL _loaded;
    uint32_t _visibleMapTriangles,_visibleActorTriangles;
}
- (BOOL)loaded { return _loaded; }
- (uint32_t)visibleMapTriangles { return _visibleMapTriangles; }
- (uint32_t)visibleActorTriangles { return _visibleActorTriangles; }
- (uint32_t)interactionCount { return _interactionCount; }
- (BOOL)interactionCompleted { return _interactionCompleted; }
- (BOOL)gameFinished { return _gameFinished; }
- (BOOL)actorSkinAdvanced { return _actorSkinAdvanced; }

- (NSString *)decodedName:(const uint8_t *)raw length:(size_t)length {
    if (!raw || !length || length > 1024) return nil;
    char decoded[1025];
    size_t count=0;
    while(count<length && raw[count]!=255 && raw[count]!=0) {
        decoded[count]=(char)(raw[count]^255);
        if (!decoded[count]) break;
        ++count;
    }
    if (!count) return @"";
    return [[NSString alloc] initWithBytes:decoded length:count encoding:NSASCIIStringEncoding];
}

- (uint32_t)findNode:(dc_game_model *)slot name:(NSString *)name {
    if (!slot->xx || !name.length) return UINT32_MAX;
    for(uint32_t i=0;i<slot->info.nodes;++i) {
        dc_xx_node node;
        if(dc_xx_node_at(slot->xx,i,&node)!=DC_OK) continue;
        NSString *decoded=[self decodedName:(const uint8_t *)slot->xxData.bytes+node.name.offset length:node.name.length];
        if([decoded isEqualToString:name]) return i;
    }
    return UINT32_MAX;
}

- (uint32_t)placementNodeFromPLST:(NSData *)data model:(dc_game_model *)slot {
    if(!data || data.length<9 || !slot->xx) return UINT32_MAX;
    const uint8_t *bytes=data.bytes;size_t cursor=4;
    /* The observed PLST record starts with a one-byte variant, then four
     * encoded name blocks and an eight-byte zero tail. */
    cursor+=1;
    uint32_t selected=UINT32_MAX;
    while(cursor+4<=data.length) {
        uint32_t length=0;memcpy(&length,bytes+cursor,sizeof(length));cursor+=4;
        if(!length)break;
        if(length>1024 || cursor+length>data.length) return UINT32_MAX;
        NSString *name=[self decodedName:bytes+cursor length:length];cursor+=length;
        uint32_t node=[self findNode:slot name:name];if(node!=UINT32_MAX)selected=node;
    }
    return selected;
}

- (NSData *)entry:(NSString *)name archive:(DCArchive *)archive error:(NSString **)error {
    for(uint32_t i=0;i<archive.entryCount;++i)
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame)
            return [archive readEntryAtIndex:i limit:128*1024*1024 error:nil];
    if(error)*error=[NSString stringWithFormat:@"Missing game resource %@",name];
    return nil;
}
- (NSData *)lightEntryForSelector:(uint32_t)selector archive:(DCArchive *)archive {
    NSString *prefix=[NSString stringWithFormat:@"pp%02u_",selector];
    for(uint32_t i=0;i<archive.entryCount;++i) {
        NSString *name=[archive asciiNameAtIndex:i];
        if(!name || ![name.lowercaseString hasPrefix:prefix.lowercaseString] ||
           ![name.lowercaseString hasSuffix:@".xl"]) continue;
        return [archive readEntryAtIndex:i limit:128*1024 error:nil];
    }
    return nil;
}
- (BOOL)loadLightForSelector:(uint32_t)selector archive:(DCArchive *)archive error:(NSString **)error {
    NSData *data=[self lightEntryForSelector:selector archive:archive];
    if(!data) { if(error)*error=[NSString stringWithFormat:@"Missing XL light resource for map %u",selector]; return NO; }
    dc_xl_info info;dc_xl_light light;
    if(dc_xl_probe(data.bytes,data.length,&info)!=DC_OK || !info.lights ||
       dc_xl_light_at(data.bytes,data.length,0,&light)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"XL light resource rejected for map %u",selector];
        return NO;
    }
    _lightData=data;_lightInfo=info;_mapLight=light;return YES;
}
- (BOOL)loadMapVariantLightForSelector:(uint32_t)selector archive:(DCArchive *)archive error:(NSString **)error {
    NSString *name=[NSString stringWithFormat:@"mp00_%02u.xl",selector];
    NSData *data=[self entry:name archive:archive error:error];
    if(!data)return NO;
    dc_xl_info info;dc_xl_light light;
    if(dc_xl_probe(data.bytes,data.length,&info)!=DC_OK || !info.lights ||
       dc_xl_light_at(data.bytes,data.length,0,&light)!=DC_OK) {
        if(error)*error=[NSString stringWithFormat:@"Map XL light resource rejected for map %u",selector];
        return NO;
    }
    _mapVariantLightData=data;_mapVariantLightInfo=info;_mapVariantLight=light;return YES;
}
- (BOOL)encodedSpan:(dc_eyeneck_span)span matchesName:(NSString *)name data:(NSData *)data {
    NSData *plain=[name dataUsingEncoding:NSASCIIStringEncoding];
    if(!plain || span.length!=plain.length || span.offset>data.length || span.length>data.length-span.offset)return NO;
    const uint8_t *raw=(const uint8_t *)data.bytes+span.offset;const uint8_t *expected=plain.bytes;
    for(NSUInteger i=0;i<span.length;++i)if((uint8_t)(expected[i]^255u)!=raw[i])return NO;
    return YES;
}
- (BOOL)openModel:(dc_game_model *)slot staticOnly:(BOOL)staticOnly error:(NSString **)error {
    dc_status status=staticOnly ? dc_model_open_static(slot->xxData.bytes,slot->xxData.length,&slot->model)
        : dc_model_open(slot->xxData.bytes,slot->xxData.length,slot->xaData.bytes,slot->xaData.length,&slot->model);
    if(status!=DC_OK) { if(error)*error=[NSString stringWithFormat:@"Game model open failed: %d",status]; return NO; }
    status=dc_xx_open(slot->xxData.bytes,slot->xxData.length,&slot->xx);
    if(status==DC_OK)status=dc_model_get_info(slot->model,&slot->info);
    if(status==DC_OK && slot->xaData)
        status=dc_xa_probe(slot->xaData.bytes,slot->xaData.length,&slot->xaInfo);
    if(status!=DC_OK || slot->info.textures>64) { if(error)*error=@"Game model profile rejected"; return NO; }
    slot->textureCount=slot->info.textures;slot->textures=calloc(slot->textureCount,sizeof(uintptr_t));
    if(slot->textureCount && !slot->textures) { if(error)*error=@"Game texture handle allocation failed"; return NO; }
    for(uint32_t i=0;i<slot->textureCount;++i) {
        dc_image_info info;status=dc_xx_image_probe(slot->xx,i,&info);
        if(status!=DC_OK || info.rgba_bytes>64*1024*1024) { if(error)*error=@"Game texture profile rejected"; return NO; }
        NSMutableData *pixels=[NSMutableData dataWithLength:info.rgba_bytes];
        status=dc_xx_image_decode(slot->xx,i,pixels.mutableBytes,pixels.length,&info);
        if(status==DC_OK)status=dc_vk_sprite_upload(_renderer,info.width,info.height,pixels.bytes,pixels.length,&slot->textures[i]);
        if(status!=DC_OK) { if(error)*error=@"Game texture upload failed"; return NO; }
    }
    slot->world=gameIdentity();
    return YES;
}
- (uint32_t)findAnchor:(dc_game_model *)slot {
    const char *suffixes="abc";
    for(uint32_t wanted=0;wanted<3;++wanted) {
        char target[32];snprintf(target,sizeof(target),"m_Nn_yuka_l_%c",suffixes[wanted]);
        for(uint32_t i=1;i<slot->info.nodes;++i) {
            dc_xx_node node;if(dc_xx_node_at(slot->xx,i,&node)!=DC_OK)continue;
            const uint8_t *raw=(const uint8_t *)slot->xxData.bytes+node.name.offset;
            size_t n=0;while(n<node.name.length && raw[n]!=255)++n;
            if(n>=sizeof(target)-1)continue;
            char decoded[32];for(size_t j=0;j<n;++j)decoded[j]=(char)(raw[j]^255);decoded[n]=0;
            if(!strcmp(decoded,target))return i;
        }
    }
    return UINT32_MAX;
}
- (void)computeWalkBounds {
    dc_matrix identity=gameIdentity();
    if(dc_model_tick(_map.model,0,0,&identity)!=DC_OK) {
        _walkMinX=-100;_walkMaxX=100;_walkMinZ=-100;_walkMaxZ=100;return;
    }
    free(_surfaces);_surfaces=NULL;_surfaceCount=0;_surfaceCapacity=0;
    _walkMinX=FLT_MAX;_walkMaxX=-FLT_MAX;_walkMinZ=FLT_MAX;_walkMaxZ=-FLT_MAX;
    for(uint32_t i=0;i<_map.info.submeshes;++i) {
        dc_xx_submesh mesh;uint32_t visible=0;
        if(dc_model_mesh(_map.model,i,&mesh)!=DC_OK || dc_model_mesh_visible(_map.model,i,&visible)!=DC_OK || !visible)continue;
        dc_matrix global;if(dc_model_global(_map.model,mesh.node,&global)!=DC_OK)continue;
        dc_mesh_vertex *vertices=calloc(mesh.vertex_count?mesh.vertex_count:1,sizeof(*vertices));
        if(!vertices || dc_model_load_vertices(_map.model,i,vertices,mesh.vertex_count)!=DC_OK){free(vertices);continue;}
        uint16_t *indices=calloc(mesh.index_count?mesh.index_count:1,sizeof(*indices));
        if(!indices || dc_xx_load_mesh_indices(_map.xx,i,indices,mesh.index_count)!=DC_OK){free(indices);free(vertices);continue;}
        for(uint32_t j=0;j<mesh.vertex_count;++j) {
            float x=vertices[j].position[0]*global.values[0]+vertices[j].position[1]*global.values[4]+vertices[j].position[2]*global.values[8]+global.values[12];
            float z=vertices[j].position[0]*global.values[2]+vertices[j].position[1]*global.values[6]+vertices[j].position[2]*global.values[10]+global.values[14];
            _walkMinX=fminf(_walkMinX,x);_walkMaxX=fmaxf(_walkMaxX,x);_walkMinZ=fminf(_walkMinZ,z);_walkMaxZ=fmaxf(_walkMaxZ,z);
        }
        for(uint32_t j=0;j+2<mesh.index_count;j+=3) {
            uint16_t ia=indices[j],ib=indices[j+1],ic=indices[j+2];if(ia>=mesh.vertex_count||ib>=mesh.vertex_count||ic>=mesh.vertex_count)continue;
            float p[3][3];uint16_t ids[3]={ia,ib,ic};
            for(unsigned k=0;k<3;++k){dc_mesh_vertex *v=&vertices[ids[k]];p[k][0]=v->position[0]*global.values[0]+v->position[1]*global.values[4]+v->position[2]*global.values[8]+global.values[12];p[k][1]=v->position[0]*global.values[1]+v->position[1]*global.values[5]+v->position[2]*global.values[9]+global.values[13];p[k][2]=v->position[0]*global.values[2]+v->position[1]*global.values[6]+v->position[2]*global.values[10]+global.values[14];}
            float ux=p[1][0]-p[0][0],uy=p[1][1]-p[0][1],uz=p[1][2]-p[0][2],vx=p[2][0]-p[0][0],vy=p[2][1]-p[0][1],vz=p[2][2]-p[0][2];
            float normalY=uz*vx-ux*vz;if(fabsf(normalY)<.2f)continue;
            if(_surfaceCount==_surfaceCapacity){size_t next=_surfaceCapacity?_surfaceCapacity*2:1024;dc_walk_surface *grown=realloc(_surfaces,next*sizeof(*grown));if(!grown){free(indices);free(vertices);return;}_surfaces=grown;_surfaceCapacity=next;}
            dc_walk_surface *surface=&_surfaces[_surfaceCount++];for(unsigned k=0;k<3;++k){surface->x[k]=p[k][0];surface->y[k]=p[k][1];surface->z[k]=p[k][2];}
        }
        free(indices);
        free(vertices);
    }
    if(!isfinite(_walkMinX)||!isfinite(_walkMaxX)||_walkMinX>=_walkMaxX){_walkMinX=-100;_walkMaxX=100;}
    if(!isfinite(_walkMinZ)||!isfinite(_walkMaxZ)||_walkMinZ>=_walkMaxZ){_walkMinZ=-100;_walkMaxZ=100;}
    float margin=1.0f;_walkMinX+=margin;_walkMaxX-=margin;_walkMinZ+=margin;_walkMaxZ-=margin;
    uint32_t savedInteractions=_player.interaction_count,savedMap=_player.map_selector;_player=(dc_game_player){.x=_actor.world.values[12],.z=_actor.world.values[14],.min_x=_walkMinX,.max_x=_walkMaxX,.min_z=_walkMinZ,.max_z=_walkMaxZ,.speed=8,.interaction_count=savedInteractions,.map_selector=savedMap};
    _interactionState.interaction_count=savedInteractions;
}
- (void)loadPlayerState {
    NSString *path=[_directory stringByAppendingPathComponent:@"save/player.state"];
    NSData *data=[NSData dataWithContentsOfFile:path];if(data.length<DC_GAME_PLAYER_SAVE_BYTES)return;
    dc_game_player loaded;if(dc_game_player_load(data.bytes,data.length,&loaded)!=DC_OK)return;
    _player.x=fmaxf(_player.min_x,fminf(_player.max_x,loaded.x));_player.z=fmaxf(_player.min_z,fminf(_player.max_z,loaded.z));
    if(loaded.speed>0)_player.speed=loaded.speed;_player.interaction_count=loaded.interaction_count;_player.map_selector=loaded.map_selector;_interactionCount=loaded.interaction_count;_interactionCompleted=loaded.interaction_count>0;_interactionState=(dc_game_interaction_state){.interaction_count=loaded.interaction_count,.completed=loaded.interaction_count>0};_actor.world.values[12]=_player.x;_actor.world.values[14]=_player.z;
}
- (void)savePlayerState {
    if(!_playerSaveDirty)return;
    NSMutableData *data=[NSMutableData dataWithLength:DC_GAME_PLAYER_SAVE_BYTES];
    if(dc_game_player_save(&_player,data.mutableBytes,data.length)!=DC_OK)return;
    NSString *directory=[_directory stringByAppendingPathComponent:@"save"];[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:@"player.state"] options:NSDataWritingAtomic error:nil];_playerSaveDirty=NO;
}
- (BOOL)surfaceYAtX:(float)x z:(float)z nearY:(float)nearY result:(float *)result {
    BOOL found=NO;float best=0,bestDistance=FLT_MAX;
    for(size_t i=0;i<_surfaceCount;++i){dc_walk_surface *s=&_surfaces[i];float den=(s->z[1]-s->z[2])*(s->x[0]-s->x[2])+(s->x[2]-s->x[1])*(s->z[0]-s->z[2]);if(fabsf(den)<1e-5f)continue;float a=((s->z[1]-s->z[2])*(x-s->x[2])+(s->x[2]-s->x[1])*(z-s->z[2]))/den;float b=((s->z[2]-s->z[0])*(x-s->x[2])+(s->x[0]-s->x[2])*(z-s->z[2]))/den;float c=1-a-b;if(a<-.01f||b<-.01f||c<-.01f)continue;float y=a*s->y[0]+b*s->y[1]+c*s->y[2],distance=fabsf(y-nearY);if(distance<bestDistance){bestDistance=distance;best=y;found=YES;}}
    if(found&&result)*result=best;return found;
}
- (uint32_t)projectedTrianglesForModel:(dc_model *)model camera:(const dc_camera_matrices *)camera viewport:(const dc_viewport *)viewport {
    dc_xx_info info;if(dc_model_get_info(model,&info)!=DC_OK)return 0;
    uint32_t triangles=0;
    for(uint32_t meshIndex=0;meshIndex<info.submeshes;++meshIndex) {
        dc_xx_submesh mesh;uint32_t visible=0;size_t written=0;
        if(dc_model_mesh(model,meshIndex,&mesh)!=DC_OK||dc_model_mesh_visible(model,meshIndex,&visible)!=DC_OK||!visible)continue;
        if(dc_model_project_clipped(model,meshIndex,&camera->view_projection,viewport,0xffffffff,NULL,0,&written)!=DC_OK)continue;
        triangles+=(uint32_t)(written/3);
    }
    return triangles;
}
- (NSString *)preferredCameraNameForSelector:(uint32_t)selector {
    switch(selector){
        case 1:return @"roji_4p.cam";
        case 3:return @"home_sh.cam";
        case 4:return @"roji_4p.cam";
        case 5:return @"home_sh.cam";
        case 6:case 7:return @"roji_4p.cam";
        case 8:return @"home_sh.cam";
        default:return nil;
    }
}
- (NSString *)autoSelectCameraAtTick:(uint32_t)tick {
    if(_cameraAutoSelected)return nil;
    dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_viewport viewport={0,0,1024,768,0,1};
    dc_matrix mapWorld=_map.world,actorWorld=_actor.world;
    if(dc_model_tick(_map.model,0,tick,&mapWorld)!=DC_OK||dc_model_tick(_actor.model,0,tick,&actorWorld)!=DC_OK)return @"Camera fallback model tick failed";
    if(_actorHeadNode!=UINT32_MAX){dc_matrix head;if(dc_model_global(_actor.model,_actorHeadNode,&head)!=DC_OK||dc_model_tick(_face.model,0,tick,&head)!=DC_OK)return @"Camera fallback face tick failed";}
    dc_camera_orbit current={.base=_cameraBase,.stored_distance=_cameraDistance,.height=_cameraHeight,.pitch=_cameraPitch,.yaw=_cameraYaw};dc_camera_matrices currentMatrices;
    if(dc_camera_build(&current,&lens,&currentMatrices)!=DC_OK)return @"Camera fallback build failed";
    uint32_t currentMap=[self projectedTrianglesForModel:_map.model camera:&currentMatrices viewport:&viewport];
    uint32_t currentActor=[self projectedTrianglesForModel:_actor.model camera:&currentMatrices viewport:&viewport];
    uint32_t currentFace=[self projectedTrianglesForModel:_face.model camera:&currentMatrices viewport:&viewport];
    if(currentMap&&currentActor&&currentFace){_cameraAutoSelected=YES;return nil;}
    NSValue *cached=_cameraFallbacks[@(_mapSelector)];
    if(cached){dc_camera_orbit candidate;[cached getValue:&candidate];_cameraBase=candidate.base;_cameraDistance=candidate.stored_distance;_cameraHeight=candidate.height;_cameraPitch=candidate.pitch;_cameraYaw=candidate.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];_cameraAutoSelected=YES;return nil;}
    NSError *reason=nil;DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_03.pp"]] error:&reason];
    if(!archive)return reason.localizedDescription ?: @"Camera archive could not be opened";
    uint64_t bestScore=0;dc_camera_orbit best=current;BOOL found=NO;
    NSString *preferred=[self preferredCameraNameForSelector:_mapSelector];
    if(preferred){for(uint32_t i=0;i<archive.entryCount;++i){if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:preferred]!=NSOrderedSame)continue;NSData *data=[archive readEntryAtIndex:i limit:4096 error:nil];dc_camera_orbit candidate;dc_camera_matrices matrices;if(data&&dc_camera_read_preset(data.bytes,data.length,0,&candidate)==DC_OK&&dc_camera_build(&candidate,&lens,&matrices)==DC_OK&&[self projectedTrianglesForModel:_map.model camera:&matrices viewport:&viewport]&&[self projectedTrianglesForModel:_actor.model camera:&matrices viewport:&viewport]&&[self projectedTrianglesForModel:_face.model camera:&matrices viewport:&viewport]){_cameraBase=candidate.base;_cameraDistance=candidate.stored_distance;_cameraHeight=candidate.height;_cameraPitch=candidate.pitch;_cameraYaw=candidate.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];[_cameraFallbacks setObject:[NSValue valueWithBytes:&candidate objCType:@encode(dc_camera_orbit)] forKey:@(_mapSelector)];_cameraAutoSelected=YES;return nil;}break;}}
    for(uint32_t i=0;i<archive.entryCount;++i) {
        NSString *name=[archive asciiNameAtIndex:i];if(![name.lowercaseString hasSuffix:@".cam"])continue;
        NSData *data=[archive readEntryAtIndex:i limit:4096 error:nil];if(!data)continue;dc_camera_orbit candidate;dc_camera_matrices matrices;
        if(dc_camera_read_preset(data.bytes,data.length,0,&candidate)!=DC_OK||dc_camera_build(&candidate,&lens,&matrices)!=DC_OK)continue;
        uint32_t mapTriangles=[self projectedTrianglesForModel:_map.model camera:&matrices viewport:&viewport];uint32_t actorTriangles=[self projectedTrianglesForModel:_actor.model camera:&matrices viewport:&viewport];uint32_t faceTriangles=[self projectedTrianglesForModel:_face.model camera:&matrices viewport:&viewport];
        if(!actorTriangles||!faceTriangles)continue;uint64_t score=(uint64_t)mapTriangles*1000u+(uint64_t)actorTriangles*10u+faceTriangles;if(!found||score>bestScore){found=YES;bestScore=score;best=candidate;}
    }
    if(found){_cameraBase=best.base;_cameraDistance=best.stored_distance;_cameraHeight=best.height;_cameraPitch=best.pitch;_cameraYaw=best.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];[_cameraFallbacks setObject:[NSValue valueWithBytes:&best objCType:@encode(dc_camera_orbit)] forKey:@(_mapSelector)];}
    _cameraAutoSelected=YES;return found?nil:@"No camera preset projects the actor";
}
- (NSString *)advanceToNextMap {
    if(_mapAdvanced)return nil;
    uint32_t nextSelector=UINT32_MAX,finished=0;
    if(dc_game_next_map_selector(_mapSelector,&nextSelector,&finished)!=DC_OK)return @"Current map is outside the playable sequence";
    if(finished){_mapAdvanced=YES;_gameFinished=YES;_interactionCompleted=YES;_playerSaveDirty=YES;return nil;}
    NSError *reason=nil;DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_10.pp"]] error:&reason];
    if(!archive)return reason.localizedDescription ?: @"Map archive could not be opened";
    NSString *nextName=[NSString stringWithFormat:@"mm00_%02u.xx",nextSelector];
    NSData *nextData=[self entry:nextName archive:archive error:nil];
    if(!nextData)return @"Next map resource is unavailable";
    NSString *nextAnimationName=[NSString stringWithFormat:@"mn00_%02u.xa",nextSelector];
    NSData *nextAnimation=[self entry:nextAnimationName archive:archive error:nil];
    NSString *nextMapLightName=[NSString stringWithFormat:@"mp00_%02u.xl",nextSelector];
    NSData *nextMapLightData=[self entry:nextMapLightName archive:archive error:nil];
    dc_xl_info nextMapLightInfo;dc_xl_light nextMapLight;
    if(!nextMapLightData || dc_xl_probe(nextMapLightData.bytes,nextMapLightData.length,&nextMapLightInfo)!=DC_OK ||
       !nextMapLightInfo.lights || dc_xl_light_at(nextMapLightData.bytes,nextMapLightData.length,0,&nextMapLight)!=DC_OK)
        return @"Next map variant XL light resource is unavailable";
    DCArchive *lightArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_07.pp"]] error:nil];
    NSData *nextLightData=lightArchive ? [self lightEntryForSelector:nextSelector archive:lightArchive] : nil;
    dc_xl_info nextLightInfo;dc_xl_light nextLight;
    if(!nextLightData || dc_xl_probe(nextLightData.bytes,nextLightData.length,&nextLightInfo)!=DC_OK ||
       !nextLightInfo.lights || dc_xl_light_at(nextLightData.bytes,nextLightData.length,0,&nextLight)!=DC_OK)
        return @"Next map XL light resource is unavailable";
    dc_game_model nextMap={0};nextMap.xxData=nextData;nextMap.xaData=nextAnimation;nextMap.world=gameIdentity();
    NSString *error=nil;if(![self openModel:&nextMap staticOnly:(nextAnimation==nil) error:&error]){[self detachModel:&nextMap];return error ?: @"Next map could not be loaded";}
    [self detachModel:&_map];_map=nextMap;_lightData=nextLightData;_lightInfo=nextLightInfo;_mapLight=nextLight;
    _mapVariantLightData=nextMapLightData;_mapVariantLightInfo=nextMapLightInfo;_mapVariantLight=nextMapLight;
    _map.world=gameIdentity();_mapSelector=nextSelector;
    const char *anchors[]={(nextSelector==1?"m_Nn_yuka_p_a":nextSelector==3?"m_Nn_yuka_r_a":nextSelector==4?"m_Nn_yuka_5_a":nextSelector==5?"m_Nn_yuka_5_a":nextSelector==6?"m_Nn_yuka_2b_a":"m_Nn_yuka_5_a"),"m_Nn_yuka_3_a","m_Nn_yuka_2f_a"};
    for(unsigned candidate=0;candidate<3;++candidate)for(uint32_t i=1;i<_map.info.nodes;++i){dc_xx_node node;if(dc_xx_node_at(_map.xx,i,&node)!=DC_OK)continue;const uint8_t *raw=(const uint8_t *)_map.xxData.bytes+node.name.offset;size_t n=0;while(n<node.name.length&&raw[n]!=255)++n;char decoded[40];if(n>=sizeof(decoded))continue;for(size_t j=0;j<n;++j)decoded[j]=(char)(raw[j]^255);decoded[n]=0;if(!strcmp(decoded,anchors[candidate])){dc_xx_node_matrix(_map.xx,i,&_actorWorld);_actor.world=_actorWorld;candidate=3;break;}}
    [self computeWalkBounds];
    const char *cameraName=nextSelector==1?"home_2f.cam":nextSelector==3?"home_3f.cam":nextSelector==4?"home_4f.cam":nextSelector==5?"home_5p.cam":"home_5p.cam";
    NSData *cameraData=[self entry:[NSString stringWithUTF8String:cameraName] archive:[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_03.pp"]] error:nil] error:nil];
    if(cameraData){dc_camera_orbit nextCamera;if(dc_camera_read_preset(cameraData.bytes,cameraData.length,0,&nextCamera)==DC_OK){_cameraBase=nextCamera.base;_cameraDistance=nextCamera.stored_distance;_cameraHeight=nextCamera.height;_cameraPitch=nextCamera.pitch;_cameraYaw=nextCamera.yaw;_cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];}}
    _player.min_x=_walkMinX;_player.max_x=_walkMaxX;_player.min_z=_walkMinZ;_player.max_z=_walkMaxZ;
    _player.x=fmaxf(_player.min_x,fminf(_player.max_x,_player.x));_player.z=fmaxf(_player.min_z,fminf(_player.max_z,_player.z));_player.map_selector=nextSelector;_playerSaveDirty=YES;
    _actor.world.values[12]=_player.x;_actor.world.values[14]=_player.z;
    _actorOriginX=_actorWorld.values[12];_actorOriginZ=_actorWorld.values[14];
    _face.world=_actor.world;
    _mapAdvanced=NO;_interactionCompleted=NO;_interactionActive=NO;_interactionState.active=0;_interactionState.completed=0;_cameraAutoSelected=NO;return nil;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer error:(NSString **)error {
    if(!(self=[super init]))return nil;_directory=[directory copy];_renderer=renderer;
    _cameraFallbacks=[NSMutableDictionary dictionary];
    NSError *reason=nil;DCArchive *mapArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_10.pp"]] error:&reason];
    DCArchive *actorArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_08.pp"]] error:&reason];
    DCArchive *faceArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_09.pp"]] error:&reason];
     DCArchive *auxiliaryArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_04.pp"]] error:&reason];
     DCArchive *lightArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_07.pp"]] error:&reason];
     if(!mapArchive || !actorArchive || !faceArchive || !auxiliaryArchive || !lightArchive) { if(error)*error=reason.localizedDescription;return nil; }
    _map.xxData=[self entry:@"mm00_00.xx" archive:mapArchive error:error];
    _actor.xxData=[self entry:@"am00_01.xx" archive:actorArchive error:error];
    _actor.xaData=[self entry:@"an00_02.xa" archive:actorArchive error:error];
    NSData *actorPlacement=[self entry:@"am00_01.plst" archive:actorArchive error:nil];
    _face.xxData=[self entry:@"ak00_00.xx" archive:faceArchive error:error];
    _face.xaData=[self entry:@"an00_01.xa" archive:faceArchive error:error];
     _eyesData=[self entry:@"ak00_00.eyes" archive:auxiliaryArchive error:error];
     _neckData=[self entry:@"am00_01.neck" archive:auxiliaryArchive error:error];
     if(!_map.xxData || !_actor.xxData || !_actor.xaData || !_face.xxData || !_face.xaData || !_eyesData || !_neckData)return nil;
    if(![self openModel:&_map staticOnly:YES error:error] || ![self openModel:&_actor staticOnly:NO error:error] ||
       ![self openModel:&_face staticOnly:YES error:error])return nil;
    NSString *morphError=nil;
    if(![self buildMorphCaches:&_face error:&morphError]) { if(error)*error=morphError ?: @"Game morph cache initialization failed";return nil; }
    if(dc_model_request(_actor.model,1,0)!=DC_OK) { if(error)*error=@"Game actor animation request failed"; return nil; }
    _actorHeadNode=[self placementNodeFromPLST:actorPlacement model:&_actor];
    if(_actorHeadNode==UINT32_MAX)_actorHeadNode=[self findNode:&_actor name:@"a_Nz_kubi2"];
    if(_actorHeadNode==UINT32_MAX)_actorHeadNode=[self findNode:&_actor name:@"a_Kp_kubi2"];
    dc_eyeneck_info eyesInfo,neckInfo;dc_eyeneck_span eyesRight,eyesLeft,neckHead;
    if(dc_eyeneck_probe(_eyesData.bytes,_eyesData.length,&eyesInfo)!=DC_OK ||
       dc_eyeneck_probe(_neckData.bytes,_neckData.length,&neckInfo)!=DC_OK ||
       eyesInfo.kind!=DC_EYENECK_EYES || eyesInfo.targets!=2 || eyesInfo.records!=5 ||
       neckInfo.kind!=DC_EYENECK_NECK || neckInfo.targets!=1 || neckInfo.records!=3 ||
       dc_eyeneck_target_at(_eyesData.bytes,_eyesData.length,0,&eyesRight)!=DC_OK ||
       dc_eyeneck_target_at(_eyesData.bytes,_eyesData.length,1,&eyesLeft)!=DC_OK ||
       dc_eyeneck_target_at(_neckData.bytes,_neckData.length,0,&neckHead)!=DC_OK ||
       ![self encodedSpan:eyesRight matchesName:@"a_Np_me_R" data:_eyesData] ||
       ![self encodedSpan:eyesLeft matchesName:@"a_Np_me_L" data:_eyesData] ||
       ![self encodedSpan:neckHead matchesName:@"a_Kp_kubi2" data:_neckData] ||
        [self findNode:&_face name:@"a_Np_me_R"]==UINT32_MAX ||
        [self findNode:&_face name:@"a_Np_me_L"]==UINT32_MAX ||
        [self findNode:&_actor name:@"a_Kp_kubi2"]==UINT32_MAX) {
         if(error)*error=@"Eyes/neck auxiliary binding failed";return nil;
     }
    if(![self loadMapVariantLightForSelector:0 archive:mapArchive error:error] ||
       ![self loadLightForSelector:0 archive:lightArchive error:error])return nil;
    for(uint32_t mesh=0;mesh<_actor.info.submeshes;++mesh) {
        uint32_t space=DC_MODEL_SPACE_LOCAL;
        if(dc_model_vertex_space(_actor.model,mesh,&space)!=DC_OK) { if(error)*error=@"Actor skin profile query failed";return nil; }
        if(space==DC_MODEL_SPACE_WORLD)++_actorSkinMeshCount;
    }
    uint32_t anchor=[self findAnchor:&_map];
    _actorWorld=gameIdentity();
    if(anchor!=UINT32_MAX && dc_xx_node_matrix(_map.xx,anchor,&_actorWorld)!=DC_OK)_actorWorld=gameIdentity();
    _cameraBase=gameIdentity();
    _cameraPreset=0;
    NSString *camPath=[directory stringByAppendingPathComponent:@"RPP_03.pp"];
    DCArchive *camArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:camPath] error:nil];
    NSData *camData=nil;
    for(uint32_t i=0;camArchive && i<camArchive.entryCount;++i) {
        NSString *name=[camArchive asciiNameAtIndex:i];
        if([name caseInsensitiveCompare:@"home_sh.cam"]==NSOrderedSame) {camData=[camArchive readEntryAtIndex:i limit:4096 error:nil];break;}
    }
    dc_camera_orbit orbit;
    if(!camData || dc_camera_read_preset(camData.bytes,camData.length,0,&orbit)!=DC_OK)
        orbit=(dc_camera_orbit){.base=gameIdentity(),.stored_distance=-1.5f};
    _cameraBase=orbit.base;
    _cameraDistance=orbit.stored_distance;_cameraHeight=orbit.height;_cameraPitch=orbit.pitch;_cameraYaw=orbit.yaw;
    _cameraAutoSelected=NO;
    _actor.world=_actorWorld;
    _face.world=_actorWorld;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _actorOriginX=_actorWorld.values[12];_actorOriginZ=_actorWorld.values[14];
    [self computeWalkBounds];
    _player.x=_actor.world.values[12];_player.z=_actor.world.values[14];
    _player.min_x=_walkMinX;_player.max_x=_walkMaxX;_player.min_z=_walkMinZ;_player.max_z=_walkMaxZ;_player.speed=8;
    [self loadPlayerState];
    uint32_t savedMap=_player.map_selector;while(_mapSelector<savedMap){NSString *advanceError=[self advanceToNextMap];if(advanceError)break;}
    _loaded=YES;return self;
}
- (void)detachModel:(dc_game_model *)slot {
    if(_renderer)for(uint32_t i=0;i<slot->textureCount;++i)if(slot->textures[i])dc_vk_sprite_remove_texture(_renderer,slot->textures[i]);
    freeMorphCaches(slot);
    free(slot->textures);slot->textures=NULL;slot->textureCount=0;
    if(slot->model)dc_model_close(slot->model);if(slot->xx)dc_xx_close(slot->xx);
    slot->model=NULL;slot->xx=NULL;
}
- (void)detachRenderer { _renderer=NULL; }
- (void)dealloc { [self savePlayerState];free(_surfaces);[self detachModel:&_map];[self detachModel:&_actor];[self detachModel:&_face]; }

- (uint32_t)textureFor:(dc_game_model *)slot mesh:(const dc_xx_submesh *)mesh {
    dc_xx_material material;if(dc_xx_material_at(slot->xx,mesh->material,&material)!=DC_OK)return UINT32_MAX;
    for(uint32_t i=0;i<slot->info.textures;++i) {
        dc_xx_texture texture;if(dc_xx_texture_at(slot->xx,i,&texture)!=DC_OK)continue;
        const uint8_t *a=(const uint8_t *)slot->xxData.bytes+material.texture_names[0].offset;
        const uint8_t *b=(const uint8_t *)slot->xxData.bytes+texture.name.offset;size_t an=0,bn=0;
        while(an<material.texture_names[0].length&&a[an]!=255)++an;while(bn<texture.name.length&&b[bn]!=255)++bn;
        if(an==bn&&an<material.texture_names[0].length&&bn<texture.name.length&&!memcmp(a,b,an))return i;
    }
    return UINT32_MAX;
}

- (uint32_t)morphVectorNamed:(NSString *)name model:(dc_game_model *)slot {
    if(!slot->xaData || !name.length) return UINT32_MAX;
    for(uint32_t i=0;i<slot->xaInfo.morph_vector_sets;++i) {
        dc_xa_morph_vector_set view;
        if(dc_xa_morph_vector_set_at(slot->xaData.bytes,slot->xaData.length,i,&view)!=DC_OK) return UINT32_MAX;
        NSString *decoded=[self decodedName:(const uint8_t *)slot->xaData.bytes+view.data_offset length:view.data_length];
        if([decoded isEqualToString:name]) return i;
    }
    return UINT32_MAX;
}

- (uint32_t)morphIndexSetNamed:(NSString *)name model:(dc_game_model *)slot {
    if(!slot->xaData || !name.length) return UINT32_MAX;
    for(uint32_t i=0;i<slot->xaInfo.morph_index_sets;++i) {
        dc_xa_morph_index_set view;
        if(dc_xa_morph_index_set_at(slot->xaData.bytes,slot->xaData.length,i,&view)!=DC_OK) return UINT32_MAX;
        NSString *decoded=[self decodedName:(const uint8_t *)slot->xaData.bytes+view.data_offset length:view.data_length];
        if([decoded isEqualToString:name]) return i;
    }
    return UINT32_MAX;
}

- (NSString *)morphVectorNameForTrack:(uint32_t)track model:(dc_game_model *)slot frame:(float)frame {
    if(!slot->xaData || track>=slot->xaInfo.morph_tracks) return nil;
    dc_xa_morph_track view;
    if(dc_xa_morph_track_at(slot->xaData.bytes,slot->xaData.length,track,&view)!=DC_OK) return nil;
    uint32_t selected=UINT32_MAX,selectedFrame=0;
    for(uint32_t keyIndex=0;keyIndex<view.key_count;++keyIndex) {
        dc_xa_morph_key key;
        if(dc_xa_morph_key_at(slot->xaData.bytes,slot->xaData.length,track,keyIndex,&key)!=DC_OK)return nil;
        uint32_t keyFrame=0;memcpy(&keyFrame,key.raw,sizeof(keyFrame));
        if(selected==UINT32_MAX || ((float)keyFrame<=frame && keyFrame>=selectedFrame)) {
            if((float)keyFrame<=frame || selected==UINT32_MAX) { selected=keyIndex;selectedFrame=keyFrame; }
        }
    }
    if(selected==UINT32_MAX)return nil;
    dc_xa_morph_key key;
    if(dc_xa_morph_key_at(slot->xaData.bytes,slot->xaData.length,track,selected,&key)!=DC_OK)return nil;
    return [self decodedName:(const uint8_t *)slot->xaData.bytes+key.value_offset length:key.value_length];
}

- (uint32_t)morphMeshForVectorName:(NSString *)vectorName model:(dc_game_model *)slot {
    NSRange marker=[vectorName rangeOfString:@"_n" options:NSBackwardsSearch];
    if(marker.location==NSNotFound || marker.location==0)return UINT32_MAX;
    NSString *nodeName=[vectorName substringToIndex:marker.location];
    for(uint32_t mesh=0;mesh<slot->info.submeshes;++mesh) {
        dc_xx_submesh meshView;if(dc_model_mesh(slot->model,mesh,&meshView)!=DC_OK)continue;
        dc_xx_node node;if(dc_xx_node_at(slot->xx,meshView.node,&node)!=DC_OK)continue;
        NSString *meshNode=[self decodedName:(const uint8_t *)slot->xxData.bytes+node.name.offset length:node.name.length];
        if([meshNode isEqualToString:nodeName])return mesh;
    }
    return UINT32_MAX;
}

- (BOOL)buildMorphCaches:(dc_game_model *)slot error:(NSString **)error {
    freeMorphCaches(slot);
    if(!slot->xaData || !slot->xaInfo.morph_tracks)return YES;
    slot->morphTrackCount=slot->xaInfo.morph_tracks;
    slot->morphTracks=calloc(slot->morphTrackCount,sizeof(*slot->morphTracks));
    if(!slot->morphTracks){slot->morphTrackCount=0;if(error)*error=@"Game morph cache allocation failed";return NO;}
    dc_xa_morph_vector_set *vectorViews=calloc(slot->xaInfo.morph_vector_sets?slot->xaInfo.morph_vector_sets:1,sizeof(*vectorViews));
    if(!vectorViews || dc_xa_load_morph_vector_sets(slot->xaData.bytes,slot->xaData.length,vectorViews,slot->xaInfo.morph_vector_sets)!=DC_OK) {
        free(vectorViews);freeMorphCaches(slot);if(error)*error=@"Game morph vector table failed";return NO;
    }
    NSMutableDictionary<NSString *,NSValue *> *vectorTable=[NSMutableDictionary dictionaryWithCapacity:slot->xaInfo.morph_vector_sets];
    for(uint32_t i=0;i<slot->xaInfo.morph_vector_sets;++i) {
        NSString *name=[self decodedName:(const uint8_t *)slot->xaData.bytes+vectorViews[i].data_offset length:vectorViews[i].data_length];
        dc_morph_key_cache ref={.frame=0,.vectorsOffset=vectorViews[i].vectors_offset,.count=vectorViews[i].count};
        if(name)[vectorTable setObject:[NSValue valueWithBytes:&ref objCType:@encode(dc_morph_key_cache)] forKey:name];
    }
    for(uint32_t track=0;track<slot->morphTrackCount;++track) {
        dc_xa_morph_track trackView;
        if(dc_xa_morph_track_at(slot->xaData.bytes,slot->xaData.length,track,&trackView)!=DC_OK) { if(error)*error=@"Game morph track cache metadata failed";free(vectorViews);freeMorphCaches(slot);return NO; }
        NSString *target=[self decodedName:(const uint8_t *)slot->xaData.bytes+trackView.target_offset length:trackView.target_length];
        uint32_t indexSet=[self morphIndexSetNamed:target model:slot];
        if(indexSet==UINT32_MAX) { if(error)*error=@"Game morph cache target is unavailable";free(vectorViews);freeMorphCaches(slot);return NO; }
        dc_xa_morph_index_set indexView;
        if(dc_xa_morph_index_set_at(slot->xaData.bytes,slot->xaData.length,indexSet,&indexView)!=DC_OK) { if(error)*error=@"Game morph cache index metadata failed";free(vectorViews);freeMorphCaches(slot);return NO; }
        dc_morph_track_cache *cache=&slot->morphTracks[track];cache->meshIndex=UINT32_MAX;cache->indexCount=indexView.count;
        cache->indices=calloc(indexView.count?indexView.count:1,sizeof(*cache->indices));
        if(!cache->indices || dc_xa_load_morph_indices(slot->xaData.bytes,slot->xaData.length,indexSet,cache->indices,indexView.count)!=DC_OK) { if(error)*error=@"Game morph cache indices failed";free(vectorViews);freeMorphCaches(slot);return NO; }
        cache->keyCount=trackView.key_count;cache->keys=calloc(cache->keyCount?cache->keyCount:1,sizeof(*cache->keys));
        if(!cache->keys){if(error)*error=@"Game morph cache key allocation failed";free(vectorViews);freeMorphCaches(slot);return NO;}
        for(uint32_t keyIndex=0;keyIndex<cache->keyCount;++keyIndex) {
            dc_xa_morph_key key;if(dc_xa_morph_key_at(slot->xaData.bytes,slot->xaData.length,track,keyIndex,&key)!=DC_OK){if(error)*error=@"Game morph cache key metadata failed";free(vectorViews);freeMorphCaches(slot);return NO;}
            uint32_t frame=0;memcpy(&frame,key.raw,sizeof(frame));NSString *vectorName=[self decodedName:(const uint8_t *)slot->xaData.bytes+key.value_offset length:key.value_length];
            NSValue *boxed=vectorTable[vectorName];dc_morph_key_cache ref={0};
            if(!boxed){if(error)*error=@"Game morph cache vector metadata failed";free(vectorViews);freeMorphCaches(slot);return NO;}
            [boxed getValue:&ref];ref.frame=frame;cache->keys[keyIndex]=ref;
            if(keyIndex==0)cache->meshIndex=[self morphMeshForVectorName:vectorName model:slot];
        }
        if(cache->meshIndex==UINT32_MAX || cache->meshIndex>=slot->info.submeshes){if(error)*error=@"Game morph cache mesh binding failed";free(vectorViews);freeMorphCaches(slot);return NO;}
    }
    free(vectorViews);
    return YES;
}

- (BOOL)applyMorphsToModel:(dc_game_model *)slot frame:(float)frame
    buffers:(dc_mesh_vertex **)buffers counts:(const uint32_t *)counts error:(NSString **)error {
    if(!slot->xaData || !slot->morphTrackCount)return YES;
    for(uint32_t track=0;track<slot->morphTrackCount;++track) {
        dc_morph_track_cache *cache=&slot->morphTracks[track];
        if(!cache->keyCount || cache->meshIndex>=slot->info.submeshes){if(error)*error=@"Game morph cache is incomplete";return NO;}
        uint32_t selected=0;
        for(uint32_t key=1;key<cache->keyCount;++key) {
            if((float)cache->keys[key].frame<=frame)selected=key;else break;
        }
        dc_morph_key_cache *vector=&cache->keys[selected];uint32_t meshIndex=cache->meshIndex;
        if(!buffers[meshIndex] || counts[meshIndex]!=vector->count){if(error)*error=@"Game morph vertex count mismatch";return NO;}
        const uint8_t *source=(const uint8_t *)slot->xaData.bytes+vector->vectorsOffset;size_t positionBytes=(size_t)vector->count*3*sizeof(float);
        for(uint32_t i=0;i<cache->indexCount;++i) {
            uint32_t packed=cache->indices[i];uint32_t ids[2]={packed>>16,packed&0xffffu};
            for(uint32_t side=0;side<2;++side) {
                uint32_t vertex=ids[side];if(vertex>=vector->count){if(error)*error=@"Game morph vertex index is out of range";return NO;}
                memcpy(buffers[meshIndex][vertex].position,source+(size_t)vertex*3*sizeof(float),3*sizeof(float));
                memcpy(buffers[meshIndex][vertex].normal,source+positionBytes+(size_t)vertex*3*sizeof(float),3*sizeof(float));
            }
        }
    }
    return YES;
}
- (NSString *)append:(dc_game_model *)slot delta:(uint32_t)delta tick:(uint32_t)tick camera:(const dc_camera_matrices *)camera
    viewport:(const dc_viewport *)viewport draws:(dc_vk_geometry_item *)draws count:(size_t *)count storage:(NSMutableArray *)storage triangles:(uint32_t *)triangles {
    dc_matrix world=slot->world;dc_status status=dc_model_tick(slot->model,delta,tick,&world);if(status!=DC_OK)return @"Game model tick failed";
    dc_mesh_vertex **morphVertices=NULL;uint32_t *morphCounts=NULL;
    if(slot->xaInfo.morph_tracks) {
        morphVertices=calloc(slot->info.submeshes?slot->info.submeshes:1,sizeof(*morphVertices));
        morphCounts=calloc(slot->info.submeshes?slot->info.submeshes:1,sizeof(*morphCounts));
        if(!morphVertices||!morphCounts){free(morphVertices);free(morphCounts);return @"Game morph buffer allocation failed";}
        for(uint32_t mesh=0;mesh<slot->info.submeshes;++mesh) {
            dc_xx_submesh meshView;if(dc_model_mesh(slot->model,mesh,&meshView)!=DC_OK) { free(morphVertices);free(morphCounts);return @"Game morph mesh metadata failed"; }
            morphCounts[mesh]=meshView.vertex_count;
            morphVertices[mesh]=calloc(meshView.vertex_count?meshView.vertex_count:1,sizeof(*morphVertices[mesh]));
            if(!morphVertices[mesh] || dc_model_load_vertices(slot->model,mesh,morphVertices[mesh],meshView.vertex_count)!=DC_OK) {
                for(uint32_t j=0;j<=mesh;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph vertex load failed";
            }
        }
        dc_animation_state actorAnimation;float morphFrame=0;
        if(dc_model_get_animation(_actor.model,&actorAnimation)==DC_OK) morphFrame=actorAnimation.frame*256.0f;
        NSString *morphError=nil;
        if(![self applyMorphsToModel:slot frame:morphFrame buffers:morphVertices counts:morphCounts error:&morphError]) {
            for(uint32_t mesh=0;mesh<slot->info.submeshes;++mesh)free(morphVertices[mesh]);free(morphVertices);free(morphCounts);return morphError ?: @"Game morph application failed";
        }
    }
    for(uint32_t i=0;i<slot->info.submeshes;++i) {
        uint32_t visible;if(dc_model_mesh_visible(slot->model,i,&visible)!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game mesh visibility failed";}if(!visible)continue;
        dc_xx_submesh mesh;dc_material_value material;if(dc_model_mesh(slot->model,i,&mesh)!=DC_OK||dc_model_material(slot->model,mesh.material,&material)!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game mesh metadata failed";}
        if(material.components[3]<=0)continue;uint32_t texture=[self textureFor:slot mesh:&mesh];if(texture==UINT32_MAX){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices?morphVertices[j]:NULL);free(morphVertices);free(morphCounts);return @"Game material texture not found";}
        size_t vertexCount=0;
        if(morphVertices) {
            uint16_t *indices=calloc(mesh.index_count?mesh.index_count:1,sizeof(*indices));dc_matrix mvp=camera->view_projection;uint32_t space=0;
            if(!indices || dc_xx_load_mesh_indices(slot->xx,i,indices,mesh.index_count)!=DC_OK || dc_model_vertex_space(slot->model,i,&space)!=DC_OK) { free(indices);for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh projection setup failed"; }
            if(space==DC_MODEL_SPACE_LOCAL) { dc_matrix global;if(dc_model_global(slot->model,mesh.node,&global)!=DC_OK || dc_matrix_multiply(&global,&camera->view_projection,&mvp)!=DC_OK) { free(indices);for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph node transform failed"; } }
            status=dc_mesh_clip_project(morphVertices[i],morphCounts[i],indices,mesh.index_count,&mvp,viewport,gameColor(&material),NULL,0,&vertexCount);if(status!=DC_OK){free(indices);for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh clip query failed";}
            if(!vertexCount){free(indices);continue;}
            NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];status=dc_mesh_clip_project(morphVertices[i],morphCounts[i],indices,mesh.index_count,&mvp,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);free(indices);if(status!=DC_OK){for(uint32_t j=0;j<slot->info.submeshes;++j)free(morphVertices[j]);free(morphVertices);free(morphCounts);return @"Game morph mesh projection failed";}
            [storage addObject:vertices];draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=slot->textures[texture],.blend_mode=3,.depth_mode=DC_VK_DEPTH_WRITE};*triangles+=(uint32_t)(vertexCount/3);continue;
        }
        status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),NULL,0,&vertexCount);if(status!=DC_OK){return @"Game mesh clip query failed";}if(!vertexCount)continue;
        NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);if(status!=DC_OK)return @"Game mesh projection failed";
        [storage addObject:vertices];
        draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=slot->textures[texture],.blend_mode=3,.depth_mode=DC_VK_DEPTH_WRITE};
        *triangles+=(uint32_t)(vertexCount/3);
    }
    if(morphVertices){for(uint32_t i=0;i<slot->info.submeshes;++i)free(morphVertices[i]);free(morphVertices);free(morphCounts);}
    return nil;
}
- (NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching
    width:(uint32_t)width height:(uint32_t)height {
    if(!_loaded)return @"Game scene is not loaded";
    BOOL newTouch=touching&&!_inputInitialized;
    float nearOriginX=_actorOriginX-_actor.world.values[12],nearOriginZ=_actorOriginZ-_actor.world.values[14];
    BOOL nearInteraction=fabsf(nearOriginX)<12.0f&&fabsf(nearOriginZ)<12.0f;
    dc_game_interaction_input interactionInput={.tick=tick,.new_touch=newTouch,.near_target=nearInteraction};
    dc_game_interaction_state interactionNext;dc_game_interaction_result interactionResult;
    if(dc_game_interaction_step(&_interactionState,&interactionInput,&interactionNext,&interactionResult)!=DC_OK)return @"Game interaction state update failed";
    if(interactionResult.begin) {
        if(dc_model_request(_actor.model,2,tick)!=DC_OK)return @"Game interaction animation request failed";
    } else if(interactionResult.restore) {
        if(dc_model_request(_actor.model,1,tick)!=DC_OK)return @"Game interaction animation restore failed";
    }
    _interactionState=interactionNext;_interactionActive=_interactionState.active;_interactionStartTick=_interactionState.start_tick;_interactionCount=_interactionState.interaction_count;
    if(interactionResult.completed){_interactionCompleted=YES;_player.interaction_count=_interactionCount;_playerSaveDirty=YES;}
    if(touching) {
        if(_inputInitialized) {
            float dx=fmaxf(-.15f,fminf(.15f,x-_lastInputX));
            float dz=fmaxf(-.15f,fminf(.15f,y-_lastInputY));
            dc_game_player next;
            dc_game_input input={.axis_x=dx/.15f,.axis_z=-dz/.15f,.touching=1};
            if(dc_game_player_step(&_player,&input,.1f,&next)==DC_OK){_player=next;_playerSaveDirty=YES;_actor.world.values[12]=next.x;_actor.world.values[14]=next.z;float floorY;if([self surfaceYAtX:next.x z:next.z nearY:_actor.world.values[13] result:&floorY])_actor.world.values[13]=floorY;}
        }
        _lastInputX=x;_lastInputY=y;_inputInitialized=YES;
    } else { _inputInitialized=NO;[self savePlayerState]; }
    if(_interactionCompleted&&!_mapAdvanced){NSString *mapError=[self advanceToNextMap];if(mapError)return mapError;}
    uint32_t delta=_tickInitialized ? tick-_lastTick : 0;_tickInitialized=YES;_lastTick=tick;
    NSString *cameraSelectionError=[self autoSelectCameraAtTick:tick];if(cameraSelectionError)return cameraSelectionError;
    dc_camera_orbit orbit={.base=_cameraBase,.stored_distance=_cameraDistance,.height=_cameraHeight,.pitch=_cameraPitch,.yaw=_cameraYaw};
    float followX=fmaxf(-40.0f,fminf(40.0f,_actor.world.values[12]-_actorOriginX));
    float followZ=fmaxf(-40.0f,fminf(40.0f,_actor.world.values[14]-_actorOriginZ));
    orbit.base.values[12]=_cameraOriginX+followX*.65f;
    orbit.base.values[14]=_cameraOriginZ+followZ*.65f;
    dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices camera;
    if(dc_camera_build(&orbit,&lens,&camera)!=DC_OK)return @"Game camera build failed";
    float scale=fminf((float)width/1024,(float)height/768);dc_viewport viewport={(width-1024*scale)*.5f,(height-768*scale)*.5f,1024*scale,768*scale,0,1};
    size_t capacity=_map.info.submeshes+_actor.info.submeshes+_face.info.submeshes;dc_vk_geometry_item *draws=calloc(capacity,sizeof(*draws));NSMutableArray *storage=[NSMutableArray array];size_t count=0;_visibleMapTriangles=_visibleActorTriangles=0;
    NSString *failure=[self append:&_map delta:delta tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleMapTriangles];
    if(!failure)failure=[self append:&_actor delta:delta tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure && delta && _actorSkinMeshCount)_actorSkinAdvanced=YES;
    if(!failure && _face.model) {
        if(_actorHeadNode!=UINT32_MAX && dc_model_global(_actor.model,_actorHeadNode,&_face.world)!=DC_OK)
            failure=@"Game face anchor lookup failed";
        if(!failure)failure=[self append:&_face delta:0 tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    }
    if(!failure) { uint32_t left=(uint32_t)fmaxf(0,ceilf(viewport.x-.5f)),top=(uint32_t)fmaxf(0,ceilf(viewport.y-.5f)),right=(uint32_t)fminf(width,ceilf(viewport.x+viewport.width-.5f)),bottom=(uint32_t)fminf(height,ceilf(viewport.y+viewport.height-.5f));dc_vk_clip_rect clip={left,top,right-left,bottom-top};uint8_t clear[4]={0,0,0,255};if(dc_vk_geometry_render_region(_renderer,draws,count,clear,NULL,0,&clip)!=DC_OK)failure=@"Game Vulkan draw failed";}
    free(draws);return failure;
}
@end
