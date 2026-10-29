#import "DCSaveScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include "dc_save.h"
#include "dc_story.h"
#include <math.h>
#include <string.h>

typedef struct save_sprite { const char *name; float w,h,x,y,ox,oy; } save_sprite;
/* Original VA006d3d08,85 records with stride0x54; logical sizes and order. */
static const save_sprite saveSprites[85]={
    {"k_defo.ema",64,64,0,0,.1f,.1f},
    {"Save_base.ema",1024,768,0,0,0,0},
    {"Save_select.ema",576,48,0,0,0,0},
    {"Save_save.ema",184,48,512,632,0,0},
    {"Save_load.ema",184,48,752,632,0,0},
    {"Save_page1.ema",32,48,416,712,0,0},
    {"Save_page2.ema",32,48,464,712,0,0},
    {"Save_page3.ema",32,48,512,712,0,0},
    {"Save_page4.ema",32,48,560,712,0,0},
    {"Save_page5.ema",32,48,608,712,0,0},
    {"Save_page6.ema",32,48,656,712,0,0},
    {"Save_page7.ema",32,48,704,712,0,0},
    {"Save_page8.ema",32,48,752,712,0,0},
    {"hanyo_chijoku.ema",24,32,33,0,0,0},
    {"hanyo_koukan.ema",24,32,61,0,0,0},
    {"hanyo_ingo.ema",24,32,89,0,0,0},
    {"hanyo_kouin.ema",24,32,117,0,0,0},
    {"hanyo_sein.ema",24,32,145,0,0,0},
    {"hanyo_seiju.ema",24,32,173,0,0,0},
    {"hanyo_seiyoku.ema",24,32,201,0,0,0},
    {"hanyo_roshutu.ema",24,32,229,0,0,0},
    {"hanyo_aokan.ema",24,32,257,0,0,0},
    {"hanyo_00.ema",8,16,0,0,0,0},
    {"hanyo_01.ema",8,16,0,0,0,0},
    {"hanyo_02.ema",8,16,0,0,0,0},
    {"hanyo_03.ema",8,16,0,0,0,0},
    {"hanyo_04.ema",8,16,0,0,0,0},
    {"hanyo_05.ema",8,16,0,0,0,0},
    {"hanyo_06.ema",8,16,0,0,0,0},
    {"hanyo_07.ema",8,16,0,0,0,0},
    {"hanyo_08.ema",8,16,0,0,0,0},
    {"hanyo_09.ema",8,16,0,0,0,0},
    {"Save_file_00.ema",16,24,0,0,0,0},
    {"Save_file_01.ema",16,24,0,0,0,0},
    {"Save_file_02.ema",16,24,0,0,0,0},
    {"Save_file_03.ema",16,24,0,0,0,0},
    {"Save_file_04.ema",16,24,0,0,0,0},
    {"Save_file_05.ema",16,24,0,0,0,0},
    {"Save_file_06.ema",16,24,0,0,0,0},
    {"Save_file_07.ema",16,24,0,0,0,0},
    {"Save_file_08.ema",16,24,0,0,0,0},
    {"Save_file_09.ema",16,24,0,0,0,0},
    {"Save_point00.ema",128,24,0,0,0,0},
    {"Save_point01.ema",128,24,0,0,0,0},
    {"Save_point02.ema",128,24,0,0,0,0},
    {"Save_point03.ema",128,24,0,0,0,0},
    {"Save_point23.ema",128,24,0,0,0,0},
    {"Save_point04.ema",128,24,0,0,0,0},
    {"Save_point05.ema",128,24,0,0,0,0},
    {"Save_point06.ema",128,24,0,0,0,0},
    {"Save_point07.ema",128,24,0,0,0,0},
    {"Save_point09.ema",128,24,0,0,0,0},
    {"Save_point08.ema",128,24,0,0,0,0},
    {"Save_point24.ema",128,24,0,0,0,0},
    {"Save_point10.ema",128,24,0,0,0,0},
    {"Save_point11.ema",128,24,0,0,0,0},
    {"Save_point12.ema",128,24,0,0,0,0},
    {"Save_point13.ema",128,24,0,0,0,0},
    {"Save_point14.ema",128,24,0,0,0,0},
    {"Save_point15.ema",128,24,0,0,0,0},
    {"Save_point16.ema",128,24,0,0,0,0},
    {"Save_point17.ema",128,24,0,0,0,0},
    {"Save_point18.ema",128,24,0,0,0,0},
    {"Save_point19.ema",128,24,0,0,0,0},
    {"Save_point20.ema",128,24,0,0,0,0},
    {"Save_point22.ema",128,24,0,0,0,0},
    {"Save_point21.ema",128,24,0,0,0,0},
    {"Save_point25.ema",128,24,0,0,0,0},
    {"hanyo_gameend.ema",56,56,48,704,0,0},
    {"hanyo_title.ema",56,56,128,704,0,0},
    {"hanyo_config.ema",56,56,248,704,0,0},
    {"hanyo_back.ema",56,56,936,704,0,0},
    {"Save_save_mono.ema",184,48,512,632,0,0},
    {"manaka_hoho.ema",224,64,72,96,0,0},
    {"manaka_toji.ema",224,64,72,96,0,0},
    {"manaka_hara.ema",224,64,72,96,0,0},
    {"manaka_bote.ema",224,64,72,96,0,0},
    {"yuko_hoho.ema",224,64,72,292,0,0},
    {"yuko_toji.ema",224,64,72,292,0,0},
    {"yuko_hara.ema",224,64,72,292,0,0},
    {"yuko_bote.ema",224,64,72,292,0,0},
    {"aoi_hoho.ema",224,64,72,488,0,0},
    {"aoi_toji.ema",224,64,72,488,0,0},
    {"aoi_hara.ema",224,64,72,488,0,0},
    {"aoi_bote.ema",224,64,72,488,0,0}
};
static BOOL saveHit(float x,float y,float rx,float ry,float w,float h) {
    return x>=rx&&x<=rx+w&&y>=ry&&y<=ry+h;
}
static uint16_t saveWord(const uint8_t *p) {return (uint16_t)p[0]|(uint16_t)p[1]<<8;}
static uint32_t saveDword(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}

