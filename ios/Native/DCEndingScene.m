#import "DCEndingScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#include "dc_flow.h"
#include "dc_menu.h"
#include <math.h>
#include <string.h>

typedef struct ending_item { const char *name; float x,y,w,h; } ending_item;
static const ending_item categoryItems[6]={
    {"Hscene_nozoki.ema",352,96,176,72},{"Hscene_chikan.ema",352,176,176,72},
    {"Hscene_2p.ema",352,256,176,72},{"Hscene_5p.ema",352,336,176,72},
    {"Hscene_3p.ema",352,416,176,72},{"Hscene_4p.ema",352,496,176,72}};
static const ending_item stageItems[3]={
    {"Hscene_manaka.ema",768,96,176,72},{"Hscene_yuko.ema",768,176,176,72},{"Hscene_aoi.ema",768,256,176,72}};
static const ending_item mapItems[7]={
    {"Hscene_station.ema",560,96,176,72},{"Hscene_train.ema",560,176,176,72},
    {"Hscene_toilet.ema",560,256,176,72},{"Hscene_hotel.ema",560,336,176,72},
    {"Hscene_roadside.ema",560,416,176,72},{"Hscene_park.ema",560,496,176,72},
    {"Hscene_manaka'sroom.ema",560,576,176,72}};
static void endingAddSprite(dc_vk_sprite_item *items,size_t *count,uintptr_t texture,
    float scale,float ox,float oy,float x,float y,float width,float height) {
    if(!items||!count||*count>=64||!texture)return;
    items[*count]=(dc_vk_sprite_item){.texture=texture,.blend_mode=3,
        .pose=(dc_sprite_pose){.width=width*scale,.height=height*scale,.x=ox+x*scale,.y=oy+y*scale,
        .z=.5f,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1}};
    ++*count;
}

