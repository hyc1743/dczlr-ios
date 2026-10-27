#include "dc_story.h"
#include <string.h>

/* Static tables recovered byte-exact from the original executable. */
static const uint8_t story_map_table[DC_STORY_CHAPTERS] = {
    0xff,0xff,0xff,0x00,0xff,0x01,0xff,0x03,0xff,0xff,0x00,0xff,0x01,
    0xff,0x06,0xff,0xff,0x00,0xff,0x01,0xff,0x04,0xff,0xff,0xff,0xff,0xff,0xff,0xff
};
static const uint8_t story_stage_table[DC_STORY_CHAPTERS] = {
    0xff,0xff,0xff,0x02,0xff,0x02,0xff,0x02,0xff,0xff,0x01,0xff,0x01,
    0xff,0x01,0xff,0xff,0x00,0xff,0x00,0xff,0x00,0xff,0xff,0xff,0xff,0xff,0xff,0xff
};
static const uint8_t story_script_table[DC_STORY_CHAPTERS][2] = {
    {0,2},{1,31},{2,9},{255,255},{15,2},{255,255},{3,38},{255,255},
    {4,31},{5,5},{255,255},{16,2},{255,255},{6,42},{255,255},{7,43},
    {8,4},{255,255},{9,4},{255,255},{10,51},{255,255},{11,74},{13,4},
    {255,255},{12,13},{14,4},{17,1},{18,2}
};
/* Original next-scene callbacks from 0x006d39d0; classified by the scene
 * initializer's chapter-type byte (0x1352e). */
static const uint32_t story_callback_table[DC_STORY_CHAPTERS] = {
    0x00605510,0x00605510,0x00605510,0x00512cc0,0x00605510,0x00489f20,
    0x00605510,0x00483510,0x00605510,0x00605510,0x00512cc0,0x00605510,
    0x00489f20,0x00605510,0x00483510,0x00605510,0x00605510,0x00512cc0,
    0x00605510,0x00489f20,0x00605510,0x00483510,0x00605510,0x00605510,
    0x0051abb0,0x00605510,0x00605510,0x00605510,0x00605510
};
static const uint32_t story_callback_scene[DC_STORY_CHAPTERS] = {
    DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_SCRIPT,
    DC_STORY_SCENE_GAMEPLAY,DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_WATCH,
    DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_NIGHT,DC_STORY_SCENE_SCRIPT,
    DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_GAMEPLAY,DC_STORY_SCENE_SCRIPT,
    DC_STORY_SCENE_WATCH,DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_NIGHT,
    DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_GAMEPLAY,
    DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_WATCH,DC_STORY_SCENE_SCRIPT,
    DC_STORY_SCENE_NIGHT,DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_SCRIPT,
    DC_STORY_SCENE_ENDING,DC_STORY_SCENE_SCRIPT,
    DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_SCRIPT,DC_STORY_SCENE_SCRIPT
};
static const uint32_t story_callback_type[DC_STORY_CHAPTERS] = {
    3,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,2,3,3,3,3
};

static int valid_state(const dc_story_state *s) {
    if (!s || s->chapter >= DC_STORY_CHAPTERS || (s->map > 8 && s->map != 0xff) ||
        (s->stage > 2 && s->stage != 0xff)) return 0;
    for (uint32_t i = 0; i < DC_STORY_STAGES; ++i) {
        if (s->stages[i].flag_a > 1 || s->stages[i].flag_b > 1 ||
            s->stages[i].progress > 2) return 0;
    }
    return 1;
}

static void plan_command(dc_story_plan *p, uint32_t kind, uint32_t value) {
    p->commands[p->count++] = (dc_story_command){kind, value};
}

dc_status dc_story_chapter_profile(uint32_t chapter, dc_story_chapter *out) {
    if (!out) return DC_ARGUMENT;
    if (chapter >= DC_STORY_CHAPTERS) return DC_RANGE;
    dc_story_chapter profile;
    profile.script = story_script_table[chapter][0] == 255
        ? -1 : (int32_t)story_script_table[chapter][0];
    profile.last_frame = story_script_table[chapter][1] == 255
        ? -1 : (int32_t)story_script_table[chapter][1];
    profile.map = story_map_table[chapter] == 255
        ? -1 : (int32_t)story_map_table[chapter];
    profile.stage = story_stage_table[chapter] == 255
        ? -1 : (int32_t)story_stage_table[chapter];
    profile.scene = story_callback_scene[chapter];
    profile.scene_type = story_callback_type[chapter];
    *out = profile;
    return DC_OK;
}

