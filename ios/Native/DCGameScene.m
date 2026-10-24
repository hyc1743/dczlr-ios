#import "DCGameScene.h"
#import "DCArchive.h"
#include "dc_camera.h"
#include "dc_gameplay.h"
#include "dc_model.h"
#include <math.h>
#include <float.h>
#include <stdio.h>
#include <string.h>

typedef struct dc_game_model {
    __strong NSData *xxData,*xaData;
    dc_model *model;
    dc_xx *xx;
    dc_xx_info info;
    uintptr_t *textures;
    uint32_t textureCount;
    dc_matrix world;
} dc_game_model;
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

@implementation DCGameScene {
    NSString *_directory;
    dc_vk_sprite *_renderer;
    dc_game_model _map,_actor;
    dc_matrix _cameraBase,_actorWorld;
    float _cameraOriginX,_cameraOriginZ,_actorOriginX,_actorOriginZ;
    uint32_t _cameraPreset;
    uint32_t _lastTick; BOOL _tickInitialized;
    float _lastInputX,_lastInputY; BOOL _inputInitialized;
    float _walkMinX,_walkMaxX,_walkMinZ,_walkMaxZ;
    dc_game_player _player;
    dc_walk_surface *_surfaces;size_t _surfaceCount,_surfaceCapacity;
    BOOL _loaded;
    uint32_t _visibleMapTriangles,_visibleActorTriangles;
}
- (BOOL)loaded { return _loaded; }
- (uint32_t)visibleMapTriangles { return _visibleMapTriangles; }
- (uint32_t)visibleActorTriangles { return _visibleActorTriangles; }

