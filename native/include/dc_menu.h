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
#ifdef __cplusplus
}
#endif
#endif