static dc_status story_advance_core(const dc_story_state *state,
        const dc_story_outcomes *outcomes, uint32_t menu_action,
        dc_story_plan *out) {
    if (!state || !outcomes || !out) return DC_ARGUMENT;
    if (!valid_state(state)) return DC_RANGE;
    for (uint32_t i = 0; i < DC_STORY_STAGES; ++i)
        if (outcomes->a[i] < 0 || outcomes->b[i] < 0) return DC_RANGE;
    dc_story_plan p = {0};
    p.next = *state;
    if (menu_action == 2) {
        /* FUN_00523380 action 2: apply the recorded stage outcomes, advance
         * the chapter, install the original next-scene callback and commit
         * the map/stage selectors from the static tables. */
        uint32_t stage = state->stage;
        if(stage>=DC_STORY_STAGES)return DC_RANGE;
        if (outcomes->a[stage] != 0) p.next.stages[stage].flag_a = 1;
        else if (outcomes->b[stage] != 0) p.next.stages[stage].flag_b = 1;
        if (p.next.chapter + 1 >= DC_STORY_CHAPTERS) return DC_RANGE;
        ++p.next.chapter;
        /* The original writes the table bytes verbatim; script chapters
         * receive 0xff and keep no map/stage selector. */
        p.next.map = story_map_table[p.next.chapter];
        p.next.stage = story_stage_table[p.next.chapter];
        plan_command(&p, DC_STORY_CLEAR_CALLBACKS, 0);
        plan_command(&p, DC_STORY_INSTALL_NEXT, story_callback_table[p.next.chapter]);
        plan_command(&p, DC_STORY_SET_MAP_STAGE, p.next.chapter);
        plan_command(&p, DC_STORY_ENTER_SCENE, story_callback_scene[p.next.chapter]);
    } else if (menu_action == 3) {
        /* FUN_00523380 action 3: configuration screen (type9). */
        plan_command(&p, DC_STORY_CLEAR_CALLBACKS, 0);
        plan_command(&p, DC_STORY_ENTER_CONFIG, 0);
        p.departed = 1;
    } else if (menu_action == 4) {
        /* FUN_00523380 action 4: save/load menu scene. */
        plan_command(&p, DC_STORY_CLEAR_CALLBACKS, 0);
        plan_command(&p, DC_STORY_ENTER_SAVE_MENU, 0);
        p.departed = 1;
    } else if (menu_action == 5) {
        /* FUN_00523380 action 5: fade transition scene. */
        plan_command(&p, DC_STORY_CLEAR_CALLBACKS, 0);
        plan_command(&p, DC_STORY_ENTER_FADE, 0);
        p.departed = 1;
    } else {
        return DC_RANGE;
    }
    *out = p;
    return DC_OK;
}

dc_status dc_story_advance(const dc_story_state *state,
        const dc_story_outcomes *outcomes, dc_story_plan *out) {
    return story_advance_core(state, outcomes, 2, out);
}

dc_status dc_story_menu_action(const dc_story_state *state,
        uint32_t action_code, dc_story_plan *out) {
    if (!state || !out) return DC_ARGUMENT;
    if (!valid_state(state)) return DC_RANGE;
    if (action_code < 2 || action_code > 5) return DC_RANGE;
    dc_story_outcomes zero = {{0,0,0},{0,0,0}};
    return story_advance_core(state, &zero, action_code, out);
}

