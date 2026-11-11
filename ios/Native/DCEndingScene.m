#import "DCEndingScene.h"
#import <AVFoundation/AVFoundation.h>
#import "DCArchive.h"
#import "DCStartupScene.h"
#include "dc_flow.h"
#include "dc_menu.h"
#include "dc_save.h"
#include <math.h>
#include <string.h>

typedef struct ending_item { const char *name; const char *mono; float x,y,w,h; } ending_item;
static const ending_item categoryItems[6]={
    {"Hscene_nozoki.ema","Hscene_nozoki_mono.ema",352,96,176,72},
    {"Hscene_chikan.ema","Hscene_chikan_mono.ema",352,176,176,72},
    {"Hscene_2p.ema","Hscene_2P_mono.ema",352,256,176,72},
    {"Hscene_5p.ema","Hscene_5p_mono.ema",352,336,176,72},
    {"Hscene_3p.ema","Hscene_3p_mono.ema",352,416,176,72},
    {"Hscene_4p.ema","Hscene_4p_mono.ema",352,496,176,72}};
static const ending_item stageItems[3]={
    {"Hscene_manaka.ema","Hscene_manaka_mono.ema",768,96,176,72},
    {"Hscene_yuko.ema","Hscene_yuko_mono.ema",768,176,176,72},
    {"Hscene_aoi.ema","Hscene_aoi_mono.ema",768,256,176,72}};
static const ending_item mapItems[7]={
    {"Hscene_station.ema","Hscene_station_mono.ema",560,96,176,72},
    {"Hscene_train.ema","Hscene_train_mono.ema",560,176,176,72},
    {"Hscene_toilet.ema","Hscene_toilet_mono.ema",560,256,176,72},
    {"Hscene_hotel.ema","Hscene_hotel_mono.ema",560,336,176,72},
    {"Hscene_roadside.ema","Hscene_roadside_mono.ema",560,416,176,72},
    {"Hscene_park.ema","Hscene_park_mono.ema",560,496,176,72},
    {"Hscene_manaka'sroom.ema","Hscene_manaka'sroom_mono.ema",560,576,176,72}};
static const char *const badgeNames[9]={
    "hanyo_chijoku.ema","hanyo_koukan.ema","hanyo_ingo.ema","hanyo_kouin.ema","hanyo_sein.ema",
    "hanyo_seiju.ema","hanyo_seiyoku.ema","hanyo_roshutu.ema","hanyo_aokan.ema"};
static const float badgeX[9]={33,61,89,117,145,173,201,229,257};
static const char *const digitNames[10]={
    "hanyo_00.ema","hanyo_01.ema","hanyo_02.ema","hanyo_03.ema","hanyo_04.ema",
    "hanyo_05.ema","hanyo_06.ema","hanyo_07.ema","hanyo_08.ema","hanyo_09.ema"};
static const char *const portraitNames[3][4]={
    {"manaka_hoho.ema","manaka_toji.ema","manaka_hara.ema","manaka_bote.ema"},
    {"yuko_hoho.ema","yuko_toji.ema","yuko_hara.ema","yuko_bote.ema"},
    {"aoi_hoho.ema","aoi_toji.ema","aoi_hara.ema","aoi_bote.ema"}};
static const char *const badgePortraitNames[3]={
    "manaka_mehoho.ema","yuko_mehoho.ema","aoi_mehoho.ema"};
static const char *const badgeVoiceNames[9]={
    "eg008_01.wav","eg009_01.wav","eg010_01.wav","eg011_01.wav","eg012_01.wav",
    "eg013_01.wav","eg014_01.wav","eg015_01.wav","eg016_01.wav"};
static const char *const stageVoicePrefixes[3]={"b","c","a"};
static const char *const stageVoiceArchives[3]={
    "RPP_12.pp","RPP_13.pp","RPP_11.pp"};
