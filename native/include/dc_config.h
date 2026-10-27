#ifndef DC_CONFIG_H
#define DC_CONFIG_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

#define DC_CONFIG_BYTES 48u
#define DC_CONFIG_SLIDERS 10u
/* Data/gcd.cfg is the original raw Main+0x21fcc block. Keep padding and
 * all otherwise unmodified bytes when applying a single setting. */
typedef struct dc_config { uint8_t bytes[DC_CONFIG_BYTES]; } dc_config;
typedef struct dc_config_track { float x,y,width,height; } dc_config_track;
/* UI order: voice, music, effects, three model alpha values, wheel, RGB. */
DC_API dc_status dc_config_default(dc_config *out);
DC_API dc_status dc_config_reset(dc_config *state);
DC_API dc_status dc_config_decode(const void *bytes,size_t length,dc_config *out);
DC_API dc_status dc_config_encode(const dc_config *state,void *bytes,size_t capacity);
DC_API dc_status dc_config_slider_track(uint32_t slider,dc_config_track *out);
DC_API dc_status dc_config_slider_value(const dc_config *state,uint32_t slider,float *out);
DC_API dc_status dc_config_slider_center(const dc_config *state,uint32_t slider,float *out);
DC_API dc_status dc_config_slider_apply(dc_config *state,uint32_t slider,float center_x);
/* Switch UI order: map levels1..3, display+19, secondary+18, marker+1a. */
DC_API dc_status dc_config_switch_value(const dc_config *state,uint32_t index,uint32_t *out);
DC_API dc_status dc_config_switch_toggle(dc_config *state,uint32_t index);
#ifdef __cplusplus
}
#endif
#endif
