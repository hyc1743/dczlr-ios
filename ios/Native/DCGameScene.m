#import "DCGameScene.h"
#import "DCArchive.h"
#include "dc_camera.h"
#include "dc_model.h"
#include <math.h>
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
    uint32_t _cameraPreset;
    uint32_t _lastTick; BOOL _tickInitialized;
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
    _loaded=YES;return self;
}
- (void)detachModel:(dc_game_model *)slot {
    if(_renderer)for(uint32_t i=0;i<slot->textureCount;++i)if(slot->textures[i])dc_vk_sprite_remove_texture(_renderer,slot->textures[i]);
    free(slot->textures);slot->textures=NULL;slot->textureCount=0;
    if(slot->model)dc_model_close(slot->model);if(slot->xx)dc_xx_close(slot->xx);
    slot->model=NULL;slot->xx=NULL;
}
- (void)detachRenderer { _renderer=NULL; }
- (void)dealloc { [self detachModel:&_map];[self detachModel:&_actor]; }

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
        uint8_t blend=material.components[3] < .999f ? 3 : 0;
        draws[(*count)++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=vertexCount,.texture=slot->textures[texture],.blend_mode=blend,.depth_mode=DC_VK_DEPTH_WRITE};
        *triangles+=(uint32_t)(vertexCount/3);
    }
    return nil;
}
- (NSString *)drawAtTick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height {
    if(!_loaded)return @"Game scene is not loaded";
    uint32_t delta=_tickInitialized ? tick-_lastTick : 0;_tickInitialized=YES;_lastTick=tick;
    dc_camera_orbit orbit={.base=_cameraBase,.stored_distance=-1.5f,.height=0,.pitch=0,.yaw=0};dc_camera_lens lens={.3f,.5f,10000,1024,768};dc_camera_matrices camera;
    if(dc_camera_build(&orbit,&lens,&camera)!=DC_OK)return @"Game camera build failed";
    float scale=fminf((float)width/1024,(float)height/768);dc_viewport viewport={(width-1024*scale)*.5f,(height-768*scale)*.5f,1024*scale,768*scale,0,1};
    size_t capacity=_map.info.submeshes+_actor.info.submeshes;dc_vk_geometry_item *draws=calloc(capacity,sizeof(*draws));NSMutableArray *storage=[NSMutableArray array];size_t count=0;_visibleMapTriangles=_visibleActorTriangles=0;
    NSString *failure=[self append:&_map delta:delta tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleMapTriangles];if(!failure)failure=[self append:&_actor delta:delta tick:tick camera:&camera viewport:&viewport draws:draws count:&count storage:storage triangles:&_visibleActorTriangles];
    if(!failure) { uint32_t left=(uint32_t)fmaxf(0,ceilf(viewport.x-.5f)),top=(uint32_t)fmaxf(0,ceilf(viewport.y-.5f)),right=(uint32_t)fminf(width,ceilf(viewport.x+viewport.width-.5f)),bottom=(uint32_t)fminf(height,ceilf(viewport.y+viewport.height-.5f));dc_vk_clip_rect clip={left,top,right-left,bottom-top};uint8_t clear[4]={0,0,0,255};if(dc_vk_geometry_render_region(_renderer,draws,count,clear,NULL,0,&clip)!=DC_OK)failure=@"Game Vulkan draw failed";}
    free(draws);return failure;
}
@end