@implementation DCSaveScene {
    dc_vk_sprite *_renderer;
    uintptr_t _textures[85];
    DCStartupScene *_transition;
    NSString *_directory,*_captureName;
    NSMutableArray<NSDictionary *> *_slots;
    NSData *_loadData;
    AVAudioPlayer *_music,*_select,*_toggle;
    uint32_t _page,_row,_ownerSceneType,_chapter,_pendingAction,_action;
    int32_t _hoverButton,_hoverAction;
    BOOL _entered,_ready,_saveRequested,_saveDisabled;
    NSDictionary *_lastRenderCapture;
}
- (NSData *)compatibilitySlotFromExistingState {
    NSString *saveDirectory=[_directory stringByAppendingPathComponent:@"save"];
    NSData *flow=[NSData dataWithContentsOfFile:[saveDirectory stringByAppendingPathComponent:@"flow.state"]];
    NSMutableData *raw=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
    dc_save_slot_meta meta={0};BOOL haveRaw=NO;
    if(flow.length>=13+DC_GAME_STATE_BYTES&&memcmp(flow.bytes,"PLFL",4)==0&&((const uint8_t *)flow.bytes)[4]==1) {
        memcpy(&meta,(const uint8_t *)flow.bytes+5,sizeof(meta));
        memcpy(raw.mutableBytes,(const uint8_t *)flow.bytes+13,DC_GAME_STATE_BYTES);haveRaw=YES;
    }
    if(!haveRaw) {
        NSData *player=[NSData dataWithContentsOfFile:[saveDirectory stringByAppendingPathComponent:@"player.state"]];
        if(player.length<DC_GAME_PLAYER_SAVE_BYTES+DC_STORY_SAVE_BYTES)return nil;
        dc_story_state story;
        if(dc_story_load((const uint8_t *)player.bytes+DC_GAME_PLAYER_SAVE_BYTES,player.length-DC_GAME_PLAYER_SAVE_BYTES,&story)!=DC_OK)return nil;
        if(dc_game_state_init(raw.mutableBytes,raw.length)!=DC_OK)return nil;
        for(unsigned i=0;i<DC_STORY_STAGES;++i){size_t base=(size_t)i*0x2198;uint8_t *p=raw.mutableBytes;p[base]=story.stages[i].flag_a;p[base+1]=story.stages[i].flag_b;p[base+0x23]=(uint8_t)story.stages[i].progress;}
        meta=(dc_save_slot_meta){(uint8_t)story.chapter,3,3,(uint8_t)story.map,(uint8_t)story.stage,255,255,254};
    }
    NSMutableData *slot=[NSMutableData dataWithLength:DC_SAVE_SLOT_BYTES];
    if(dc_save_slot_encode(raw.bytes,raw.length,&meta,slot.mutableBytes,slot.length)!=DC_OK)return nil;
    return slot;
}
- (uint32_t)action {return _action;}
- (uint32_t)selectedSlot {return _page*10+_row;}
- (BOOL)saveRequested {return _saveRequested;}
- (NSData *)selectedSlotData {
    if(_loadData)return _loadData;
    NSData *data=_slots.count>self.selectedSlot?_slots[self.selectedSlot][@"data"]:nil;
    return data.length?data:nil;
}
- (NSDictionary *)lastRenderCapture {return _lastRenderCapture;}
- (NSString *)presentationContext {
    return [NSString stringWithFormat:@"system=save ready=%d page=%u row=%u slot=%u saveDisabled=%d saveRequested=%d pending=%u action=%u",_ready,_page,_row,self.selectedSlot,_saveDisabled,_saveRequested,_pendingAction,_action];
}
- (void)consumeSaveRequest {_saveRequested=NO;}
- (void)requestRenderCapture:(NSString *)name {_captureName=[name copy];}
- (AVAudioPlayer *)audio:(NSString *)name archive:(NSString *)file error:(NSString **)error {
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:file]] error:&reason];
    if(!archive){if(error)*error=reason.localizedDescription;return nil;}
    for(uint32_t i=0;i<archive.entryCount;++i)if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame){
        NSData *data=[archive readEntryAtIndex:i limit:32*1024*1024 error:&reason];
        AVAudioPlayer *player=data?[[AVAudioPlayer alloc] initWithData:data error:&reason]:nil;
        if(!player||![player prepareToPlay]){if(error)*error=reason.localizedDescription?:@"Save audio preparation failed";return nil;}
        return player;
    }
    if(error)*error=[NSString stringWithFormat:@"Missing original save audio %@",name];return nil;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
        transition:(DCStartupScene *)transition ownerSceneType:(uint32_t)ownerSceneType
        chapter:(uint32_t)chapter error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];_renderer=renderer;_transition=transition;
    _ownerSceneType=ownerSceneType;_chapter=chapter;_hoverButton=_hoverAction=-1;
    /*0052e070 disables Save for these owner/chapter combinations only. */
    _saveDisabled=ownerSceneType==1||ownerSceneType==12||(ownerSceneType==3&&chapter>24);
    NSError *reason=nil;
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if(!archive){if(error)*error=reason.localizedDescription;return nil;}
    NSMutableDictionary<NSString *,NSNumber *> *indices=[NSMutableDictionary dictionary];
    for(uint32_t i=0;i<archive.entryCount;++i){NSString *name=[archive asciiNameAtIndex:i];if(name)indices[name.lowercaseString]=@(i);}
    for(unsigned i=0;i<85;++i){
        NSString *name=[NSString stringWithUTF8String:saveSprites[i].name];NSNumber *index=indices[name.lowercaseString];
        if(!index){if(error)*error=[NSString stringWithFormat:@"Missing original save bitmap %@",name];return nil;}
        DCDecodedImage *image=[archive decodeImageAtIndex:index.unsignedIntValue inputLimit:8*1024*1024 outputLimit:64*1024*1024 error:&reason];
        if(!image||dc_vk_sprite_upload(renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&_textures[i])!=DC_OK){
            if(error)*error=reason.localizedDescription?:@"Save bitmap upload failed";return nil;
        }
    }
    _music=[self audio:@"bgm015.wav" archive:@"RPP_01.pp" error:error];
    _select=[self audio:@"se100.wav" archive:@"RPP_14.pp" error:error];
    _toggle=[self audio:@"se101.wav" archive:@"RPP_14.pp" error:error];
    if(!_music||!_select||!_toggle)return nil;
    NSData *configuration=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"gcd.cfg"]];
    int32_t se=-1200,bgm=-1200;
    if(configuration.length>=12){const uint8_t *p=configuration.bytes;se=(int32_t)saveDword(p+4);bgm=(int32_t)saveDword(p+8);}
    _music.volume=powf(10,bgm/2000.f);_select.volume=_toggle.volume=powf(10,se/2000.f);
    [self refreshSlots];
    /*00530b90/00530970 choose the latest local DOS date/time; ties keep the
     * earlier slot. Selection stays unchanged on subsequent refreshes. */
    uint64_t newest=0;
    for(uint32_t i=0;i<80;++i){uint64_t stamp=[_slots[i][@"stamp"] unsignedLongLongValue];if(stamp>newest){newest=stamp;_page=i/10;_row=i%10;}}
    _music.numberOfLoops=-1;[_music play];return self;
}
- (void)refreshSlots {
    NSMutableArray<NSDictionary *> *slots=[NSMutableArray arrayWithCapacity:80];
    NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone=NSTimeZone.localTimeZone;
    NSMutableData *decoded=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];
    for(uint32_t slot=0;slot<80;++slot){
        char name[16];dc_save_slot_name(slot,name,sizeof(name));
        NSString *path=[[_directory stringByAppendingPathComponent:@"save"] stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:nil];
        NSData *bytes=file?[file readDataUpToLength:DC_SAVE_SLOT_BYTES error:nil]:nil;[file closeAndReturnError:nil];
        dc_save_slot_meta meta={0};
        BOOL valid=bytes&&dc_save_slot_decode(bytes.bytes,bytes.length,decoded.mutableBytes,decoded.length,&meta)==DC_OK;
        NSMutableDictionary *entry=[NSMutableDictionary dictionaryWithDictionary:@{@"data":[NSData data],@"prefix":[NSData data],@"digits":@[],@"chapter":@0,@"complete":@NO,@"stamp":@0}];
        if(valid){
            const uint8_t *p=decoded.bytes;
            entry[@"data"]=bytes;entry[@"prefix"]=[NSData dataWithBytes:p length:DC_SAVE_RECORD_BYTES];entry[@"chapter"]=@(meta.chapter);
            entry[@"complete"]=@(p[0x23]==2&&p[0x2198+0x23]==2&&p[0x4330+0x23]==2);
            NSDictionary *attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            NSDate *date=attributes[NSFileModificationDate];
            if(date){
                NSDateComponents *c=[calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond fromDate:date];
                unsigned values[5]={(unsigned)c.year,(unsigned)c.month,(unsigned)c.day,(unsigned)c.hour,(unsigned)c.minute};
                /* Original stores year units at slot-record byte +1, then
                 * 0052f9c0 overwrites that byte with the page. Date drawing
                 * therefore starts at year tens and ends with its untouched
                 * zero byte at index13. */
                NSMutableArray *digits=[NSMutableArray arrayWithCapacity:12];
                unsigned year=values[0];[digits addObject:@((year/10)%10)];[digits addObject:@((year/100)%10)];[digits addObject:@((year/1000)%10)];
                for(unsigned field=1;field<5;++field){unsigned value=values[field];[digits addObject:@(value%10)];[digits addObject:@((value/10)%10)];}
                [digits addObject:@0];
                entry[@"digits"]=digits;
                uint64_t stamp=(((uint64_t)c.year*10000+(uint64_t)c.month*100+(uint64_t)c.day)*1000000+(uint64_t)c.hour*10000+(uint64_t)c.minute*100+(uint64_t)c.second/2);
                entry[@"stamp"]=@(stamp);
            }
        }
        [slots addObject:entry];
    }
    BOOL anyValid=NO;for(NSDictionary *entry in slots)if([entry[@"data"] length]){anyValid=YES;break;}
    if(!anyValid) {
        NSData *compatibility=[self compatibilitySlotFromExistingState];
        if(compatibility) {
            NSMutableData *decoded=[NSMutableData dataWithLength:DC_GAME_STATE_BYTES];dc_save_slot_meta meta={0};
            if(dc_save_slot_decode(compatibility.bytes,compatibility.length,decoded.mutableBytes,decoded.length,&meta)==DC_OK) {
                NSMutableDictionary *entry=[slots[0] mutableCopy];entry[@"data"]=compatibility;entry[@"prefix"]=[NSData dataWithBytes:decoded.bytes length:DC_SAVE_RECORD_BYTES];entry[@"chapter"]=@(meta.chapter);entry[@"complete"]=@NO;slots[0]=entry;
            }
        }
    }
    _slots=slots;
}
- (void)detachRenderer {
    if(_renderer)for(unsigned i=0;i<85;++i)if(_textures[i])dc_vk_sprite_remove_texture(_renderer,_textures[i]);
    memset(_textures,0,sizeof(_textures));_renderer=NULL;
}
- (void)pause {[_music pause];[_select pause];[_toggle pause];}
- (void)resumeFromTemporaryScreen {_pendingAction=_action=0;_entered=_ready=NO;_loadData=nil;[_music play];}
- (void)dealloc {[self detachRenderer];[_music stop];[_select stop];[_toggle stop];}
- (NSString *)depart:(uint32_t)action tick:(uint32_t)tick {
    _pendingAction=action;
    if(action==6)[self pause];else {_select.currentTime=0;[_select play];}
    return [_transition requestTransition:action==6?3:2 tick:tick]==DC_OK?nil:@"Save departure transition failed";
}
- (void)append:(unsigned)index x:(float)x y:(float)y scale:(float)scale
        offsetX:(float)ox offsetY:(float)oy items:(dc_vk_sprite_item *)items count:(size_t *)count {
    if(index>=85||*count>=512)return;
    save_sprite sprite=saveSprites[index];
    dc_sprite_pose pose={.width=sprite.w*scale,.height=sprite.h*scale,.x=ox+x*scale,.y=oy+y*scale,.z=.5f,
        .origin_x=sprite.ox,.origin_y=sprite.oy,.scale_x=1,.scale_y=1,.alpha=1,.red=1,.green=1,.blue=1,.u1=1,.v1=1};
    items[(*count)++]=(dc_vk_sprite_item){.pose=pose,.texture=_textures[index],.blend_mode=3};
}
- (NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input width:(uint32_t)width height:(uint32_t)height {
    if(!_renderer)return @"Save renderer detached";
    if(!_entered){if([_transition requestTransition:4 tick:tick]!=DC_OK)return @"Save entry transition failed";_entered=YES;}
    uint32_t ready=0;if([_transition queryTransitionReady:&ready]!=DC_OK)return @"Save transition query failed";
    if(ready){if(_pendingAction&&(_pendingAction==6||!_select.isPlaying))_action=_pendingAction;else if(!_pendingAction)_ready=YES;}
    float x=input.x*1024,y=input.y*768;
    if(_ready&&!_pendingAction&&!_saveRequested){
        _hoverButton=_hoverAction=-1;
        if(input.keys[1]==3){NSString *failure=[self depart:6 tick:tick];if(failure)return failure;}
        else if(input.mouse[1]==2||input.keys[0x3c]==3){NSString *failure=[self depart:1 tick:tick];if(failure)return failure;}
        else {
            BOOL hit=NO;
            for(unsigned row=0;row<10&&!hit;++row)if(saveHit(x,y,412,67+56*row,536,40)){
                hit=YES;if(input.mouse[0]==3){_row=row;_loadData=nil;_toggle.currentTime=0;[_toggle play];}
            }
            for(unsigned page=0;page<8&&!hit;++page){save_sprite s=saveSprites[5+page];if(saveHit(x,y,s.x,s.y,s.w,s.h)){
                hit=YES;if(input.mouse[0]==3){_page=page;_loadData=nil;_toggle.currentTime=0;[_toggle play];}
            }}
            for(unsigned button=0;button<2&&!hit;++button){
                if(button==0&&_saveDisabled)continue;
                save_sprite s=saveSprites[3+button];if(!saveHit(x,y,s.x,s.y,s.w,s.h))continue;
                hit=YES;_hoverButton=(int32_t)button;
                if(input.mouse[0]==3){
                    if(button==0){_saveRequested=YES;_toggle.currentTime=0;[_toggle play];}
                    else if(self.selectedSlotData){_loadData=[self.selectedSlotData copy];NSString *failure=[self depart:5 tick:tick];if(failure)return failure;}
                }
            }
            for(unsigned action=0;action<4&&!hit;++action){save_sprite s=saveSprites[68+action];if(saveHit(x,y,s.x,s.y,s.w,s.h)){
                hit=YES;_hoverAction=(int32_t)action;
                if(input.mouse[0]==3){static const uint32_t actions[4]={4,2,3,1};NSString *failure=[self depart:actions[action] tick:tick];if(failure)return failure;}
            }}
        }
    }
    dc_vk_sprite_item items[512]={0};size_t count=0;
    float scale=fminf(width/1024.f,height/768.f),ox=(width-1024*scale)*.5f,oy=(height-768*scale)*.5f;
#define SAVE_APPEND(i,px,py) [self append:(i) x:(px) y:(py) scale:scale offsetX:ox offsetY:oy items:items count:&count]
    /* Save_select follows the selected page (DAT_0084d07a), not the row. */
    SAVE_APPEND(1,0,0);SAVE_APPEND(2,376,64+56*_page);
    save_sprite pageSprite=saveSprites[5+_page];SAVE_APPEND(5+_page,pageSprite.x,pageSprite.y);
    if(_hoverButton>=0){save_sprite s=saveSprites[3+_hoverButton];SAVE_APPEND(3+(unsigned)_hoverButton,s.x,s.y);}
    if(_saveDisabled)SAVE_APPEND(72,512,632);
    if(_hoverAction>=0){save_sprite s=saveSprites[68+_hoverAction];SAVE_APPEND(68+(unsigned)_hoverAction,s.x,s.y);}
    static const float dateX[12]={588,571,554,537,632,615,676,659,730,713,773,756};
    for(unsigned row=0;row<10;++row){
        float ry=76+56*row;SAVE_APPEND(32+row,502,ry);SAVE_APPEND(32+_page,485,ry);
        NSDictionary *entry=_slots[_page*10+row];NSData *bytes=entry[@"data"];
        if(bytes.length){
            NSArray *digits=entry[@"digits"];
            for(unsigned i=0;i<12&&i<digits.count;++i){unsigned digit=[digits[i] unsignedIntValue];if(digit<10)SAVE_APPEND(32+digit,dateX[i],ry);}
            unsigned chapter=[entry[@"chapter"] unsignedIntValue],extra=chapter==24&&[entry[@"complete"] boolValue];
            unsigned point=42+chapter+extra;if(point<85)SAVE_APPEND(point,804,ry);
        }
    }
    NSData *prefix=_slots[self.selectedSlot][@"prefix"];
    const uint8_t *state=prefix.bytes;
    static const float scoreX[4]={260,245,230,215},timeX[5]={260,245,218,203,176};
    for(unsigned panel=0;panel<3;++panel){
        unsigned character=2-panel;const uint8_t *p=prefix.length>=DC_SAVE_RECORD_BYTES?state+character*0x2198:NULL;
        /* 0052d970 copies the per-character selector from record+0x23
         * (the stack alias named auStack_65ba). */
        unsigned portrait=p?p[0x23]:0;
        static const unsigned portraitVariant[6]={0,0,1,0,2,3};
        if(portrait>0&&portrait<6&&portrait!=3){unsigned index=73+panel*4+portraitVariant[portrait];save_sprite s=saveSprites[index];SAVE_APPEND(index,s.x,s.y);}
        for(unsigned flag=0;flag<9;++flag)if(p&&p[3+flag])SAVE_APPEND(13+flag,saveSprites[13+flag].x,237+196*panel);
        for(unsigned field=0;field<2;++field){
            unsigned value=p?saveWord(p+(field?0xc:0x26)):0;if(value==10000)value=9999;
            uint8_t digits[4];for(unsigned i=0;i<4;++i){digits[i]=value%10;value/=10;}
            for(unsigned i=0;i<4;++i){BOOL visible=i==0;for(unsigned j=i;j<4;++j)if(digits[j])visible=YES;
                if(visible)SAVE_APPEND(22+digits[i],scoreX[i],(field?190:165)+195*panel);
            }
        }
        uint32_t time=p?saveDword(p+0x30):0;uint8_t timeDigits[5]={0,0,0,3,1};
        if(time<90000){unsigned value=time/10;for(unsigned i=0;i<2;++i){timeDigits[i]=value%10;value/=10;}
            timeDigits[4]=value/60;value%=60;for(unsigned i=2;i<4;++i){timeDigits[i]=value%10;value/=10;}
        }
        for(unsigned i=0;i<5;++i)SAVE_APPEND(22+timeDigits[i],timeX[i],213+195*panel);
    }
    SAVE_APPEND(0,x,y);
#undef SAVE_APPEND
    if(input.keys[0x2e]==3)_captureName=@"system-save-native.png";
    NSMutableData *pixels=_captureName?[NSMutableData dataWithLength:(size_t)width*height*4]:nil;
    NSString *failure=[_transition drawSprites:items count:count tick:tick width:width height:height readback:pixels];
    if(failure)return failure;
    if(pixels){
        NSString *name=_captureName.lastPathComponent;_captureName=nil;NSString *directory=[_directory stringByDeletingLastPathComponent];
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Big|kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
        NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
        CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        if(!image||!destination){if(destination)CFRelease(destination);if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(color);return @"Save capture allocation failed";}
        CGImageDestinationAddImage(destination,image,NULL);BOOL written=CGImageDestinationFinalize(destination);
        CFRelease(destination);CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(color);
        if(!written)return @"Save capture write failed";
        NSMutableArray *occupied=[NSMutableArray array];for(unsigned i=0;i<10;++i){NSData *data=_slots[_page*10+i][@"data"];[occupied addObject:@(data.length>0)];}
        _lastRenderCapture=@{@"file":name,@"width":@(width),@"height":@(height),@"draws":@(count),@"page":@(_page),@"row":@(_row),@"slot":@(self.selectedSlot),@"occupied":occupied,@"ownerSceneType":@(_ownerSceneType),@"chapter":@(_chapter),@"saveDisabled":@(_saveDisabled),@"saveRequested":@(_saveRequested),@"ready":@(_ready),@"pending":@(_pendingAction),@"action":@(_action),@"pointer":@[@(x),@(y)]};
        NSData *json=[NSJSONSerialization dataWithJSONObject:_lastRenderCapture options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[[directory stringByAppendingPathComponent:name] stringByAppendingString:@".json"] atomically:YES];
    }
    return nil;
}
@end
