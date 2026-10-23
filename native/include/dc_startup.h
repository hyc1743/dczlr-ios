#ifndef DC_STARTUP_H
#define DC_STARTUP_H
#include "dc_pp.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Two-card startup update reconstructed from 0x00512050 and 0x0052bc10.
 * This is a state/action planner, not the complete game bootstrap. Resource
 * loading, the external transition controller, rendering and the next game
 * state remain host operations. Numeric transition states retain their observed
 * values; their animation semantics are not inferred by this module. */
typedef struct dc_startup_state {
    uint32_t card, waiting, advanced, elapsed;
} dc_startup_state;
typedef struct dc_startup_input {
    int32_t delta, transition_state;
    uint32_t transition_complete;
    uint8_t skip_code; /* Only original input code 3 triggers skipping. */
} dc_startup_input;
enum dc_startup_action_kind {
    DC_STARTUP_REQUEST_TRANSITION = 1,
    DC_STARTUP_LOAD_CARD = 2,
    DC_STARTUP_RELEASE_CARD = 3,
    DC_STARTUP_ENTER_NEXT = 4
};
typedef struct dc_startup_action { uint32_t kind, value; } dc_startup_action;
typedef struct dc_startup_plan {
    dc_startup_state next;
    uint32_t count;
    dc_startup_action actions[3];
} dc_startup_plan;

/* Initial host action order only; other 0x00511f20 setup is outside this API. */
DC_API dc_status dc_startup_begin_plan(dc_startup_plan *out);
/* Interpret the completed external transition before adding delta. Original
 * unsigned 32-bit elapsed arithmetic wraps explicitly, including negative delta
 * bit patterns. The original comparisons use unsigned carry branches. Commit next only after
 * executing actions in order; a failed host action requires full recovery.
 * An advanced state is a no-op because the original replaces its callback.
 * Invalid arguments leave out unchanged. */
DC_API dc_status dc_startup_build_plan(const dc_startup_state *state,
    const dc_startup_input *input, dc_startup_plan *out);
#ifdef __cplusplus
}
#endif
#endif