static uint16_t endingWord(const uint8_t *p) {return (uint16_t)p[0]|(uint16_t)p[1]<<8;}
static uint32_t endingDword(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static void endingAddSprite(dc_vk_sprite_item *items,size_t *count,uintptr_t texture,
    float scale,float ox,float oy,float x,float y,float width,float height) {
    if(!items||!count||*count>=256||!texture)return;
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
    dc_flow_state _flowState;
    dc_flow_selector_masks _admission;
    NSMutableDictionary<NSString *,NSNumber *> *_textures;
    AVAudioPlayer *_music,*_select,*_toggle,*_badgeVoice;
    uint32_t _pendingAction,_action,_category,_mapIndex,_stageMask,_firstStage,_secondStage;
    uint32_t _bank,_clearedCount;
    int32_t _hover,_hoverBottom,_badgeVoiceStage,_badgeVoiceIndex;
    BOOL _entered,_ready,_pausedMusic,_pausedBadgeVoice,_badgeVoiceStarted;
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
- (AVAudioPlayer *)audio:(NSString *)name archive:(NSString *)file {
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:file]] error:nil];
    if(!archive)return nil;
    for(uint32_t i=0;i<archive.entryCount;++i)if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame){
        NSData *data=[archive readEntryAtIndex:i limit:32*1024*1024 error:nil];
        AVAudioPlayer *player=data?[[AVAudioPlayer alloc] initWithData:data error:nil]:nil;
        if(player&&[player prepareToPlay])return player;
        break;
    }
    return nil;
}
- (instancetype)initWithDirectory:(NSString *)directory renderer:(dc_vk_sprite *)renderer
    transition:(DCStartupScene *)transition story:(const dc_story_state *)story error:(NSString **)error {
    if(!(self=[super init]))return nil;
    _directory=[directory copy];_renderer=renderer;_transition=transition;
    if(story)_story=*story;
    dc_flow_state flowState;memset(&flowState,0,sizeof(flowState));
    dc_game_state_init(flowState.raw,sizeof(flowState.raw));
    NSData *savedFlow=[NSData dataWithContentsOfFile:[[directory stringByAppendingPathComponent:@"save"] stringByAppendingPathComponent:@"flow.state"]];
    if(savedFlow.length>=13+DC_GAME_STATE_BYTES&&memcmp(savedFlow.bytes,"PLFL",4)==0&&((const uint8_t *)savedFlow.bytes)[4]==1) {
        memcpy(flowState.raw,(const uint8_t *)savedFlow.bytes+13,DC_GAME_STATE_BYTES);
    }
    for(unsigned i=0;i<DC_STORY_STAGES;++i) {
        uint8_t *p=flowState.raw+i*DC_FLOW_STAGE_BYTES;
        if(_story.stages[i].progress>p[0x23])p[0x23]=(uint8_t)_story.stages[i].progress;
        if(_story.stages[i].flag_a)p[0]=_story.stages[i].flag_a;
        if(_story.stages[i].flag_b)p[1]=_story.stages[i].flag_b;
    }
    if(flowState.raw[0x23]==0&&flowState.raw[DC_FLOW_STAGE_BYTES+0x23]==0&&flowState.raw[2*DC_FLOW_STAGE_BYTES+0x23]==0) {
        for(unsigned i=0;i<DC_STORY_STAGES;++i)flowState.raw[i*DC_FLOW_STAGE_BYTES+0x23]=1;
    }
    _clearedCount=0;
    for(unsigned i=0;i<DC_STORY_STAGES;++i) {
        if(flowState.raw[i*DC_FLOW_STAGE_BYTES+0x23]==2)++_clearedCount;
    }
    flowState.meta=(dc_save_slot_meta){24,2,2,255,255,255,255,0};
    if(dc_flow_selector_admission(&flowState,&_admission)!=DC_OK) {
        _admission=(dc_flow_selector_masks){0,{126,125,0,4,4,4},{0,0,0,0,0,0}};
    }
    _flowState=flowState;
    _textures=[NSMutableDictionary dictionary];
    NSString *attachError=[self attachRenderer:renderer];
    if(attachError){if(error)*error=attachError;return nil;}
    _music=[self audio:@"bgm016.wav" archive:@"RPP_01.pp"];
    _select=[self audio:@"se100.wav" archive:@"RPP_14.pp"];
    _toggle=[self audio:@"se101.wav" archive:@"RPP_14.pp"];
    NSData *configuration=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"gcd.cfg"]];
    int32_t se=-1200,bgm=-1200;
    if(configuration.length>=12){const uint8_t *p=configuration.bytes;se=(int32_t)endingDword(p+4);bgm=(int32_t)endingDword(p+8);}
    float bgmVol=powf(10,bgm/2000.f),seVol=powf(10,se/2000.f);
    if(_music){_music.volume=bgmVol;_music.numberOfLoops=-1;_pausedMusic=!([_music play]||([_music prepareToPlay]&&[_music play]));}
    if(_select)_select.volume=seVol;
    if(_toggle)_toggle.volume=seVol;
    _bank=0;_category=6;_mapIndex=7;_firstStage=3;_secondStage=3;_hover=-1;_hoverBottom=-1;_badgeVoiceStage=-1;_badgeVoiceIndex=-1;return self;
}
- (void)setPendingBadgeStage:(int32_t)stage badgeIndex:(int32_t)badgeIndex {
    if(stage>=0&&stage<3&&badgeIndex>=0&&badgeIndex<9){
        _badgeVoiceStage=stage;_badgeVoiceIndex=badgeIndex;_badgeVoiceStarted=NO;
    } else {
        _badgeVoiceStage=-1;_badgeVoiceIndex=-1;_badgeVoiceStarted=NO;
    }
}
- (void)startPendingBadgeVoiceIfNeeded {
    if(_badgeVoiceStarted||_badgeVoiceStage<0||_badgeVoiceStage>=3||_badgeVoiceIndex<0||_badgeVoiceIndex>=9)return;
    _badgeVoiceStarted=YES;
    NSString *voiceName=[NSString stringWithFormat:@"%s%s",stageVoicePrefixes[_badgeVoiceStage],badgeVoiceNames[_badgeVoiceIndex]];
    NSString *archiveName=[NSString stringWithUTF8String:stageVoiceArchives[_badgeVoiceStage]];
    _badgeVoice=[self audio:voiceName archive:archiveName];
    if(!_badgeVoice){_badgeVoiceStage=-1;_badgeVoiceIndex=-1;return;}
    NSData *configuration=[NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:@"gcd.cfg"]];
    int32_t voiceDb=-1200;
    BOOL voiceEnabled=YES;
    unsigned voiceSlot=(unsigned)(2-_badgeVoiceStage);
    if(configuration.length>=36){
        const uint8_t *p=configuration.bytes;
        voiceDb=(int32_t)endingDword(p+12+voiceSlot*4);
        voiceEnabled=p[32+voiceSlot]!=0;
    }
    _badgeVoice.volume=voiceEnabled?powf(10,voiceDb/2000.f):0.f;
    _pausedBadgeVoice=!([_badgeVoice play]||([_badgeVoice prepareToPlay]&&[_badgeVoice play]));
}
- (NSString *)attachRenderer:(dc_vk_sprite *)renderer {
    if(!renderer)return @"Ending selector renderer unavailable";
    if(_renderer==renderer&&_textures.count>0)return nil;
    [self detachRenderer];_renderer=renderer;
    if(!_textures)_textures=[NSMutableDictionary dictionary];
    DCArchive *archive=[[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:nil];
    if(!archive)return @"Original ending selector archive unavailable";
    NSMutableSet<NSString *> *names=[NSMutableSet setWithObject:@"Hscene_base.ema"];
    for(const ending_item *p=categoryItems;p<categoryItems+6;++p){[names addObject:[NSString stringWithUTF8String:p->name]];[names addObject:[NSString stringWithUTF8String:p->mono]];}
    for(const ending_item *p=stageItems;p<stageItems+3;++p){[names addObject:[NSString stringWithUTF8String:p->name]];[names addObject:[NSString stringWithUTF8String:p->mono]];}
    for(const ending_item *p=mapItems;p<mapItems+7;++p){[names addObject:[NSString stringWithUTF8String:p->name]];[names addObject:[NSString stringWithUTF8String:p->mono]];}
    for(NSString *name in @[@"Hscene_PLAY.ema",@"Hscene_PLAY_mono.ema",@"secret.ema",
        @"hanyo_gameend.ema",@"hanyo_title.ema",@"hanyo_config.ema",@"hanyo_saveload.ema",@"k_defo.ema",
        @"Hscene_select01.ema",@"Hscene_select02.ema",@"Hscene_select03.ema"])[names addObject:name];
    for(unsigned i=0;i<9;++i)[names addObject:[NSString stringWithUTF8String:badgeNames[i]]];
    for(unsigned i=0;i<10;++i)[names addObject:[NSString stringWithUTF8String:digitNames[i]]];
    for(unsigned p=0;p<3;++p){
        [names addObject:[NSString stringWithUTF8String:badgePortraitNames[p]]];
        for(unsigned v=0;v<4;++v)[names addObject:[NSString stringWithUTF8String:portraitNames[p][v]]];
    }
    for(NSString *name in names){
        uint32_t foundIndex=UINT32_MAX;
        for(uint32_t i=0;i<archive.entryCount;++i)if([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name]==NSOrderedSame){
            foundIndex=i;break;
        }
        if(foundIndex==UINT32_MAX)continue;
        NSError *reason=nil;
        DCDecodedImage *image=[archive decodeImageAtIndex:foundIndex inputLimit:16*1024*1024 outputLimit:64*1024*1024 error:&reason];
        uintptr_t texture=0;
        if(!image||dc_vk_sprite_upload(_renderer,image.width,image.height,image.rgba.bytes,image.rgba.length,&texture)!=DC_OK)
            return reason.localizedDescription?:[NSString stringWithFormat:@"Ending selector texture unavailable: %@",name];
        _textures[name]=@(texture);
    }
    if(!_textures[@"Hscene_base.ema"]||!_textures[@"Hscene_PLAY.ema"])return @"Ending selector base resources unavailable";
    return nil;
}
- (uintptr_t)texture:(NSString *)name {
    NSNumber *value=_textures[name];if(value)return value.unsignedLongLongValue;
    return _textures[[name stringByReplacingOccurrencesOfString:@"2P" withString:@"2p"]].unsignedLongLongValue;
}
- (BOOL)categoryDisabled:(unsigned)i {return i>=6 || (_admission.disabled_categories&(1u<<i))!=0;}
- (BOOL)mapDisabled:(unsigned)i {return _category>=6 || i>=7 || (_admission.disabled_maps[_category]&(1u<<i))!=0;}
- (BOOL)stageDisabled:(unsigned)i {return _category>=6 || i>=3 || (_admission.disabled_stages[_category]&(1u<<i))!=0;}
- (BOOL)hit:(float)x y:(float)y item:(ending_item)item{return x>=item.x&&x<=item.x+item.w&&y>=item.y&&y<=item.y+item.h;}
- (void)playToggle {if(_toggle){_toggle.currentTime=0;[_toggle play];}}
- (void)playSelect {if(_select){_select.currentTime=0;[_select play];}}
- (NSString *)depart:(uint32_t)action tick:(uint32_t)tick {
    _pendingAction=action;_hover=-1;_hoverBottom=-1;
    if(_badgeVoice){[_badgeVoice stop];_badgeVoiceStage=-1;_badgeVoiceIndex=-1;_pausedBadgeVoice=NO;}
    if(action!=6)[self playSelect];
    return [_transition requestTransition:action==6?3:2 tick:tick]==DC_OK?nil:@"Ending selector departure transition failed";
}
- (NSString *)chooseFromInput:(dc_pc_frame)input x:(float)x y:(float)y tick:(uint32_t)tick {
    if(!_ready||_pendingAction)return nil;
    _hover=-1;_hoverBottom=-1;
    if(input.keys[1]==3)return [self depart:6 tick:tick];
    if(_badgeVoiceStage>=0)return nil;
    if(y>=704&&y<=760){
        if(x>=48&&x<=104)_hoverBottom=0;
        else if(x>=128&&x<=184)_hoverBottom=1;
        else if(x>=248&&x<=304)_hoverBottom=2;
        else if(x>=328&&x<=384)_hoverBottom=3;
    }
    if(_bank==3&&[self hit:x y:y item:(ending_item){"Hscene_PLAY.ema",NULL,800,624,200,48}])_hover=0;
    if(input.keys[0x3b]==3)return [self depart:3 tick:tick];
    if(input.keys[0x3c]==3||input.keys[0x1f]==3)return [self depart:5 tick:tick];
    if(input.mouse[0]==3&&_hoverBottom>=0){
        static const uint32_t bottomActions[4]={4,2,3,5};
        return [self depart:bottomActions[_hoverBottom] tick:tick];
    }
    if(input.mouse[1]==2||input.mouse[1]==3){
        if(_bank==3){_bank=1;}
        else if(_bank==1){_stageMask=0;_firstStage=3;_secondStage=3;_bank=2;}
        else if(_bank==2){_mapIndex=7;_bank=0;}
        else if(_bank==0){_category=6;}
        return nil;
    }
    if(input.mouse[0]!=3)return nil;
    if(_bank==3&&[self hit:x y:y item:(ending_item){"Hscene_PLAY.ema",NULL,800,624,200,48}]){
        if(_category==5)_stageMask=7;
        if(_stageMask)return [self depart:1 tick:tick];
        return nil;
    }
    if(_bank==0){
        for(unsigned i=0;i<6;++i)if([self hit:x y:y item:categoryItems[i]]){
            if([self categoryDisabled:i])return nil;
            _category=i;_mapIndex=7;_stageMask=0;_firstStage=3;_secondStage=3;_bank=2;[self playToggle];
            return nil;
        }
    } else if(_bank==2){
        for(unsigned i=0;i<7;++i)if([self hit:x y:y item:mapItems[i]]){
            if([self mapDisabled:i])return nil;
            _mapIndex=i;_bank=1;
            [self playToggle];
            return nil;
        }
    } else if(_bank==1){
        for(unsigned i=0;i<3;++i)if([self hit:x y:y item:stageItems[i]]){
            if([self stageDisabled:i])return nil;
            if(_category==5){
                _stageMask|=1u<<i;
                if(_stageMask==7)_bank=3;
                [self playToggle];
            } else if(_category==4){
                if(_stageMask==0){
                    _firstStage=i;_stageMask=1u<<i;
                } else if(_stageMask==(1u<<_firstStage)){
                    if(_firstStage!=i){_secondStage=i;_stageMask|=1u<<i;_bank=3;}
                } else {
                    if(_firstStage!=i&&_secondStage!=i){
                        _firstStage=_secondStage;_secondStage=i;
                        _stageMask=(1u<<_firstStage)|(1u<<_secondStage);
                    }
                    _bank=3;
                }
                [self playToggle];
            } else {
                _firstStage=i;_stageMask=1u<<i;_bank=3;[self playToggle];
            }
            return nil;
        }
    }
    return nil;
}
- (NSString *)drawAtTick:(uint32_t)tick pcInput:(dc_pc_frame)input width:(uint32_t)width height:(uint32_t)height {
    if(!_renderer||!_transition)return @"Ending selector renderer unavailable";
    if(_pausedMusic){[AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];[AVAudioSession.sharedInstance setActive:YES error:nil];if(!_music||[_music play]||([_music prepareToPlay]&&[_music play]))_pausedMusic=NO;}
    if(_pausedBadgeVoice){[AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];[AVAudioSession.sharedInstance setActive:YES error:nil];if(!_badgeVoice||[_badgeVoice play]||([_badgeVoice prepareToPlay]&&[_badgeVoice play]))_pausedBadgeVoice=NO;}
    uint32_t ready=0;if(!_entered){if([_transition requestTransition:4 tick:tick]!=DC_OK)return @"Ending selector entry transition failed";_entered=YES;}
    if([_transition queryTransitionReady:&ready]!=DC_OK)return @"Ending selector transition query failed";
    if(ready){
        if(_pendingAction){
            if(_pendingAction==6){
                _pausedMusic=NO;_pausedBadgeVoice=NO;
                [_music pause];[_select pause];[_toggle pause];[_badgeVoice pause];
                _action=6;
            } else if(!_select||!_select.isPlaying){
                _pausedMusic=NO;_pausedBadgeVoice=NO;
                if(_pendingAction==1||_pendingAction==2||_pendingAction==4)[_music stop];
                else {[_music pause];[_select pause];[_toggle pause];[_badgeVoice pause];}
                _action=_pendingAction;
            }
        } else {
            _ready=YES;
            [self startPendingBadgeVoiceIfNeeded];
            if(_badgeVoiceStarted&&!_pausedBadgeVoice&&(!_badgeVoice||!_badgeVoice.isPlaying)){_badgeVoiceStage=-1;_badgeVoiceIndex=-1;}
        }
    }
    float scale=fminf(width/1024.f,height/768.f),ox=(width-1024*scale)*.5f,oy=(height-768*scale)*.5f;
    float x=input.x*1024,y=input.y*768;
    NSString *inputFailure=[self chooseFromInput:input x:x y:y tick:tick];
    if(inputFailure)return inputFailure;
    dc_vk_sprite_item spriteItems[256]={0};size_t spriteCount=0;
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_base.ema"],scale,ox,oy,0,0,1024,768);
    static const float scoreX[4]={260,245,230,215},timeX[5]={260,245,218,203,176};
    static const unsigned portraitVariant[6]={0,0,1,0,2,3};
    for(unsigned panel=0;panel<3;++panel){
        unsigned character=2-panel;
        const uint8_t *p=_flowState.raw+character*DC_FLOW_STAGE_BYTES;
        unsigned portrait=p[0x22];
        if(_badgeVoiceStage==(int32_t)character){
            if(_ready&&!_pendingAction){
                NSString *pName=[NSString stringWithUTF8String:badgePortraitNames[panel]];
                endingAddSprite(spriteItems,&spriteCount,[self texture:pName],scale,ox,oy,72,96+196*panel,224,64);
            }
        } else if(portrait>0&&portrait<6&&portrait!=3){
            NSString *pName=[NSString stringWithUTF8String:portraitNames[panel][portraitVariant[portrait]]];
            endingAddSprite(spriteItems,&spriteCount,[self texture:pName],scale,ox,oy,72,96+196*panel,224,64);
        }
        for(unsigned flag=0;flag<9;++flag)if(p[3+flag]){
            NSString *bName=[NSString stringWithUTF8String:badgeNames[flag]];
            endingAddSprite(spriteItems,&spriteCount,[self texture:bName],scale,ox,oy,badgeX[flag],237+196*panel,24,32);
        }
        for(unsigned field=0;field<2;++field){
            unsigned value=endingWord(p+(field?0xc:0x26));if(value==10000)value=9999;
            uint8_t digits[4];for(unsigned i=0;i<4;++i){digits[i]=value%10;value/=10;}
            for(unsigned i=0;i<4;++i){
                BOOL visible=i==0;for(unsigned j=i;j<4;++j)if(digits[j])visible=YES;
                if(visible){
                    NSString *dName=[NSString stringWithUTF8String:digitNames[digits[i]]];
                    endingAddSprite(spriteItems,&spriteCount,[self texture:dName],scale,ox,oy,scoreX[i],(field?190:165)+195*panel,8,16);
                }
            }
        }
        uint32_t time=endingDword(p+0x30);uint8_t timeDigits[5]={0,0,0,3,1};
        if(time<90000){
            unsigned value=time/10;for(unsigned i=0;i<2;++i){timeDigits[i]=value%10;value/=10;}
            timeDigits[4]=value/60;value%=60;for(unsigned i=2;i<4;++i){timeDigits[i]=value%10;value/=10;}
        }
        for(unsigned i=0;i<5;++i){
            NSString *dName=[NSString stringWithUTF8String:digitNames[timeDigits[i]]];
            endingAddSprite(spriteItems,&spriteCount,[self texture:dName],scale,ox,oy,timeX[i],213+195*panel,8,16);
        }
    }
    BOOL secret3P=(_clearedCount<2);
    BOOL secret4P=(_clearedCount<3);
    if(_category<6){
        endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:categoryItems[_category].name]],scale,ox,oy,categoryItems[_category].x,categoryItems[_category].y,176,72);
    }
    for(unsigned i=0;i<3;++i)if(_stageMask&(1u<<i)){
        endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:stageItems[i].name]],scale,ox,oy,stageItems[i].x,stageItems[i].y,176,72);
    }
    if(_mapIndex<7){
        endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:mapItems[_mapIndex].name]],scale,ox,oy,mapItems[_mapIndex].x,mapItems[_mapIndex].y,176,72);
    }
    if(_bank==3&&_hover==0){
        endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_PLAY.ema"],scale,ox,oy,800,624,200,48);
    }
    if(_hoverBottom==0)endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_gameend.ema"],scale,ox,oy,48,704,56,56);
    else if(_hoverBottom==1)endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_title.ema"],scale,ox,oy,128,704,56,56);
    else if(_hoverBottom==2)endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_config.ema"],scale,ox,oy,248,704,56,56);
    else if(_hoverBottom==3)endingAddSprite(spriteItems,&spriteCount,[self texture:@"hanyo_saveload.ema"],scale,ox,oy,328,704,56,56);
    for(unsigned i=0;i<6;++i){
        BOOL showMono=(_bank==0)?[self categoryDisabled:i]:(i!=_category);
        if(showMono){
            endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:categoryItems[i].mono]],scale,ox,oy,categoryItems[i].x,categoryItems[i].y,176,72);
        }
    }
    for(unsigned i=0;i<3;++i){
        BOOL showMono=(_bank==0||_bank==2)?YES:((_bank==1)?[self stageDisabled:i]:((_stageMask&(1u<<i))==0));
        if(showMono){
            endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:stageItems[i].mono]],scale,ox,oy,stageItems[i].x,stageItems[i].y,176,72);
        }
    }
    for(unsigned i=0;i<7;++i){
        BOOL showMono=(_bank==0)?YES:((_bank==2)?[self mapDisabled:i]:(i!=_mapIndex));
        if(showMono){
            endingAddSprite(spriteItems,&spriteCount,[self texture:[NSString stringWithUTF8String:mapItems[i].mono]],scale,ox,oy,mapItems[i].x,mapItems[i].y,176,72);
        }
    }
    if(_bank!=3){
        endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_PLAY_mono.ema"],scale,ox,oy,800,624,200,48);
    }
    if(secret3P)endingAddSprite(spriteItems,&spriteCount,[self texture:@"secret.ema"],scale,ox,oy,categoryItems[4].x,categoryItems[4].y,176,72);
    if(secret4P)endingAddSprite(spriteItems,&spriteCount,[self texture:@"secret.ema"],scale,ox,oy,categoryItems[5].x,categoryItems[5].y,176,72);
    if(_bank==0)endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_select01.ema"],scale,ox,oy,336,48,200,536);
    else if(_bank==2)endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_select02.ema"],scale,ox,oy,544,48,200,616);
    else if(_bank==1)endingAddSprite(spriteItems,&spriteCount,[self texture:@"Hscene_select03.ema"],scale,ox,oy,752,48,200,296);
    endingAddSprite(spriteItems,&spriteCount,[self texture:@"k_defo.ema"],scale,ox,oy,x-6,y-6,64,64);
    return [_transition drawSprites:spriteItems count:spriteCount tick:tick width:width height:height];
}
- (void)pause {
    _pausedMusic=_pausedMusic||_music.isPlaying;
    _pausedBadgeVoice=_pausedBadgeVoice||_badgeVoice.isPlaying;
    [_music pause];[_select pause];[_toggle pause];[_badgeVoice pause];
}
- (void)resumeFromTemporaryScreen {
    _pendingAction=_action=0;_entered=_ready=NO;_pausedBadgeVoice=NO;
    NSData *configuration=[NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:@"gcd.cfg"]];
    int32_t se=-1200,bgm=-1200;
    if(configuration.length>=12){const uint8_t *p=configuration.bytes;se=(int32_t)endingDword(p+4);bgm=(int32_t)endingDword(p+8);}
    float bgmVol=powf(10,bgm/2000.f),seVol=powf(10,se/2000.f);
    if(_music)_music.volume=bgmVol;
    if(_select)_select.volume=seVol;
    if(_toggle)_toggle.volume=seVol;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    _pausedMusic=(_music&&!([_music play]||([_music prepareToPlay]&&[_music play])));
}
- (void)detachRenderer {
    for(NSNumber *value in _textures.allValues)if(_renderer)dc_vk_sprite_remove_texture(_renderer,value.unsignedLongLongValue);
    [_textures removeAllObjects];_renderer=NULL;
}
- (void)dealloc {[self detachRenderer];[_music stop];[_select stop];[_toggle stop];[_badgeVoice stop];}
@end
