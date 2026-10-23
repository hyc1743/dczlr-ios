#ifndef DC_MENU_H
#define DC_MENU_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif
#define DC_MENU_LIMIT 32u
typedef struct dc_menu_button {
    float x,y,width,height;
    uint32_t disabled,press_activate,toggle;
} dc_menu_button;
typedef struct dc_menu_state {
    int32_t selected,hover;
    uint32_t active,pressed[DC_MENU_LIMIT],toggled[DC_MENU_LIMIT];
} dc_menu_state;
/* Original 0x45f7c0 with 0x45f600 inclusive scaled hit bounds. First admitted
 * hit wins. x==-1 or disabled==1 excludes a row. Pressed rows are cleared only
 * while traversed through the first hit; later rows retain state. Return code
 * -1 no hit; 0 same hover; 2 changed hover; 1 activation; 3 release on new row.
 * Input code 3 is original release/click; odd codes can activate press flags.
 * No-hit preserves hover/selected. Finite geometry, nonnegative dimensions
 * and positive scale admitted. All failures preserve state/result. */
DC_API dc_status dc_menu_step(dc_menu_state *state,const dc_menu_button *buttons,
    size_t count,int32_t x,int32_t y,float scale,uint8_t input_code,int32_t *result);

/* Title routing from 0x5129c0/0x52b830. The host supplies the exact
 * transition-query and selection-player busy results. Callback installation,
 * cleanup, save-state initialization and audio are ordered host operations. */
typedef struct dc_title_state { uint32_t action,waiting,hover; } dc_title_state;
typedef struct dc_title_input {
    uint32_t transition_ready,selection_busy,escape_code;
    int32_t menu_result,menu_row;
} dc_title_input;
enum dc_title_operation {
    DC_TITLE_CLEANUP=1, DC_TITLE_ENTER=2, DC_TITLE_INIT_GAME=3,
    DC_TITLE_BACKUP=4, DC_TITLE_HIDE=5, DC_TITLE_STOP_MUSIC=6,
    DC_TITLE_PLAY_SELECTION=7, DC_TITLE_TRANSITION=8, DC_TITLE_QUIT=9
};
/* ENTER values: 1 intro, 2 load, 3 edit, 4 extra, 6 options.
 * BACKUP values: 1 load slots, 2 options slots. HIDE value 2 also clears
 * the original context byte +0x68b5. INIT_GAME includes chapter=0.
 * ENTER clears the four active callbacks before installing target init.
 * QUIT clears the context running flag. No iOS process-exit is implied. */
typedef struct dc_title_command { uint32_t kind,value; } dc_title_command;
typedef struct dc_title_plan {
    dc_title_state next;
    uint32_t count,departed;
    dc_title_command commands[6];
} dc_title_plan;
/* Run the waiting helper before accepting this frame's input. Initial title
 * state is {0,1,255} after host transition request 4. Once departed is set,
 * the host replaces this planner's update callback. Result 3 changes hover
 * but does not activate. Output is transactional; input/output may alias. */
DC_API dc_status dc_title_build_plan(const dc_title_state *state,
    const dc_title_input *input,dc_title_plan *out);
#ifdef __cplusplus
}
#endif
#endif
