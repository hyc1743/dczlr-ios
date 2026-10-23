#include "dc_startup.h"
#include <string.h>

static void action(dc_startup_plan *p, uint32_t kind, uint32_t value) {
    p->actions[p->count++] = (dc_startup_action){kind, value};
}

dc_status dc_startup_begin_plan(dc_startup_plan *out) {
    if (!out) return DC_ARGUMENT;
    dc_startup_plan p = {0};
    p.next.waiting = 1;
    action(&p, DC_STARTUP_REQUEST_TRANSITION, 3);
    action(&p, DC_STARTUP_LOAD_CARD, 0);
    action(&p, DC_STARTUP_REQUEST_TRANSITION, 4);
    *out = p;
    return DC_OK;
}

dc_status dc_startup_build_plan(const dc_startup_state *state,
        const dc_startup_input *input, dc_startup_plan *out) {
    if (!state || !input || !out || state->card > 1 || state->waiting > 1 ||
        state->advanced > 1 || input->transition_complete > 1) return DC_ARGUMENT;
    dc_startup_plan p = {0};
    p.next = *state;
    if (!p.next.advanced) {
        if (p.next.waiting && input->transition_complete) {
            if (input->transition_state == 1) p.next.waiting = 0;
            else if (input->transition_state == 3) {
                if (!p.next.card) {
                    action(&p, DC_STARTUP_LOAD_CARD, 1);
                    action(&p, DC_STARTUP_REQUEST_TRANSITION, 4);
                    p.next.card = 1;
                } else {
                    action(&p, DC_STARTUP_RELEASE_CARD, 0);
                    action(&p, DC_STARTUP_ENTER_NEXT, 0);
                    p.next.advanced = 1;
                }
            }
        }
        if (!p.next.waiting) {
            p.next.elapsed += (uint32_t)input->delta;
            uint32_t limit = p.next.card ? 30000 : 2000;
            if (input->skip_code == 3 || p.next.elapsed >= limit) {
                p.next.elapsed = 0;
                p.next.waiting = 1;
                action(&p, DC_STARTUP_REQUEST_TRANSITION, input->skip_code == 3 ? 3 : 2);
            }
        }
    }
    *out = p;
    return DC_OK;
}