@implementation DCEndingScene {
    NSString *_directory;
    DCStartupScene *_transition;
    dc_vk_sprite *_renderer;
    dc_story_state _story;
    NSMutableDictionary<NSString *,NSNumber *> *_textures;
    uint32_t _action,_category,_mapIndex,_stageMask,_firstStage,_secondStage;
    uint32_t _bank;
    int32_t _hover;
    BOOL _entered,_confirming;
}
- (uint32_t)action{return _action;}
- (BOOL)routeReady{return _action==1;}
- (uint32_t)category{return _category;}
- (uint32_t)mapIndex{return _mapIndex;}
- (uint32_t)stageMask{return _stageMask;}
- (uint32_t)firstStage{return _firstStage;}
- (uint32_t)secondStage{return _secondStage;}
- (NSData *)entry:(NSString *)name archive:(DCArchive *)archive {
    for(uint32_t i=0;i<archive.entryCount;++i)
        if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame)
            return [archive readEntryAtIndex:i limit:16*1024*1024 error:nil];
    return nil;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    transition:(DCStartupScene *)transition story:(const dc_story_state *)story error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];_renderer=renderer;_transition=transition;
    if(story)_story=*story;
    _textures=[NSMutableDictionary dictionary];
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:nil];
    if(!archive){if(error)*error=@"Original ending selector archive unavailable";return nil;}
    NSMutableSet<NSString *> *names=[NSMutableSet setWithObject:@"Hscene_base.ema"];
    for(const ending_item *p=categoryItems;p<categoryItems+6;++p){[names addObject:[NSString stringWithUTF8String:p->name]];[names addObject:[NSString stringWithFormat:@"%s",p->name]];}
    for(const ending_item *p=stageItems;p<stageItems+3;++p)[names addObject:[NSString stringWithUTF8String:p->name]];
    for(const ending_item *p=mapItems;p<mapItems+7;++p)[names addObject:[NSString stringWithUTF8String:p->name]];
    for(NSString *name in @[@"Hscene_PLAY.ema",@"hanyo_gameend.ema",@"hanyo_title.ema",@"hanyo_config.ema",@"hanyo_saveload.ema",@"k_defo.ema",
        @"Hscene_nozoki_mono.ema",@"Hscene_chikan_mono.ema",@"Hscene_2P_mono.ema",@"Hscene_5p_mono.ema",@"Hscene_3p_mono.ema",@"Hscene_4p_mono.ema",
        @"Hscene_manaka_mono.ema",@"Hscene_yuko_mono.ema",@"Hscene_aoi_mono.ema",
        @"Hscene_station_mono.ema",@"Hscene_train_mono.ema",@"Hscene_toilet_mono.ema",@"Hscene_hotel_mono.ema",@"Hscene_roadside_mono.ema",@"Hscene_park_mono.ema",@"Hscene_manaka'sroom_mono.ema",
        @"Hscene_select01.ema",@"Hscene_select02.ema",@"Hscene_select03.ema"])[names addObject:name];
    for(NSString *name in names){
        NSData *data=[self entry:name archive:archive];
        if(!data)continue;
        DCDecodedImage *image=nil;NSError *reason=nil;
        for(uint32_t i=0;i<archive.entryCount;++i)if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame){
            image=[archive decodeImageAtIndex:i inputLimit:16*1024*1024 outputLimit:64*1024*1024 error:&reason];break;
        }
        uintptr_t texture=0;
        if(!image||dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&texture)!=DC_OK){
            if(error)*error=reason.localizedDescription?:[NSString stringWithFormat:@"Ending selector texture unavailable: %@",name];return nil;
        }
        _textures[name]=@(texture);
    }
    if(!_textures[@"Hscene_base.ema"]||!_textures[@"Hscene_PLAY.ema"]){if(error)*error=@"Ending selector base resources unavailable";return nil;}
    _bank=0;_hover=-1;return self;
}
- (uintptr_t)texture:(NSString *)name {
    NSNumber *value=_textures[name];if(value)return value.unsignedLongLongValue;
    return _textures[[name stringByReplacingOccurrencesOfString:@"2P" withString:@"2p"]].unsignedLongLongValue;
}
- (BOOL)hit:(float)x y:(float)y item:(ending_item)item{return x>=item.x&&x<=item.x+item.w&&y>=item.y&&y<=item.y+item.h;}
- (void)chooseFromInput:(dc_pc_frame)input x:(float)x y:(float)y tick:(uint32_t)tick {
    if(input.keys[1]==3){_action=2;return;}
    if(input.mouse[0]==3&&y>=704&&y<=760){
        if(x>=48&&x<=104){_action=4;return;}
        if(x>=128&&x<=184){_action=2;return;}
        if(x>=248&&x<=304){_action=3;return;}
        if(x>=328&&x<=384){_action=5;return;}
    }
    if(input.mouse[1]==3){if(_bank>0)--_bank;return;}
    if(input.mouse[0]!=3)return;
    if(_bank==0){for(unsigned i=0;i<6;++i)if([self hit:x y:y item:categoryItems[i]]){_category=i;_bank=2;return;}}
    else if(_bank==2){for(unsigned i=0;i<7;++i)if([self hit:x y:y item:mapItems[i]]){_mapIndex=i;_bank=_category==5?3:1;return;}}
    else if(_bank==1){for(unsigned i=0;i<3;++i)if([self hit:x y:y item:stageItems[i]]){if(_category==4){if(_stageMask==0){_firstStage=i;_stageMask|=1u<<i;}else{_secondStage=i;_stageMask|=1u<<i;_bank=3;}}else{_firstStage=i;_stageMask=1u<<i;_bank=3;}return;}}
    else if(_bank==3&&[self hit:x y:y item:(ending_item){"Hscene_PLAY.ema",800,624,200,48}]){if(_category==5)_stageMask=7;if(_stageMask&&!_confirming){_confirming=YES;[_transition requestTransition:2 tick:tick];}}
}
- (NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input width:(uint32_t)width height:(uint32_t)height {
    if(!_renderer||!_transition)return @"Ending selector renderer unavailable";
    uint32_t ready=0;if(!_entered){if([_transition requestTransition:4 tick:tick]!=DC_OK)return @"Ending selector entry transition failed";_entered=YES;}
    if([_transition queryTransitionReady:&ready]!=DC_OK)return @"Ending selector transition query failed";
    if(_confirming&&ready)_action=1;
    float scale=fminf(width/1024.f,height/768.f),ox=(width-1024*scale)*.5f,oy=(height-768*scale)*.5f;
    float x=input.x*1024,y=input.y*768;[self chooseFromInput:input x:x y:y tick:tick];
    dc_vk_sprite_item spriteItems[64]={0};size_t spriteCount=0;
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_base.ema"],scale,ox,oy,0,0,1024,768);
    if(_bank==0)for(unsigned i=0;i<6;++i)endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:categoryItems[i].name]],scale,ox,oy,categoryItems[i].x,categoryItems[i].y,176,72);
    if(_bank==1)for(unsigned i=0;i<3;++i)endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:stageItems[i].name]],scale,ox,oy,stageItems[i].x,stageItems[i].y,176,72);
    if(_bank==2)for(unsigned i=0;i<7;++i)endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:mapItems[i].name]],scale,ox,oy,mapItems[i].x,mapItems[i].y,176,72);
    if(_bank==3)endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_PLAY.ema"],scale,ox,oy,800,624,200,48);
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_gameend.ema"],scale,ox,oy,48,704,56,56);
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_title.ema"],scale,ox,oy,128,704,56,56);
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_config.ema"],scale,ox,oy,248,704,56,56);
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_saveload.ema"],scale,ox,oy,328,704,56,56);
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"k_defo.ema"],scale,ox,oy,x-6,y-6,64,64);
    return [_transition drawSprites:spriteItems count:spriteCount tick:tick width:width height:height];
}
- (void)detachRenderer {for(NSNumber *value in _textures.allValues)if(_renderer)dc_vk_sprite_remove_texture(_renderer,value.unsignedLongLongValue);[_textures removeAllObjects];_renderer=NULL;}
- (void)dealloc {[self detachRenderer];}
@end
