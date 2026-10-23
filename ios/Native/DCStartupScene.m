#import "DCStartupScene.h"
#import "DCArchive.h"
#include "dc_model.h"
#include "dc_startup.h"
#include <math.h>
#include <string.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

static dc_matrix dcStartupIdentity(void) { return (dc_matrix){{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}}; }
static uint32_t dcStartupColor(const dc_material_value *value) {
    uint32_t result=0;
    for (uint32_t i=0;i<4;++i) {
        float v=fminf(1,fmaxf(0,value->components[i]));
        uint32_t component=(uint32_t)(v*255);
        result |= component << (i==3 ? 24 : 16-i*8);
    }
    return result;
}

@implementation DCStartupScene {
    dc_vk_sprite *_renderer;
    NSData *_xxData,*_xaData;
    dc_model *_model;
    dc_xx *_xx;
    dc_xx_info _info;
    uintptr_t _cards[2],_textures[16];
    DCDecodedImage *_cardImages[2];
    dc_startup_state _startup;
    uint32_t _card,_lastTick;
    BOOL _finished,_tickInitialized,_wasTouching,_cardReady;
    BOOL _captureEnabled,_capturedCards[2];
}
- (BOOL)finished { return _finished; }
- (uint32_t)card { return _card; }
- (BOOL)cardReady { return _cardReady; }
- (NSData *)entry:(NSString *)name archive:(DCArchive *)archive limit:(NSUInteger)limit error:(NSString **)error {
    for (uint32_t i=0;i<archive.entryCount;++i) {
        if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame) {
            NSError *reason=nil;
            NSData *data=[archive readEntryAtIndex:i limit:limit error:&reason];
            if (!data && error) *error=reason.localizedDescription;
            return data;
        }
    }
    if (error) *error=[NSString stringWithFormat:@"Missing startup resource: %@",name];
    return nil;
}
- (NSString *)applyPlan:(const dc_startup_plan *)plan tick:(uint32_t)tick {
    for (uint32_t i=0;i<plan->count;++i) {
        const dc_startup_action *action=&plan->actions[i];
        switch (action->kind) {
        case DC_STARTUP_REQUEST_TRANSITION: {
            dc_status status=dc_model_request(_model,action->value,tick);
            if (status!=DC_OK) return [NSString stringWithFormat:@"Startup transition request failed: %d",status];
            break;
        }
        case DC_STARTUP_LOAD_CARD:
            if (action->value>1 || !_cards[action->value]) return @"Startup card is unavailable";
            _card=action->value;break;
        case DC_STARTUP_RELEASE_CARD: _card=UINT32_MAX;break;
        case DC_STARTUP_ENTER_NEXT: _finished=YES;break;
        default: return @"Unknown startup action";
        }
    }
    _startup=plan->next;
    return nil;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer error:(NSString **)error {
    if (!(self=[super init])) return nil;
    _renderer=renderer;_card=UINT32_MAX;
    _captureEnabled=[NSProcessInfo.processInfo.environment[@"PORTLAB_CAPTURE_STARTUP"] isEqualToString:@"1"];
    NSError *reason=nil;
    DCArchive *transition=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_17.pp"]] error:&reason];
    if (!transition) {if(error)*error=reason.localizedDescription;return nil;}
    _xxData=[self entry:@"mm_B_W.xx" archive:transition limit:32*1024*1024 error:error];
    _xaData=[self entry:@"mm_B_W.xa" archive:transition limit:32*1024*1024 error:error];
    if (!_xxData || !_xaData) return nil;
    dc_status status=dc_model_open(_xxData.bytes,_xxData.length,_xaData.bytes,_xaData.length,&_model);
    if (status==DC_OK) status=dc_xx_open(_xxData.bytes,_xxData.length,&_xx);
    if (status==DC_OK) status=dc_model_get_info(_model,&_info);
    if (status!=DC_OK || _info.textures>16 || _info.submeshes>16) {
        if(error)*error=[NSString stringWithFormat:@"Startup model profile rejected: %d",status];return nil;
    }
    DCArchive *cards=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if (!cards) {if(error)*error=reason.localizedDescription;return nil;}
    NSArray<NSString *> *names=@[@"illusion.ema",@"warning.ema"];
    for (uint32_t target=0;target<2;++target) {
        uint32_t index=UINT32_MAX;
        for (uint32_t i=0;i<cards.entryCount;++i)
            if ([[cards asciiNameAtIndex:i] caseInsensitiveCompare:names[target]]==NSOrderedSame) {index=i;break;}
        if (index==UINT32_MAX) {if(error)*error=@"Startup card resource is missing";return nil;}
        DCDecodedImage *image=[cards decodeImageAtIndex:index inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];
        if (!image) {if(error)*error=reason.localizedDescription;return nil;}
        _cardImages[target]=image;
    }
    NSString *uploadFailure=[self attachRenderer:renderer];
    if(uploadFailure) {if(error)*error=uploadFailure;return nil;}
    dc_startup_plan begin;
    status=dc_startup_begin_plan(&begin);
    NSString *failure=status==DC_OK ? [self applyPlan:&begin tick:0] : @"Startup initialization failed";
    if (failure) {if(error)*error=failure;return nil;}
    return self;
}
- (void)dealloc {
    [self detachRenderer];
    dc_model_close(_model);dc_xx_close(_xx);
}
- (void)detachRenderer {
    if (_renderer) {
        for (uint32_t i=0;i<2;++i) if(_cards[i]) dc_vk_sprite_remove_texture(_renderer,_cards[i]);
        for (uint32_t i=0;i<16;++i) if(_textures[i]) dc_vk_sprite_remove_texture(_renderer,_textures[i]);
    }
    memset(_cards,0,sizeof(_cards));memset(_textures,0,sizeof(_textures));
    _renderer=NULL;_tickInitialized=NO;
}
- (NSString *)attachRenderer:(dc_vk_sprite *)renderer {
    if (_renderer==renderer && _cards[0] && _cards[1]) return nil;
    [self detachRenderer];_renderer=renderer;
    for (uint32_t i=0;i<_info.textures;++i) {
        dc_image_info image;
        dc_status status=dc_xx_image_probe(_xx,i,&image);
        if (status!=DC_OK || image.rgba_bytes>64*1024*1024) return @"Startup image profile rejected";
        NSMutableData *pixels=[NSMutableData dataWithLength:image.rgba_bytes];
        status=dc_xx_image_decode(_xx,i,pixels.mutableBytes,pixels.length,&image);
        if(status==DC_OK) status=dc_vk_sprite_upload(_renderer,image.width,image.height,pixels.bytes,pixels.length,&_textures[i]);
        if(status!=DC_OK) return @"Startup transition texture upload failed";
    }
    for (uint32_t i=0;i<2;++i) {
        DCDecodedImage *image=_cardImages[i];
        if(!image || dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&_cards[i])!=DC_OK)
            return @"Startup card texture upload failed";
    }
    return nil;
}
- (NSString *)drawAtTick:(uint32_t)tick touching:(BOOL)touching width:(uint32_t)width height:(uint32_t)height {
    uint32_t delta=_tickInitialized ? tick-_lastTick : 0;
    uint32_t clip,ready;
    dc_status status=dc_model_query(_model,&clip,&ready);
    if (status!=DC_OK) return @"Startup animation query failed";
    dc_startup_input input={.delta=(int32_t)delta,.transition_state=(int32_t)clip,.transition_complete=ready,
        .skip_code=touching&&!_wasTouching ? 3 : 0};
    dc_startup_plan plan;
    status=dc_startup_build_plan(&_startup,&input,&plan);
    if (status!=DC_OK) return @"Startup state update failed";
    NSString *failure=[self applyPlan:&plan tick:tick];
    if (failure) return failure;
    dc_matrix world=dcStartupIdentity();
    status=dc_model_tick(_model,delta,tick,&world);
    if (status!=DC_OK) return [NSString stringWithFormat:@"Startup model update failed: %d",status];
    _tickInitialized=YES;_lastTick=tick;_wasTouching=touching;
    return [self renderSprites:NULL count:0 width:width height:height readback:nil];
}
- (dc_status)queryTransitionReady:(uint32_t *)ready {
    uint32_t clip;
    return dc_model_query(_model,&clip,ready);
}
- (dc_status)requestTransition:(uint32_t)request tick:(uint32_t)tick {
    return dc_model_request(_model,request,tick);
}
- (NSString *)drawSprites:(const dc_vk_sprite_item *)items count:(size_t)count
        tick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height {
    return [self drawSprites:items count:count tick:tick width:width height:height readback:nil];
}
- (NSString *)drawSprites:(const dc_vk_sprite_item *)items count:(size_t)count
        tick:(uint32_t)tick width:(uint32_t)width height:(uint32_t)height readback:(NSMutableData *)readback {
    uint32_t delta=_tickInitialized ? tick-_lastTick : 0;
    dc_matrix world=dcStartupIdentity();
    dc_status status=dc_model_tick(_model,delta,tick,&world);
    if(status!=DC_OK)return @"Scene transition model update failed";
    _tickInitialized=YES;_lastTick=tick;
    return [self renderSprites:items count:count width:width height:height readback:readback];
}
- (NSString *)renderSprites:(const dc_vk_sprite_item *)items count:(size_t)itemCount
        width:(uint32_t)width height:(uint32_t)height readback:(NSMutableData *)readback {
    if(itemCount>8 || (itemCount && !items))return @"Scene sprite profile rejected";
    if(readback && readback.length!=(size_t)width*height*4)return @"Scene readback capacity rejected";
    dc_status status;uint32_t clip,ready;
    float scale=fminf((float)width/1024,(float)height/768);
    dc_viewport viewport={(width-1024*scale)*.5f,(height-768*scale)*.5f,1024*scale,768*scale,0,1};
    dc_vk_geometry_item draws[25]={0};
    dc_sprite_vertex card[6];size_t count=0;
    dc_sprite_vertex sprites[8][6];
    const unsigned order[6]={0,1,2,2,1,3};
    for(size_t i=0;i<itemCount;++i) {
        dc_sprite_vertex corners[4];
        status=dc_sprite_build_vertices(&items[i].pose,corners);
        if(status!=DC_OK)return @"Scene sprite projection failed";
        for(unsigned j=0;j<6;++j)sprites[i][j]=corners[order[j]];
        draws[count++]=(dc_vk_geometry_item){.vertices=sprites[i],.vertex_count=6,
            .texture=items[i].texture,.blend_mode=items[i].blend_mode,.point_filter=items[i].point_filter};
    }
    if (_card<2) {
        dc_sprite_pose pose={.width=viewport.width,.height=viewport.height,.x=viewport.x,.y=viewport.y,.z=.5f,
            .scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
        dc_sprite_vertex corners[4];
        status=dc_sprite_build_vertices(&pose,corners);
        if (status!=DC_OK) return @"Startup card projection failed";
        const unsigned order[6]={0,1,2,2,1,3};
        for (unsigned i=0;i<6;++i) card[i]=corners[order[i]];
        draws[count++]=(dc_vk_geometry_item){.vertices=card,.vertex_count=6,.texture=_cards[_card],.blend_mode=3};
    }
    /* Original camera 5: FOV=.5, near=.5, far=10000, inverse camera Z=1.5. */
    float ys=1/tanf(.25f),q=10000.0f/(.5f-10000.0f);
    dc_matrix projection={{ys/(1024.0f/768),0,0,0,0,ys,0,0,0,0,q,-1,0,0,.5f*q,0}};
    dc_matrix view=dcStartupIdentity(),vp;view.values[14]=-1.5f;
    status=dc_matrix_multiply(&view,&projection,&vp);
    if (status!=DC_OK) return @"Startup camera matrix failed";
    __attribute__((objc_precise_lifetime)) NSMutableArray<NSMutableData *> *storage=[NSMutableArray array];
    for (uint32_t i=0;i<_info.submeshes;++i) {
        dc_xx_submesh mesh;dc_material_value material;
        status=dc_model_mesh(_model,i,&mesh);
        if (status==DC_OK) status=dc_model_material(_model,mesh.material,&material);
        if (status!=DC_OK) return @"Startup mesh material failed";
        if (material.components[3]==0) continue;
        dc_xx_material binding;status=dc_xx_material_at(_xx,mesh.material,&binding);
        if (status!=DC_OK) return @"Startup texture binding failed";
        uint32_t image=UINT32_MAX;
        for (uint32_t j=0;j<_info.textures;++j) {
            dc_xx_texture texture;dc_xx_texture_at(_xx,j,&texture);
            const uint8_t *a=(const uint8_t *)_xxData.bytes+binding.texture_names[0].offset;
            const uint8_t *b=(const uint8_t *)_xxData.bytes+texture.name.offset;
            size_t an=0,bn=0;
            while(an<binding.texture_names[0].length && a[an]!=255)++an;
            while(bn<texture.name.length && b[bn]!=255)++bn;
            if(an==bn && an<binding.texture_names[0].length && bn<texture.name.length && !memcmp(a,b,an)) {image=j;break;}
        }
        if (image==UINT32_MAX) return @"Startup texture name was not found";
        NSMutableData *vertices=[NSMutableData dataWithLength:mesh.index_count*sizeof(dc_sprite_vertex)];
        status=dc_model_project(_model,i,&vp,&viewport,dcStartupColor(&material),vertices.mutableBytes,mesh.index_count);
        if (status!=DC_OK) return [NSString stringWithFormat:@"Startup mesh projection failed: %d",status];
        [storage addObject:vertices];
        draws[count++]=(dc_vk_geometry_item){.vertices=vertices.bytes,.vertex_count=mesh.index_count,.texture=_textures[image],.blend_mode=3};
    }
    const uint8_t clear[4]={0,0,0,255};
    status=dc_model_query(_model,&clip,&ready);
    if (status!=DC_OK) return @"Startup animation query failed";
    BOOL stableCard=_card<2 && !_startup.waiting && clip==1 && ready;
    BOOL capture=_captureEnabled && stableCard && !_capturedCards[_card];
    NSMutableData *pixels=readback ?: (capture ? [NSMutableData dataWithLength:(size_t)width*height*4] : nil);
    status=dc_vk_geometry_render(_renderer,draws,count,clear,pixels.mutableBytes,pixels.length);
    if (status!=DC_OK) return [NSString stringWithUTF8String:dc_vk_sprite_error(_renderer)];
    _cardReady=stableCard;
    if(capture) {
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,
            kCGBitmapByteOrderDefault|kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);CGColorSpaceRelease(color);
        if(!image)return @"Startup frame capture failed";
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *url=[documents URLByAppendingPathComponent:[NSString stringWithFormat:@"startup-card-%u.png",_card]];
        CGImageDestinationRef output=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        if(!output) {CGImageRelease(image);return @"Startup frame capture destination failed";}
        CGImageDestinationAddImage(output,image,NULL);
        BOOL saved=CGImageDestinationFinalize(output);
        CFRelease(output);CGImageRelease(image);
        if(!saved)return @"Startup frame capture write failed";
        _capturedCards[_card]=YES;
    }
    return nil;
}
@end