- (NSData *)entry:(NSString *)name archive:(DCArchive *)archive error:(NSString **)error {
    for(uint32_t i=0;i<archive.entryCount;++i)
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame)
            return [archive readEntryAtIndex:i limit:128*1024*1024 error:nil];
    if(error)*error=[NSString stringWithFormat:@"Missing game resource %@",name];
    return nil;
}
- (BOOL)openModel:(dc_game_model *)slot staticOnly:(BOOL)staticOnly error:(NSString **)error {
    dc_status status=staticOnly ? dc_model_open_static(slot->xxData.bytes,slot->xxData.length,&slot->model)
        : dc_model_open(slot->xxData.bytes,slot->xxData.length,slot->xaData.bytes,slot->xaData.length,&slot->model);
    if(status!=DC_OK) { if(error)*error=[NSString stringWithFormat:@"Game model open failed: %d",status]; return NO; }
    status=dc_xx_open(slot->xxData.bytes,slot->xxData.length,&slot->xx);
    if(status==DC_OK)status=dc_model_get_info(slot->model,&slot->info);
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
    _player=(dc_game_player){.x=_actor.world.values[12],.z=_actor.world.values[14],.min_x=_walkMinX,.max_x=_walkMaxX,.min_z=_walkMinZ,.max_z=_walkMaxZ,.speed=8};
}
- (BOOL)surfaceYAtX:(float)x z:(float)z nearY:(float)nearY result:(float *)result {
    BOOL found=NO;float best=0,bestDistance=FLT_MAX;
    for(size_t i=0;i<_surfaceCount;++i){dc_walk_surface *s=&_surfaces[i];float den=(s->z[1]-s->z[2])*(s->x[0]-s->x[2])+(s->x[2]-s->x[1])*(s->z[0]-s->z[2]);if(fabsf(den)<1e-5f)continue;float a=((s->z[1]-s->z[2])*(x-s->x[2])+(s->x[2]-s->x[1])*(z-s->z[2]))/den;float b=((s->z[2]-s->z[0])*(x-s->x[2])+(s->x[0]-s->x[2])*(z-s->z[2]))/den;float c=1-a-b;if(a<-.01f||b<-.01f||c<-.01f)continue;float y=a*s->y[0]+b*s->y[1]+c*s->y[2],distance=fabsf(y-nearY);if(distance<bestDistance){bestDistance=distance;best=y;found=YES;}}
    if(found&&result)*result=best;return found;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer error:(NSString **)error {
    if(!(self=[super init]))return nil;_directory=[directory copy];_renderer=renderer;
    NSError *reason=nil;DCArchive *mapArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_10.pp"]] error:&reason];
    DCArchive *actorArchive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_08.pp"]] error:&reason];
    if(!mapArchive || !actorArchive) { if(error)*error=reason.localizedDescription;return nil; }
    _map.xxData=[self entry:@"mm00_00.xx" archive:mapArchive error:error];
    _actor.xxData=[self entry:@"am00_01.xx" archive:actorArchive error:error];
    _actor.xaData=[self entry:@"an00_02.xa" archive:actorArchive error:error];
    if(!_map.xxData || !_actor.xxData || !_actor.xaData)return nil;
    if(![self openModel:&_map staticOnly:YES error:error] || ![self openModel:&_actor staticOnly:NO error:error])return nil;
    if(dc_model_request(_actor.model,1,0)!=DC_OK) { if(error)*error=@"Game actor animation request failed"; return nil; }
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
    _actor.world=_actorWorld;
    _cameraOriginX=_cameraBase.values[12];_cameraOriginZ=_cameraBase.values[14];
    _actorOriginX=_actorWorld.values[12];_actorOriginZ=_actorWorld.values[14];
    [self computeWalkBounds];
    _player.x=_actor.world.values[12];_player.z=_actor.world.values[14];
    _player.min_x=_walkMinX;_player.max_x=_walkMaxX;_player.min_z=_walkMinZ;_player.max_z=_walkMaxZ;_player.speed=8;
    _loaded=YES;return self;
}
- (void)detachModel:(dc_game_model *)slot {
    if(_renderer)for(uint32_t i=0;i<slot->textureCount;++i)if(slot->textures[i])dc_vk_sprite_remove_texture(_renderer,slot->textures[i]);
    free(slot->textures);slot->textures=NULL;slot->textureCount=0;
    if(slot->model)dc_model_close(slot->model);if(slot->xx)dc_xx_close(slot->xx);
    slot->model=NULL;slot->xx=NULL;
}
- (void)detachRenderer { _renderer=NULL; }
- (void)dealloc { free(_surfaces);[self detachModel:&_map];[self detachModel:&_actor]; }

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
- (NSString *)append:(dc_game_model *)slot delta:(uint32_t)delta tick:(uint32_t)tick camera:(const dc_camera_matrices *)camera
    viewport:(const dc_viewport *)viewport draws:(dc_vk_geometry_item *)draws count:(size_t *)count storage:(NSMutableArray *)storage triangles:(uint32_t *)triangles {
    dc_matrix world=slot->world;dc_status status=dc_model_tick(slot->model,delta,tick,&world);if(status!=DC_OK)return @"Game model tick failed";
    for(uint32_t i=0;i<slot->info.submeshes;++i) {
        uint32_t visible;if(dc_model_mesh_visible(slot->model,i,&visible)!=DC_OK)return @"Game mesh visibility failed";if(!visible)continue;
        dc_xx_submesh mesh;dc_material_value material;if(dc_model_mesh(slot->model,i,&mesh)!=DC_OK||dc_model_material(slot->model,mesh.material,&material)!=DC_OK)return @"Game mesh metadata failed";
        if(material.components[3]<=0)continue;uint32_t texture=[self textureFor:slot mesh:&mesh];if(texture==UINT32_MAX)return @"Game material texture not found";
        size_t vertexCount=0;status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),NULL,0,&vertexCount);if(status!=DC_OK)return @"Game mesh clip query failed";if(!vertexCount)continue;
        NSMutableData *vertices=[NSMutableData dataWithLength:vertexCount*sizeof(dc_sprite_vertex)];status=dc_model_project_clipped(slot->model,i,&camera->view_projection,viewport,gameColor(&material),vertices.mutableBytes,vertexCount,&vertexCount);if(status!=DC_OK)return @"Game mesh projection failed";
        [storage addObject:vertices];
        draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=slot->textures[texture],.blend_mode=3,.depth_mode=DC_VK_DEPTH_WRITE};
        *triangles+=(uint32_t)(vertexCount/3);
    }
    return nil;
}
- (NSString *)drawAtTick:(uint32_t)tick inputX:(float)x inputY:(float)y touching:(BOOL)touching
    width:(uint32_t)width height:(uint32_t)height {
    if(!_loaded)return @"Game scene is not loaded";
    if(touching) {
        if(_inputInitialized) {
            float dx=fmaxf(-.15f,fminf(.15f,x-_lastInputX));
            float dz=fmaxf(-.15f,fminf(.15f,y-_lastInputY));
            dc_game_player next;
            dc_game_input input={.axis_x=dx/.15f,.axis_z=-dz/.15f,.touching=1};
            if(dc_game_player_step(&_player,&input,.1f,&next)==DC_OK){_player=next;_actor.world.values[12]=next.x;_actor.world.values[14]=next.z;float floorY;if([self surfaceYAtX:next.x z:next.z nearY:_actor.world.values[13] result:&floorY])_actor.world.values[13]=floorY;}
        }
        _lastInputX=x;_lastInputY=y;_inputInitialized=YES;
    } else _inputInitialized=NO;
    uint32_t delta=_tickInitialized ? tick-_lastTick : 0;_tickInitialized=YES;_lastTick=tick;
    dc_camera_orbit orbit={.base=_cameraBase,.stored_distance=-1.5f,.height=0,.pitch=0,.yaw=0};
    float followX=fmaxf(-40.0f,fminf(40.0f,_actor.world.values[12]-_actorOriginX));
    float followZ=fmaxf(-40.0f,fminf(40.0f,_actor.world.values[14]-_actorOriginZ));
    orbit.base.values[12]=_cameraOriginX+followX*.65f;
    orbit.base.values[14]=_cameraOriginZ+followZ*.65f;
    dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices camera;
    if(dc_camera_build(&orbit,&lens,&camera)!=DC_OK)return @"Game camera build failed";
    float scale=fminf((float)width/1024,(float)height/768);dc_viewport viewport={(width-1024*scale)*.5f,(height-768*scale)*.5f,1024*scale,768*scale,0,1};
    size_t capacity=_map.info.submeshes+_actor.info.submeshes;dc_vk_geometry_item *draws=calloc(capacity,sizeof(*draws));NSMutableArray *storage=[NSMutableArray array];size_t count=0;_visibleMapTriangles=_visibleActorTriangles=0;
    NSString *failure=[self append:&_map delta:delta tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleMapTriangles];if(!failure)failure=[self append:&_actor delta:delta tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure) { uint32_t left=(uint32_t)fmaxf(0,ceilf(viewport.x-.5f)),top=(uint32_t)fmaxf(0,ceilf(viewport.y-.5f)),right=(uint32_t)fminf(width,ceilf(viewport.x+viewport.width-.5f)),bottom=(uint32_t)fminf(height,ceilf(viewport.y+viewport.height-.5f));dc_vk_clip_rect clip={left,top,right-left,bottom-top};uint8_t clear[4]={0,0,0,255};if(dc_vk_geometry_render_region(_renderer,draws,count,clear,NULL,0,&clip)!=DC_OK)failure=@"Game Vulkan draw failed";}
    free(draws);return failure;
}
@end
