#ifndef DC_STORY_H
#define DC_STORY_H
#include "dc_menu.h"
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Original story dispatcher tables recovered from the local Windows
 * executable (SHA-256 70aebdcd...) at the following addresses:
 * - 0x006d39d0: per-chapter next-scene callback table (26 entries)
 * - 0x006d3a44: per-chapter story stage selector (26 bytes)
 * - 0x006d3a84: per-chapter map selector (26 bytes)
 * - 0x0078d908: per-chapter script descriptor table (26 x 2 bytes)
 * The chapter-end semantics follow FUN_00523380 (action 2) and the
 * transition actions 3/4/5 install FUN_0050de60 (edit), FUN_0052e070
 * (save/load menu) and FUN_0051e010 (fade transition). */

#define DC_STORY_CHAPTERS 26u
#define DC_STORY_STAGES 3u
#define DC_STORY_STAGE_BYTES 0x2198u
#define DC_STORY_SAVE_BYTES 72u

typedef enum dc_story_scene_kind {
    DC_STORY_SCENE_SCRIPT = 0,   /* FUN_00605510, chapter type 3 */
    DC_STORY_SCENE_GAMEPLAY = 1, /* FUN_00512cc0, chapter type 4 */
    DC_STORY_SCENE_WATCH = 2,    /* FUN_00489f20, chapter type 5 */
    DC_STORY_SCENE_NIGHT = 3,    /* FUN_00483510, chapter type 6 */
    DC_STORY_SCENE_ENDING = 4    /* FUN_0051abb0, chapter type 2 */
} dc_story_scene_kind;

typedef struct dc_story_chapter {
    int32_t script;      /* -1 when the chapter has no numbered script */
    int32_t last_frame;  /* -1 when the chapter has no numbered script */
    int32_t map;         /* 0..8 or -1 */
    int32_t stage;       /* 0..2 or -1 */
    uint32_t scene;      /* dc_story_scene_kind */
    uint32_t scene_type; /* original 0x1352e byte */
} dc_story_chapter;

typedef struct dc_story_stage {
    uint32_t flag_a; /* 0x13538 + stage*0x2198 */
    uint32_t flag_b; /* 0x13539 + stage*0x2198 */
    uint32_t progress; /* 0x1355b + stage*0x2198 */
} dc_story_stage;

typedef struct dc_story_state {
    uint32_t chapter;      /* original 0x13535 */
    uint32_t map;          /* original 0x13533 */
    uint32_t stage;        /* original 0x13530 */
    dc_story_stage stages[DC_STORY_STAGES];
    uint32_t unlocked;     /* original 0x156f3/0x1788b progress flags */
} dc_story_state;

/* Scene context action record used by the chapter-end menu. Row outcomes
 * mirror the shorts at scene-context offset 0x184c + 0xa4/0xa6 + stage*4. */
typedef struct dc_story_outcomes {
    int32_t a[DC_STORY_STAGES];
    int32_t b[DC_STORY_STAGES];
} dc_story_outcomes;

typedef enum dc_story_command_kind {
    DC_STORY_CLEAR_CALLBACKS = 0,
    DC_STORY_INSTALL_NEXT = 1,   /* install the original callback table entry */
    DC_STORY_SET_MAP_STAGE = 2,  /* commit 0x13533/0x13530 from the tables */
    DC_STORY_ENTER_SCENE = 3,    /* enter the chapter's scene kind */
    DC_STORY_ENTER_EDIT = 4,     /* FUN_0050de60 destination */
    DC_STORY_ENTER_SAVE_MENU = 5,/* FUN_0052e070 destination */
    DC_STORY_ENTER_FADE = 6      /* FUN_0051e010 destination */
} dc_story_command_kind;

typedef struct dc_story_command {
    uint32_t kind;
    uint32_t value;
} dc_story_command;

typedef struct dc_story_plan {
    dc_story_state next;
    dc_story_command commands[8];
    uint32_t count;
    uint32_t departed;
} dc_story_plan;

/* Look up one chapter's full descriptor. */
DC_API dc_status dc_story_chapter_profile(uint32_t chapter, dc_story_chapter *out);

/* Original chapter-end handler (FUN_00523380 action 2): apply the selected
 * stage outcomes, advance the chapter and select the next map/stage. */
DC_API dc_status dc_story_advance(const dc_story_state *state,
    const dc_story_outcomes *outcomes, dc_story_plan *out);

/* Original transition actions from the chapter-end menu (FUN_00523380
 * actions 3/4/5 and the script dispatcher actions): edit scene, save/load
 * menu scene and fade transition. */
DC_API dc_status dc_story_menu_action(const dc_story_state *state,
    uint32_t action_code, dc_story_plan *out);

/* Resolve the chapter entry after a script chapter completes. Returns the
 * next chapter's profile; non-script chapters depart to their scene. */
DC_API dc_status dc_story_script_finish(const dc_story_state *state,
    dc_story_plan *out);

/* Host save record for the story state: magic "PLGS", version 1, the story
 * fields and a FNV-1a checksum. */
DC_API dc_status dc_story_save(const dc_story_state *state,void *bytes,size_t length);
DC_API dc_status dc_story_load(const void *bytes,size_t length,dc_story_state *out);

#ifdef __cplusplus
}
#endif
#endif