dc_status dc_story_script_finish(const dc_story_state *state,
        dc_story_plan *out) {
    if (!state || !out) return DC_ARGUMENT;
    if (!valid_state(state) || state->chapter >= 25)
        return DC_RANGE;
    dc_story_plan p = {0};
    p.next = *state;
    ++p.next.chapter;
    dc_story_chapter profile;
    dc_status status = dc_story_chapter_profile(p.next.chapter, &profile);
    if (status != DC_OK) return status;
    if (profile.script >= 0) {
        /* The next chapter is another numbered script. */
        plan_command(&p, DC_STORY_INSTALL_NEXT, story_callback_table[p.next.chapter]);
        p.next.map = profile.map < 0 ? p.next.map : (uint32_t)profile.map;
        p.next.stage = profile.stage < 0 ? p.next.stage : (uint32_t)profile.stage;
    } else {
        /* Non-script chapter: the original installs the next-scene callback
         * and clears the per-frame callback bank. The ending scene keeps the
         * previous map/stage selectors. */
        if (profile.scene != DC_STORY_SCENE_ENDING && (profile.map < 0 || profile.stage < 0))
            return DC_FORMAT;
        if (profile.map >= 0) p.next.map = (uint32_t)profile.map;
        if (profile.stage >= 0) p.next.stage = (uint32_t)profile.stage;
        if (p.next.chapter == 24 && p.next.stages[0].progress == 0) {
            p.next.unlocked = 1;
            for (uint32_t i = 0; i < DC_STORY_STAGES; ++i)
                p.next.stages[i].progress = 1;
        }
        plan_command(&p, DC_STORY_CLEAR_CALLBACKS, 0);
        plan_command(&p, DC_STORY_INSTALL_NEXT, story_callback_table[p.next.chapter]);
        plan_command(&p, DC_STORY_SET_MAP_STAGE, p.next.chapter);
        plan_command(&p, DC_STORY_ENTER_SCENE, profile.scene);
        p.departed = 1;
    }
    *out = p;
    return DC_OK;
}

static uint32_t story_checksum(const uint8_t *p,size_t n) {
    uint32_t h=2166136261u;
    for(size_t i=0;i<n;++i)h=(h^p[i])*16777619u;
    return h;
}

dc_status dc_story_save(const dc_story_state *state,void *bytes,size_t length) {
    if(!state||!bytes)return DC_ARGUMENT;
    if(length<DC_STORY_SAVE_BYTES)return DC_RANGE;
    if(!valid_state(state))return DC_RANGE;
    uint8_t record[DC_STORY_SAVE_BYTES]={0};
    memcpy(record,"PLGS",4);
    record[4]=1;
    record[8]=(uint8_t)state->chapter;
    record[9]=(uint8_t)state->map;
    record[10]=(uint8_t)state->stage;
    record[11]=(uint8_t)(state->unlocked?1:0);
    for(uint32_t i=0;i<DC_STORY_STAGES;++i) {
        record[12+i*3]=(uint8_t)(state->stages[i].flag_a?1:0);
        record[13+i*3]=(uint8_t)(state->stages[i].flag_b?1:0);
        record[14+i*3]=(uint8_t)state->stages[i].progress;
    }
    uint32_t sum=story_checksum(record,DC_STORY_SAVE_BYTES-4);
    memcpy(record+DC_STORY_SAVE_BYTES-4,&sum,4);
    memcpy(bytes,record,sizeof(record));
    return DC_OK;
}

dc_status dc_story_load(const void *bytes,size_t length,dc_story_state *out) {
    if(!bytes||!out)return DC_ARGUMENT;
    if(length<DC_STORY_SAVE_BYTES)return DC_RANGE;
    const uint8_t *record=bytes;
    uint32_t expected=story_checksum(record,DC_STORY_SAVE_BYTES-4),actual;
    memcpy(&actual,record+DC_STORY_SAVE_BYTES-4,4);
    if(memcmp(record,"PLGS",4)||record[4]!=1||expected!=actual)return DC_FORMAT;
    dc_story_state next={0};
    next.chapter=record[8];
    next.map=record[9];
    next.stage=record[10];
    next.unlocked=record[11]!=0;
    for(uint32_t i=0;i<DC_STORY_STAGES;++i) {
        next.stages[i].flag_a=record[12+i*3]!=0;
        next.stages[i].flag_b=record[13+i*3]!=0;
        next.stages[i].progress=record[14+i*3];
    }
    if(!valid_state(&next))return DC_RANGE;
    *out=next;
    return DC_OK;
}
