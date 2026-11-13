#include "dc_type7.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

/* Exact .rdata tables from 电车之狼R.exe (0x0066d728..0x0066e7ac). */
static const int32_t k_2p_sex[6][120] = {
    {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, 1, 2, 3, 4, 5,-1, 7, 8, 9,10,11,12,13,14,15,16,17,18,19,20,
     21,22,23,24,25,26,27,28,29,30,31,32,33,34,-1,36,37,38,39,40,41,42,43,44,45,46,47,48,-1,50,
     51,-1,52,53,54,55,56,57,-1,-1,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,-1,-1,
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1},
    {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,81,82,83,84,85,-1,87,88,89,90,91,92,93,94,95,96,-1,-1,-1,-1,
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,97,
     98,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1},
    {-1,102,103,104,105,106,107,108,109,110,111,112,113,114,115,-1,117,118,119,120,121,122,123,124,125,126,127,128,129,130,
     131,132,133,134,135,136,137,138,139,140,141,142,143,144,-1,146,147,148,149,150,151,152,153,154,155,156,157,158,159,-1,
     160,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
     162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,-1,-1,-1,-1,-1,-1,-1,-1},
    {-1, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,-1,16,17,18,19,20,21,22,23,24,25,26,27,28,29,
     30,31,32,33,34,35,36,37,38,39,40,41,42,43,-1,45,46,47,48,49,50,51,52,53,54,55,56,57,58,-1,
     59,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
     61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,-1,-1,-1,-1,-1,-1,-1,-1},
    {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,91,92,93,94,95,-1,97,98,99,100,101,102,103,104,105,106,-1,-1,-1,-1,
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,107,
     108,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,111,112,113,114,115,-1,117,118,119,120,121,122,123,124,125,126,127,128,129,130,
     131,132,133,134,135,136,137,138,139,140,141,142,143,144,-1,146,147,148,149,150,151,152,153,154,155,156,157,158,-1,160,
     161,-1,162,163,164,165,166,167,-1,-1,170,171,172,173,174,175,176,177,178,179,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
     -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
};

static const int32_t k_2p_oral[7][4] = {
    { 1,  2,  3,  4},
    {11, 12, 13, 14},
    {21, 22, 23, 24},
    {32, 33, 34, 35},
    {45, 46, 47, 48},
    {56, 57, 58, 59},
    {66, 67, 68, 69}
};

static const int32_t k_3p_sex[2][40] = {
    {-1, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15,16,17,18,19,
     20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,-1,-1},
    {-1, 1,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,
     72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,-1,-1}
};

static const int32_t k_3p_vibe[2][10] = {
    {90, 91, 92, 93, 94, 95, 96, -1, -1, -1},
    {97, 98, 99,100,101,102,103, -1, -1, -1}
};

static const int32_t k_3p_oral[5][4] = {
    { 1,  2,  3,  4},
    {13, 14, 15, 16},
    {25, 26, 27, 28},
    {37, 38, 39, 40},
    {51, 52, 53, 54}
};

static const int32_t k_4p_sex[3][60] = {
    {-1,-1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15,16,17,18,19,
     20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,
     40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,-1,-1,-1,-1},
    {-1,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,
     77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,
     97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,-1,-1,-1,-1},
    {-1,-1,117,118,119,120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,
     135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,
     155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,-1,-1,-1,-1}
};

static const int32_t k_4p_switch[3][3] = {
    { 56,  57,  -1},
    {114, 113, 115},
    { -1, 172, 171}
};

static const int32_t k_4p_oral[2][4] = {
    {1,  2,  3,  4},
    {9, 10, 11, 12}
};

static int valid_map(uint8_t map_id, uint8_t sub_mode) {
    if (map_id == 3u) return sub_mode <= DC_TYPE7_SUB_2P_ORAL;
    return map_id == 0u || map_id == 1u || map_id == 4u ||
           map_id == 5u || map_id == 7u || map_id == 8u;
}

static const char *map_cam_prefix(uint8_t map_id) {
    switch (map_id) {
        case 0u: return "home";
        case 1u: return "trai";
        case 3u: return "toil";
        case 4u: return "hote";
        case 5u: return "roji";
        case 7u: return "park";
        case 8u: return "mana";
        default: return "home";
    }
}

static const char *type7_bgm_name(uint8_t map_id) {
    /* Exact 0x005201e0 / 0x00520ce8 Type 7 map BGM selector. */
    switch (map_id) {
        case 0u: return "bgm100.wav";
        case 1u: return "bgm102.wav";
        case 3u: return "bgm107.wav";
        case 4u: return "bgm108.wav";
        case 5u: return "bgm103.wav";
        case 6u: return "bgm104.wav";
        case 7u: return "bgm105.wav";
        case 8u: return "bgm106.wav";
        default: return "";
    }
}

static void plan_add_chain(dc_type7_plan *p, uint8_t body, int32_t from_clip, int32_t to_clip) {
    if (!p || from_clip <= 0 || p->chain_count >= DC_TYPE7_MAX_CHAINS) return;
    uint8_t idx = p->chain_count++;
    p->chain_body[idx] = body;
    p->chain_from[idx] = (uint16_t)from_clip;
    p->chain_to[idx] = (int16_t)to_clip;
}

static void plan_add_loop(dc_type7_plan *p, uint8_t body, int32_t clip, int16_t limit) {
    if (!p || clip <= 0 || p->loop_count >= DC_TYPE7_MAX_LOOPS) return;
    uint8_t idx = p->loop_count++;
    p->loop_body[idx] = body;
    p->loop_clip[idx] = (uint16_t)clip;
    p->loop_limit[idx] = limit;
}

static void apply_2p_rig_overrides(uint8_t r, dc_type7_plan *p) {
    if (!p || r >= 6u) return;
    if (r == 1u || r == 4u) {
        plan_add_loop(p, 0u, k_2p_sex[r][10], 0); /* Cowgirl wait loop */
    }
    if (k_2p_sex[r][65] > 0 && k_2p_sex[r][64] > 0) {
        plan_add_chain(p, 0u, k_2p_sex[r][65], k_2p_sex[r][64]);
    }
    if (k_2p_sex[r][28] > 0 && k_2p_sex[r][29] > 0) {
        plan_add_chain(p, 0u, k_2p_sex[r][28], k_2p_sex[r][29]);
    }
    if (k_2p_sex[r][33] > 0 && k_2p_sex[r][34] > 0) {
        plan_add_chain(p, 0u, k_2p_sex[r][33], k_2p_sex[r][34]);
    }
}

static int32_t setup_2p_piston_chains(const dc_type7_state *s, uint8_t r, bool chain_from_10, dc_type7_plan *p) {
    if (r >= 6u) r = 2u;
    apply_2p_rig_overrides(r, p);
    uint32_t base = (s->cummed_piston && k_2p_sex[r][40] > 0) ? 40u : 11u;
    int32_t c0 = k_2p_sex[r][base + 0u];
    int32_t c1 = k_2p_sex[r][base + 1u];
    int32_t c2 = k_2p_sex[r][base + 2u];
    int32_t c3 = k_2p_sex[r][base + 3u];
    if (c0 <= 0) return k_2p_sex[r][10];

    if (s->sub_style == 1u) {
        int32_t sh = k_2p_sex[r][(base == 40u) ? 45u : 16u];
        if (c1 > 0 && sh > 0) {
            plan_add_chain(p, 0u, c0, c1);
            plan_add_chain(p, 0u, c1, sh);
            plan_add_chain(p, 0u, sh, c1);
        }
    } else if (s->sub_style == 2u) {
        uint32_t gb = (base == 40u) ? 48u : 19u;
        int32_t g0 = k_2p_sex[r][gb + 0u];
        int32_t g2 = k_2p_sex[r][gb + 2u];
        int32_t g3 = k_2p_sex[r][gb + 3u];
        int32_t g4 = k_2p_sex[r][gb + 4u];
        if (g0 > 0 && g2 > 0 && g3 > 0 && g4 > 0) {
            plan_add_chain(p, 0u, c0, g0);
            plan_add_chain(p, 0u, g0, g2);
            plan_add_chain(p, 0u, g2, g3);
            plan_add_chain(p, 0u, g3, g4);
            plan_add_chain(p, 0u, g4, g3);
        }
    } else if (c1 > 0 && c2 > 0 && c3 > 0) {
        plan_add_chain(p, 0u, c0, c1);
        plan_add_chain(p, 0u, c1, c2);
        plan_add_chain(p, 0u, c2, c3);
        plan_add_chain(p, 0u, c3, c0);
    }
    if (chain_from_10 && k_2p_sex[r][10] > 0) {
        plan_add_chain(p, 0u, k_2p_sex[r][10], c0);
    }
    return c0;
}

static int32_t setup_3p_piston_chains(uint8_t sl, bool chain_from_10, dc_type7_plan *p) {
    sl &= 1u;
    int32_t c0 = k_3p_sex[sl][11], c1 = k_3p_sex[sl][12], c2 = k_3p_sex[sl][13], c3 = k_3p_sex[sl][14];
    plan_add_chain(p, 0u, c0, c1);
    plan_add_chain(p, 0u, c1, c2);
    plan_add_chain(p, 0u, c2, c3);
    plan_add_chain(p, 0u, c3, c0);
    if (k_3p_sex[sl][24] > 0 && k_3p_sex[sl][25] > 0) {
        plan_add_chain(p, 0u, k_3p_sex[sl][24], k_3p_sex[sl][25]);
    }
    if (chain_from_10 && k_3p_sex[sl][10] > 0) {
        plan_add_chain(p, 0u, k_3p_sex[sl][10], c0);
    }
    return c0;
}

static void setup_4p_piston_chains(uint8_t sl, bool chain_from_10, dc_type7_plan *p) {
    if (sl >= 3u) sl = 1u;
    int32_t mc0 = k_4p_sex[sl][11], mc1 = k_4p_sex[sl][12], mc2 = k_4p_sex[sl][13], mc3 = k_4p_sex[sl][14];
    plan_add_chain(p, 0u, mc0, mc1);
    plan_add_chain(p, 0u, mc1, mc2);
    plan_add_chain(p, 0u, mc2, mc3);
    plan_add_chain(p, 0u, mc3, mc0);
    uint8_t hb = (uint8_t)(1u + sl);
    plan_add_chain(p, hb, 11, 12);
    plan_add_chain(p, hb, 12, 13);
    plan_add_chain(p, hb, 13, 14);
    plan_add_chain(p, hb, 14, 11);
    if (chain_from_10) {
        plan_add_chain(p, 0u, k_4p_sex[sl][10], mc0);
        plan_add_chain(p, hb, 10, 11);
    }
    plan_add_chain(p, 0u, k_4p_sex[sl][28], k_4p_sex[sl][29]);
    plan_add_chain(p, 0u, k_4p_sex[sl][33], k_4p_sex[sl][34]);
    plan_add_chain(p, hb, 28, 29);
    plan_add_chain(p, hb, 33, 34);
}

static void setup_5p_piston_chains(bool cummed, bool chain_from_10, dc_type7_plan *p) {
    int32_t b = cummed ? 39 : 11;
    plan_add_chain(p, 0u, b + 0, b + 1);
    plan_add_chain(p, 0u, b + 1, b + 2);
    plan_add_chain(p, 0u, b + 2, b + 3);
    plan_add_chain(p, 0u, b + 3, b + 0);
    plan_add_chain(p, 0u, 26, 27);
    plan_add_chain(p, 0u, 31, 32);
    if (chain_from_10) plan_add_chain(p, 0u, 10, b);
}

static void setup_3p_oral_loops(int32_t clip, dc_type7_plan *p) {
    if (clip == 1 || clip == 3 || clip == 13 || clip == 15 || clip == 25 ||
        clip == 27 || clip == 37 || clip == 39 || clip == 51 || clip == 53) {
        plan_add_loop(p, 0u, clip, 0);
    }
}

static void setup_4p_oral_loops(int32_t clip, dc_type7_plan *p) {
    if (clip == 1 || clip == 3 || clip == 9 || clip == 11) {
        for (uint8_t b = 0u; b < 4u; ++b) plan_add_loop(p, b, clip, 0);
    }
}

static void recompute_breath_tier(dc_type7_state *s) {
    static const float k_idle_speeds[5] = {1.0f, 1.25f, 1.65f, 2.5f, 5.0f};
    float mx = 0.0f;
    for (uint8_t i = 0u; i < s->heroine_count && i < 3u; ++i) {
        uint8_t h = s->slots[i];
        if (h < 3u && s->arousal[h] > mx) mx = s->arousal[h];
    }
    uint8_t tier = 0u;
    if (mx >= 0.88f) tier = 4u;
    else if (mx >= 0.70f) tier = 3u;
    else if (mx >= 0.45f) tier = 2u;
    else if (mx >= 0.20f) tier = 1u;
    s->breath_tier = tier;
    s->idle_anim_speed = k_idle_speeds[tier];
}

static uint16_t sat10000(uint32_t v) {
    return v > 10000u ? 10000u : (uint16_t)v;
}

static uint16_t rd16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void wr16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xffu);
    p[1] = (uint8_t)((v >> 8) & 0xffu);
}

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void bump_arousal(dc_type7_state *s, uint8_t h, float delta) {
    if (h >= 3u) return;
    float v = s->arousal[h] + delta;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    s->arousal[h] = v;
}

static void clear_plan(dc_type7_plan *p, uint8_t body_count) {
    memset(p, 0, sizeof(*p));
    p->body_count = body_count;
    for (unsigned i = 0; i < DC_TYPE7_MAX_BODIES; ++i) {
        p->body_clip[i] = -1;
        p->body_next_clip[i] = -1;
    }
}

static void add_item(dc_type7_menu *m, const char *stem, uint8_t pos,
    uint8_t selected, uint8_t action_id, uint8_t aux) {
    if (m->count >= DC_TYPE7_MAX_MENU_ITEMS) return;
    dc_type7_menu_item *it = &m->items[m->count++];
    memset(it, 0, sizeof(*it));
    snprintf(it->stem, sizeof(it->stem), "%s", stem);
    it->radial_pos = pos;
    it->selected = selected;
    it->action_id = action_id;
    it->aux = aux;
}

char dc_type7_heroine_prefix(uint8_t heroine) {
    static const char prefixes[3] = {'b', 'c', 'a'};
    return heroine < 3u ? prefixes[heroine] : 'b';
}

int32_t dc_type7_clip_2p_sex(uint32_t row, uint32_t idx) {
    return (row < 6u && idx < 120u) ? k_2p_sex[row][idx] : -1;
}

int32_t dc_type7_clip_2p_oral(uint32_t pos, uint32_t step) {
    return (pos < 7u && step < 4u) ? k_2p_oral[pos][step] : -1;
}

int32_t dc_type7_clip_3p_sex(uint32_t slot, uint32_t idx) {
    return (slot < 2u && idx < 40u) ? k_3p_sex[slot][idx] : -1;
}

int32_t dc_type7_clip_3p_vibe(uint32_t slot, uint32_t idx) {
    return (slot < 2u && idx < 10u) ? k_3p_vibe[slot][idx] : -1;
}

int32_t dc_type7_clip_3p_oral(uint32_t pos, uint32_t step) {
    return (pos < 5u && step < 4u) ? k_3p_oral[pos][step] : -1;
}

int32_t dc_type7_clip_4p_sex(uint32_t slot, uint32_t idx) {
    return (slot < 3u && idx < 60u) ? k_4p_sex[slot][idx] : -1;
}

int32_t dc_type7_clip_4p_switch(uint32_t from_slot, uint32_t to_slot) {
    return (from_slot < 3u && to_slot < 3u) ? k_4p_switch[from_slot][to_slot] : -1;
}

int32_t dc_type7_clip_4p_oral(uint32_t pos, uint32_t step) {
    return (pos < 2u && step < 4u) ? k_4p_oral[pos][step] : -1;
}

static void fill_4p_heroine_clips(const dc_type7_state *s, int32_t active_clip, dc_type7_plan *plan) {
    /* Body indices: [0]=em00_01 male, [1]=slot0 Aoi, [2]=slot1 Yuuko, [3]=slot2 Manaka. */
    for (uint8_t sl = 0; sl < 3u; ++sl) {
        if ((int8_t)sl == s->active_slot) {
            plan->body_clip[1u + sl] = active_clip;
        } else if (s->vibe_mask & (1u << sl)) {
            plan->body_clip[1u + sl] = (s->phase == DC_TYPE7_PHASE_SLOW ||
                s->phase == DC_TYPE7_PHASE_FAST || s->phase == DC_TYPE7_PHASE_EDGE) ? 62 : 60;
        } else {
            plan->body_clip[1u + sl] = 58;
        }
    }
}

static void record_posture(dc_type7_state *s, uint8_t h) {
    if (h >= 3u) return;
    if (s->rig_mode == 2u || s->rig_mode == 0u) s->metrics[h].posture_a_used = 1u;
    else if (s->rig_mode == 3u || s->rig_mode == 5u) s->metrics[h].posture_b_used = 1u;
}

dc_status dc_type7_init(dc_type7_state *state, uint8_t initial_sub_mode,
    uint8_t map_id, uint8_t slot0, uint8_t slot1, uint8_t slot2,
    uint8_t conquered_mask, dc_type7_plan *initial_plan) {
    if (!state) return DC_ARGUMENT;
    if (initial_sub_mode > DC_TYPE7_SUB_5P) return DC_RANGE;
    if (!valid_map(map_id, initial_sub_mode)) return DC_RANGE;
    if (slot0 >= 3u) return DC_RANGE;

    memset(state, 0, sizeof(*state));
    state->sub_mode = initial_sub_mode;
    state->initial_sub_mode = (initial_sub_mode == DC_TYPE7_SUB_2P_ORAL) ? DC_TYPE7_SUB_2P_SEX
        : (initial_sub_mode == DC_TYPE7_SUB_3P_ORAL) ? DC_TYPE7_SUB_3P_SEX
        : (initial_sub_mode == DC_TYPE7_SUB_4P_ORAL) ? DC_TYPE7_SUB_4P_SEX
        : initial_sub_mode;
    state->map_id = map_id;
    state->conquered_mask = (uint8_t)(conquered_mask & 7u);
    state->idle_anim_speed = 1.0f;
    state->speed = 1.0f;

    if (initial_sub_mode == DC_TYPE7_SUB_2P_SEX || initial_sub_mode == DC_TYPE7_SUB_2P_ORAL) {
        state->heroine_count = 1u;
        state->slots[0] = slot0;
        state->slots[1] = slot0;
        state->slots[2] = slot0;
        state->primary_heroine = slot0;
        state->active_slot = 0;
        state->rig_mode = (initial_sub_mode == DC_TYPE7_SUB_2P_ORAL) ? 6u
            : ((map_id == 4u || map_id == 8u) ? 2u : 3u);
    } else if (initial_sub_mode == DC_TYPE7_SUB_5P) {
        state->heroine_count = 1u;
        state->slots[0] = slot0;
        state->slots[1] = slot0;
        state->slots[2] = slot0;
        state->primary_heroine = slot0;
        state->active_slot = 0;
        state->rig_mode = 3u;
    } else if (initial_sub_mode == DC_TYPE7_SUB_3P_SEX || initial_sub_mode == DC_TYPE7_SUB_3P_ORAL) {
        if (slot1 >= 3u || slot1 == slot0) return DC_RANGE;
        /* 0x004e6f10 cyclic normalization -> (0,1), (1,2), or (2,0). */
        uint8_t a = slot0, b = slot1;
        if (a == 0u && b == 2u) { a = 2u; b = 0u; }
        else if (a == 1u && b == 0u) { a = 0u; b = 1u; }
        else if (a == 2u && b == 1u) { a = 1u; b = 2u; }
        state->heroine_count = 2u;
        state->slots[0] = a;
        state->slots[1] = b;
        state->slots[2] = a;
        state->primary_heroine = a;
        state->active_slot = -1;
        state->rig_mode = (map_id == 4u || map_id == 8u) ? 2u : 3u;
    } else {
        (void)slot1;
        (void)slot2;
        /* 0x004f11e0 canonical 4P slots: [0]=Aoi(2), [1]=Yuuko(0, active), [2]=Manaka(1). */
        state->heroine_count = 3u;
        state->slots[0] = 2u;
        state->slots[1] = 0u;
        state->slots[2] = 1u;
        state->primary_heroine = 0u;
        state->active_slot = 1;
        state->rig_mode = (map_id == 4u || map_id == 8u) ? 2u : 3u;
        for (uint8_t h = 0; h < 3u; ++h) {
            for (uint8_t c = 0; c < 5u; ++c) state->fuku_state[h][c] = 2u;
        }
    }

    if (initial_sub_mode == DC_TYPE7_SUB_3P_SEX || initial_sub_mode == DC_TYPE7_SUB_3P_ORAL) {
        for (uint8_t i = 0; i < 2u; ++i) {
            uint8_t h = state->slots[i];
            state->fuku_state[h][0] = 2u;
            state->fuku_state[h][2] = 2u;
        }
    }
    if (initial_sub_mode == DC_TYPE7_SUB_2P_ORAL ||
        initial_sub_mode == DC_TYPE7_SUB_3P_ORAL ||
        initial_sub_mode == DC_TYPE7_SUB_4P_ORAL) {
        state->phase = DC_TYPE7_PHASE_SLOW;
    }
    state->cam_target_heroine = state->primary_heroine;

    if (initial_plan) {
        uint8_t bc = (initial_sub_mode == DC_TYPE7_SUB_4P_SEX ||
                      initial_sub_mode == DC_TYPE7_SUB_4P_ORAL) ? 4u : 1u;
        clear_plan(initial_plan, bc);
        initial_plan->reset_cam_preset = 1u;
        if (initial_sub_mode == DC_TYPE7_SUB_2P_SEX) {
            apply_2p_rig_overrides(state->rig_mode, initial_plan);
            initial_plan->body_clip[0] = k_2p_sex[state->rig_mode][1];
        } else if (initial_sub_mode == DC_TYPE7_SUB_2P_ORAL) {
            initial_plan->body_clip[0] = k_2p_oral[0][0];
        } else if (initial_sub_mode == DC_TYPE7_SUB_3P_SEX) {
            initial_plan->body_clip[0] = 1;
        } else if (initial_sub_mode == DC_TYPE7_SUB_3P_ORAL) {
            setup_3p_oral_loops(k_3p_oral[0][0], initial_plan);
            initial_plan->body_clip[0] = k_3p_oral[0][0];
        } else if (initial_sub_mode == DC_TYPE7_SUB_4P_SEX) {
            initial_plan->body_clip[0] = k_4p_sex[1][1]; /* 58 */
            fill_4p_heroine_clips(state, 1, initial_plan);
        } else if (initial_sub_mode == DC_TYPE7_SUB_4P_ORAL) {
            setup_4p_oral_loops(k_4p_oral[0][0], initial_plan);
            for (uint8_t b = 0; b < 4u; ++b) initial_plan->body_clip[b] = k_4p_oral[0][0];
        } else {
            initial_plan->body_clip[0] = 1;
        }
        dc_type7_voice_stem(state, &initial_plan->voice_heroine, initial_plan->voice_stem);
    }
    return DC_OK;
}

dc_status dc_type7_resolve_assets(const dc_type7_state *state, dc_type7_assets *out) {
    if (!state || !out) return DC_ARGUMENT;
    if (state->sub_mode > DC_TYPE7_SUB_5P || !valid_map(state->map_id, state->sub_mode)) return DC_RANGE;

    memset(out, 0, sizeof(*out));
    const char *cam_pfx = map_cam_prefix(state->map_id);
    snprintf(out->bgm_name, sizeof(out->bgm_name), "%s", type7_bgm_name(state->map_id));
    char c0 = dc_type7_heroine_prefix(state->slots[0]);
    bool indoor = (state->map_id == 4u || state->map_id == 8u);

    switch (state->sub_mode) {
        case DC_TYPE7_SUB_2P_SEX:
        case DC_TYPE7_SUB_2P_ORAL: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_05.pp");
            out->body_count = 1u;
            unsigned mesh_no = indoor ? 3u : 2u;
            unsigned xa_no = (state->sub_mode == DC_TYPE7_SUB_2P_ORAL) ? 7u
                : ((state->rig_mode == 0u || state->rig_mode == 2u) ? 5u : 6u);
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "%cm00_%02u.xx", c0, mesh_no);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "%cm00_%02u.plst", c0, mesh_no);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "%cn00_%02u.xa", c0, xa_no);
            out->head_count = 1u;
            out->head_heroine[0] = state->slots[0];
            out->head_body_index[0] = 0u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_02.xl", (unsigned)state->map_id);
            if (state->sub_mode == DC_TYPE7_SUB_2P_ORAL) {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_2f.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_isu_%c", c0);
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_isu_a");
            } else if (xa_no == 5u) {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_2t.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_2f_%c", c0);
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_2f_a");
            } else {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_2b.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_2b_%c", c0);
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_2b_a");
            }
            break;
        }
        case DC_TYPE7_SUB_3P_SEX:
        case DC_TYPE7_SUB_3P_ORAL: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_06.pp");
            out->body_count = 1u;
            unsigned pair_base = 5u; /* (0,1) -> dm00_05/06 + dn00_05/06 */
            if (state->slots[0] == 1u && state->slots[1] == 2u) pair_base = 1u;
            else if (state->slots[0] == 2u && state->slots[1] == 0u) pair_base = 3u;
            unsigned dm_no = pair_base + (indoor ? 1u : 0u);
            unsigned dn_no = pair_base + (state->sub_mode == DC_TYPE7_SUB_3P_ORAL ? 1u : 0u);
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "dm00_%02u.xx", dm_no);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "dm00_%02u.plst", dm_no);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "dn00_%02u.xa", dn_no);
            out->head_count = 2u;
            out->head_heroine[0] = state->slots[0];
            out->head_heroine[1] = state->slots[1];
            out->head_body_index[0] = 0u;
            out->head_body_index[1] = 0u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_03.xl", (unsigned)state->map_id);
            if (state->sub_mode == DC_TYPE7_SUB_3P_ORAL) {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_3f.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_w_%c", c0);
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_w_a");
            } else {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_3p.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_3_%c", c0);
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_3_a");
            }
            break;
        }
        case DC_TYPE7_SUB_4P_SEX:
        case DC_TYPE7_SUB_4P_ORAL: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_06.pp");
            out->body_count = 4u;
            bool oral = (state->sub_mode == DC_TYPE7_SUB_4P_ORAL);
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "em00_01.xx");
            out->body_plst[0][0] = '\0';
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "en00_%02u.xa", oral ? 8u : 4u);

            snprintf(out->body_xx[1], sizeof(out->body_xx[1]), "am00_05.xx");
            snprintf(out->body_plst[1], sizeof(out->body_plst[1]), "am00_05.plst");
            snprintf(out->body_xa[1], sizeof(out->body_xa[1]), "en00_%02u.xa", oral ? 5u : 1u);

            snprintf(out->body_xx[2], sizeof(out->body_xx[2]), "bm00_05.xx");
            snprintf(out->body_plst[2], sizeof(out->body_plst[2]), "bm00_05.plst");
            snprintf(out->body_xa[2], sizeof(out->body_xa[2]), "en00_%02u.xa", oral ? 7u : 3u);

            snprintf(out->body_xx[3], sizeof(out->body_xx[3]), "cm00_05.xx");
            snprintf(out->body_plst[3], sizeof(out->body_plst[3]), "cm00_05.plst");
            snprintf(out->body_xa[3], sizeof(out->body_xa[3]), "en00_%02u.xa", oral ? 6u : 2u);

            out->head_count = 3u;
            out->head_heroine[0] = 2u; out->head_body_index[0] = 1u;
            out->head_heroine[1] = 0u; out->head_body_index[1] = 2u;
            out->head_heroine[2] = 1u; out->head_body_index[2] = 3u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_04.xl", (unsigned)state->map_id);
            if (oral) {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_4f.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_t_b");
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_t_a");
            } else {
                snprintf(out->cam_file, sizeof(out->cam_file), "%s_4p.cam", cam_pfx);
                snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_4_b");
                snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_4_a");
            }
            break;
        }
        case DC_TYPE7_SUB_5P: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_06.pp");
            out->body_count = 1u;
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "%cm00_04.xx", c0);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "%cm00_04.plst", c0);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "%cn00_08.xa", c0);
            out->head_count = 1u;
            out->head_heroine[0] = state->slots[0];
            out->head_body_index[0] = 0u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_05.xl", (unsigned)state->map_id);
            snprintf(out->cam_file, sizeof(out->cam_file), "%s_5p.cam", cam_pfx);
            snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_5_%c", c0);
            snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_5_a");
            break;
        }
    }

    for (uint8_t i = 0; i < out->head_count; ++i) {
        char hc = dc_type7_heroine_prefix(out->head_heroine[i]);
        snprintf(out->head_xx[i], sizeof(out->head_xx[i]), "%ck00_00.xx", hc);
        snprintf(out->head_xa[i], sizeof(out->head_xa[i]), "%cn00_01.xa", hc);
        snprintf(out->head_eyes[i], sizeof(out->head_eyes[i]), "%ck00_00.eyes", hc);
        snprintf(out->head_neck[i], sizeof(out->head_neck[i]), "%cm00_01.neck", hc);
    }
    return DC_OK;
}

dc_status dc_type7_observe_clip(dc_type7_state *state, uint32_t body0_clip) {
    if (!state) return DC_ARGUMENT;
    int32_t c = (int32_t)body0_clip;
    switch (state->sub_mode) {
        case DC_TYPE7_SUB_2P_SEX: {
            uint8_t r = state->rig_mode < 6u ? state->rig_mode : 2u;
            if (c == k_2p_sex[r][1]) state->phase = DC_TYPE7_PHASE_IDLE;
            else if (c == k_2p_sex[r][10] ||
                     (k_2p_sex[r][11] > 0 && c >= k_2p_sex[r][11] && c <= k_2p_sex[r][23]) ||
                     (k_2p_sex[r][40] > 0 && c >= k_2p_sex[r][40] && c <= k_2p_sex[r][52])) {
                state->phase = DC_TYPE7_PHASE_SLOW;
            }
            else if (c == k_2p_sex[r][26]) state->phase = DC_TYPE7_PHASE_FAST;
            else if (c == k_2p_sex[r][39]) state->phase = DC_TYPE7_PHASE_EDGE;
            else if (c == k_2p_sex[r][55]) state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            else if (c == k_2p_sex[r][92] || c == k_2p_sex[r][99]) state->phase = DC_TYPE7_PHASE_PAUSE_HOLD;
            break;
        }
        case DC_TYPE7_SUB_2P_ORAL: {
            for (unsigned p = 0; p < 7u; ++p) {
                if (c == k_2p_oral[p][0]) { state->oral_pos = (uint8_t)p; state->oral_fast = 0u; state->phase = DC_TYPE7_PHASE_SLOW; }
                else if (c == k_2p_oral[p][2]) { state->oral_pos = (uint8_t)p; state->oral_fast = 1u; state->phase = DC_TYPE7_PHASE_FAST; }
            }
            if (c == 80) state->phase = DC_TYPE7_PHASE_PAUSE_HOLD;
            else if (c == 100 || c == 107) state->phase = DC_TYPE7_PHASE_EDGE;
            else if (c == 111) {
                if (state->phase != DC_TYPE7_PHASE_MOUTH_HOLD) state->hold_timer_ms = 0u;
                state->phase = DC_TYPE7_PHASE_MOUTH_HOLD;
            }
            else if (c == 134 || c == 136) {
                state->oral_afterglow_irrumatio = (c == 136) ? 1u : 0u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            }
            break;
        }
        case DC_TYPE7_SUB_3P_SEX: {
            if (c == 1) { state->phase = DC_TYPE7_PHASE_IDLE; state->active_slot = -1; }
            else if ((c >= 10 && c <= 22) || (c >= 41 && c <= 53) || c == 92) { state->phase = DC_TYPE7_PHASE_SLOW; state->active_slot = 0; }
            else if ((c >= 62 && c <= 74) || c == 99) { state->phase = DC_TYPE7_PHASE_SLOW; state->active_slot = 1; }
            else if (c == 25 || c == 94) { state->phase = DC_TYPE7_PHASE_FAST; state->active_slot = 0; }
            else if (c == 77 || c == 101) { state->phase = DC_TYPE7_PHASE_FAST; state->active_slot = 1; }
            else if (c == 38) state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            break;
        }
        case DC_TYPE7_SUB_3P_ORAL: {
            for (unsigned p = 0; p < 5u; ++p) {
                if (c == k_3p_oral[p][0]) { state->oral_pos = (uint8_t)p; state->oral_fast = 0u; state->phase = DC_TYPE7_PHASE_SLOW; }
                else if (c == k_3p_oral[p][2]) { state->oral_pos = (uint8_t)p; state->oral_fast = 1u; state->phase = DC_TYPE7_PHASE_FAST; }
            }
            if (c == 67) state->phase = DC_TYPE7_PHASE_EDGE;
            else if (c == 74 || c == 78) state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            break;
        }
        case DC_TYPE7_SUB_4P_SEX: {
            uint8_t sl = (state->active_slot >= 0 && state->active_slot < 3) ? (uint8_t)state->active_slot : 1u;
            if (c == 58 && state->phase == DC_TYPE7_PHASE_IDLE) state->phase = DC_TYPE7_PHASE_IDLE;
            else if (c == k_4p_sex[sl][10] ||
                     (c >= k_4p_sex[sl][11] && c <= k_4p_sex[sl][22]) ||
                     (c >= k_4p_sex[sl][39] && c <= k_4p_sex[sl][50])) {
                state->phase = DC_TYPE7_PHASE_SLOW;
            }
            else if (c == k_4p_sex[sl][25]) state->phase = DC_TYPE7_PHASE_FAST;
            else if (c == k_4p_sex[sl][38]) state->phase = DC_TYPE7_PHASE_SECOND_HOLD;
            else if (c == k_4p_sex[sl][53]) state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            break;
        }
        case DC_TYPE7_SUB_4P_ORAL: {
            for (unsigned p = 0; p < 2u; ++p) {
                if (c == k_4p_oral[p][0]) { state->oral_pos = (uint8_t)p; state->oral_fast = 0u; state->phase = DC_TYPE7_PHASE_SLOW; }
                else if (c == k_4p_oral[p][2]) { state->oral_pos = (uint8_t)p; state->oral_fast = 1u; state->phase = DC_TYPE7_PHASE_FAST; }
            }
            if (c == 18) state->phase = DC_TYPE7_PHASE_EDGE;
            else if (c == 28 || c == 30) state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            break;
        }
        case DC_TYPE7_SUB_5P: {
            if (c == 1) state->phase = DC_TYPE7_PHASE_IDLE;
            else if ((c >= 10 && c <= 22) || (c >= 39 && c <= 50)) state->phase = DC_TYPE7_PHASE_SLOW;
            else if (c == 25) state->phase = DC_TYPE7_PHASE_FAST;
            else if (c == 38) state->phase = DC_TYPE7_PHASE_SECOND_HOLD;
            else if (c == 53) state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            break;
        }
    }
    recompute_breath_tier(state);
    return DC_OK;
}

dc_status dc_type7_tick(dc_type7_state *state, uint32_t dt_ms,
    uint32_t body0_clip, float clip_progress, dc_type7_plan *out_events) {
    if (!state) return DC_ARGUMENT;
    uint8_t bc = (state->sub_mode == DC_TYPE7_SUB_4P_SEX || state->sub_mode == DC_TYPE7_SUB_4P_ORAL) ? 4u : 1u;
    if (out_events) clear_plan(out_events, bc);
    if (dt_ms > 250u) dt_ms = 250u;

    dc_type7_observe_clip(state, body0_clip);
    float dt_sec = (float)dt_ms * 0.001f;
    float spd = state->speed > 0.1f ? state->speed : 1.0f;

    float ar_delta = -0.008f * dt_sec;
    if (state->phase == DC_TYPE7_PHASE_SLOW) ar_delta = 0.018f * dt_sec * spd;
    else if (state->phase == DC_TYPE7_PHASE_FAST) ar_delta = 0.042f * dt_sec * spd;
    else if (state->phase == DC_TYPE7_PHASE_EDGE) ar_delta = 0.055f * dt_sec;
    else if (state->phase == DC_TYPE7_PHASE_MOUTH_HOLD) ar_delta = 0.0f;

    for (uint8_t i = 0u; i < state->heroine_count && i < 3u; ++i) {
        uint8_t h = state->slots[i];
        if (state->heroine_count > 1u && state->active_slot >= 0 &&
            (int8_t)i != state->active_slot && (state->vibe_mask & (1u << i)) == 0u &&
            state->sub_mode != DC_TYPE7_SUB_3P_ORAL && state->sub_mode != DC_TYPE7_SUB_4P_ORAL) {
            bump_arousal(state, h, -0.005f * dt_sec);
        } else {
            bump_arousal(state, h, ar_delta);
        }
    }
    recompute_breath_tier(state);

    /* 0x004e5dc0: 2P Oral Mouth-Hold (clip 111) 10,000 ms auto-timeout -> Swallow (conquered) or Spit. */
    if (state->sub_mode == DC_TYPE7_SUB_2P_ORAL &&
        state->phase == DC_TYPE7_PHASE_MOUTH_HOLD && body0_clip == 111u) {
        state->hold_timer_ms += dt_ms;
        if (state->hold_timer_ms >= 10000u) {
            state->hold_timer_ms = 0u;
            uint8_t h = state->slots[0];
            bool conq = (state->conquered_mask & (1u << h)) != 0u;
            if (conq) state->metrics[h].swallowed = 2u;
            else if (state->metrics[h].swallowed == 0u) state->metrics[h].swallowed = 1u;
            state->arousal[h] = 0.0f;
            state->phase = DC_TYPE7_PHASE_AFTERGLOW;
            recompute_breath_tier(state);
            if (out_events) {
                out_events->body_clip[0] = conq ? 112 : 114;
                dc_type7_voice_stem(state, &out_events->voice_heroine, out_events->voice_stem);
                snprintf(out_events->se_name, sizeof(out_events->se_name), "se330.wav");
            }
            return DC_OK;
        }
    } else {
        state->hold_timer_ms = 0u;
    }

    if (!out_events) return DC_OK;

    /* Synchronized piston / grind / oral stroke SEs (se300..332, se200 in RPP_14.pp). */
    bool active_motion = (state->phase == DC_TYPE7_PHASE_SLOW ||
                          state->phase == DC_TYPE7_PHASE_FAST ||
                          state->phase == DC_TYPE7_PHASE_EDGE);
    if (body0_clip != state->se_cycle_clip || clip_progress < 0.25f) {
        state->se_cycle_clip = body0_clip;
        state->se_fired_in_stroke = 0u;
    }
    if (active_motion && !state->se_fired_in_stroke && clip_progress >= 0.48f) {
        state->se_fired_in_stroke = 1u;
        unsigned v = (unsigned)(state->voice_serial + body0_clip) % 3u;
        bool is_oral = (state->sub_mode == DC_TYPE7_SUB_2P_ORAL ||
                        state->sub_mode == DC_TYPE7_SUB_3P_ORAL ||
                        state->sub_mode == DC_TYPE7_SUB_4P_ORAL);
        if (state->vibe_mask && (v == 2u)) {
            snprintf(out_events->se_name, sizeof(out_events->se_name), "se200.wav");
        } else if (is_oral || state->sub_style == 2u) {
            snprintf(out_events->se_name, sizeof(out_events->se_name), "se32%u.wav", v);
        } else if (state->phase == DC_TYPE7_PHASE_FAST || state->phase == DC_TYPE7_PHASE_EDGE) {
            snprintf(out_events->se_name, sizeof(out_events->se_name), "se31%u.wav", v);
        } else {
            snprintf(out_events->se_name, sizeof(out_events->se_name), "se30%u.wav", v);
        }
    }

    /* Contextual moan cadence scaled by breath_tier. */
    if (active_motion) {
        state->moan_timer_ms += dt_ms;
        uint32_t period_ms = 5600u - (uint32_t)state->breath_tier * 550u;
        if (state->moan_timer_ms >= period_ms) {
            state->moan_timer_ms = 0u;
            dc_type7_voice_stem(state, &out_events->voice_heroine, out_events->voice_stem);
        }
    } else {
        state->moan_timer_ms = 0u;
    }
    return DC_OK;
}

dc_status dc_type7_adjust_speed(dc_type7_state *state, float delta) {
    if (!state) return DC_ARGUMENT;
    float s = state->speed + delta;
    if (s < 0.5f) s = 0.5f;
    if (s > 3.0f) s = 3.0f;
    state->speed = s;
    return DC_OK;
}

enum {
    ACT_INSERT_VAG = 1,
    ACT_INSERT_ANAL = 2,
    ACT_SPEED_UP = 3,
    ACT_SPEED_DOWN = 4,
    ACT_PAUSE_HOLD = 5,
    ACT_RESUME_HOLD = 6,
    ACT_EDGE = 7,
    ACT_FINISH_IN = 8,
    ACT_FINISH_OUT = 9,
    ACT_FINISH_BOTH = 10,
    ACT_SWALLOW = 11,
    ACT_SPIT = 12,
    ACT_CONTINUE = 13,
    ACT_RESTART = 14,
    ACT_SWITCH_HOLE = 15,
    ACT_SWITCH_POSTURE = 16,
    ACT_SWITCH_SUBMODE = 17,
    ACT_ORAL_POS = 18,
    ACT_TARGET_SLOT_VAG = 19,
    ACT_TARGET_SLOT_ANAL = 20,
    ACT_TOGGLE_VIBE = 21,
    ACT_SECOND_WAVE = 22,
    ACT_FINAL_FINISH = 23,
    ACT_RESUME_STYLE = 24,
    ACT_EXIT_SCENE = 30
};

static const char *acc_stem(uint8_t heroine, uint8_t removed) {
    if (heroine == 0u) return removed ? "M_a021" : "M_a018"; /* Yuuko ponytail vs long */
    if (heroine == 1u) return removed ? "M_a017" : "M_a020"; /* Manaka glasses OFF vs ON */
    return removed ? "M_a016" : "M_a019";                    /* Aoi nekomimi OFF vs ON */
}

dc_status dc_type7_build_menu(const dc_type7_state *state, uint8_t hub, dc_type7_menu *out) {
    if (!state || !out) return DC_ARGUMENT;
    memset(out, 0, sizeof(*out));
    out->hub = hub;
    out->target_heroine = state->primary_heroine;

    if (hub == DC_TYPE7_HUB_SYS) {
        add_item(out, "M_s001", 2u, 0u, 1u, 0u);
        add_item(out, "M_s002", 4u, 0u, 2u, 0u);
        return DC_OK;
    }

    if (hub == DC_TYPE7_HUB_FUKU) {
        if (state->sub_mode == DC_TYPE7_SUB_4P_SEX || state->sub_mode == DC_TYPE7_SUB_4P_ORAL) {
            /* 4P: simultaneous 6th-slot accessory buttons for all 3 heroines (0x005342b0). */
            add_item(out, acc_stem(2u, state->fuku_state[2][5]), 3u, state->fuku_state[2][5], 5u, 2u);
            add_item(out, acc_stem(0u, state->fuku_state[0][5]), 2u, state->fuku_state[0][5], 5u, 0u);
            add_item(out, acc_stem(1u, state->fuku_state[1][5]), 4u, state->fuku_state[1][5], 5u, 1u);
            return DC_OK;
        }
        if (state->sub_mode == DC_TYPE7_SUB_3P_SEX || state->sub_mode == DC_TYPE7_SUB_3P_ORAL) {
            uint8_t cur = state->fuku_slot_cursor & 1u;
            uint8_t h = state->slots[cur];
            out->target_heroine = h;
            out->page = cur;
            static const char *const bra_stems[3] = {"M_a004", "M_a005", "M_a006"};
            static const char *const pan_stems[4] = {"M_a010", "M_a011", "M_a012", "M_a013"};
            static const char *const sck_stems[2] = {"M_a014", "M_a015"};
            if (h != 2u) {
                add_item(out, bra_stems[state->fuku_state[h][1] % 3u], 1u, state->fuku_state[h][1] > 0u, 1u, h);
            }
            add_item(out, pan_stems[state->fuku_state[h][3] % 4u], 3u, state->fuku_state[h][3] > 0u, 3u, h);
            add_item(out, sck_stems[state->fuku_state[h][4] & 1u], 4u, state->fuku_state[h][4] > 0u, 4u, h);
            add_item(out, acc_stem(h, state->fuku_state[h][5]), 6u, state->fuku_state[h][5] > 0u, 5u, h);
            return DC_OK;
        }
        /* 2P / 5P: full clothing set for single heroine (bra omitted for Aoi h==2). */
        uint8_t h = state->slots[0];
        out->target_heroine = h;
        static const char *const top_stems[3] = {"M_a001", "M_a002", "M_a003"};
        static const char *const bra_stems[3] = {"M_a004", "M_a005", "M_a006"};
        static const char *const skt_stems[3] = {"M_a007", "M_a008", "M_a009"};
        static const char *const pan_stems[4] = {"M_a010", "M_a011", "M_a012", "M_a013"};
        static const char *const sck_stems[2] = {"M_a014", "M_a015"};
        add_item(out, top_stems[state->fuku_state[h][0] % 3u], 0u, state->fuku_state[h][0] > 0u, 0u, h);
        if (h != 2u) {
            add_item(out, bra_stems[state->fuku_state[h][1] % 3u], 1u, state->fuku_state[h][1] > 0u, 1u, h);
        }
        add_item(out, skt_stems[state->fuku_state[h][2] % 3u], 2u, state->fuku_state[h][2] > 0u, 2u, h);
        add_item(out, pan_stems[state->fuku_state[h][3] % 4u], 3u, state->fuku_state[h][3] > 0u, 3u, h);
        add_item(out, sck_stems[state->fuku_state[h][4] & 1u], 4u, state->fuku_state[h][4] > 0u, 4u, h);
        add_item(out, acc_stem(h, state->fuku_state[h][5]), 5u, state->fuku_state[h][5] > 0u, 5u, h);
        return DC_OK;
    }

    if (hub == DC_TYPE7_HUB_CAM) {
        bool multi = (state->heroine_count > 1u);
        uint8_t cur = multi ? (state->cam_slot_cursor % state->heroine_count) : 0u;
        uint8_t h = state->slots[cur];
        out->target_heroine = h;
        out->page = cur;
        uint8_t gm = state->gaze_mode[h];
        uint8_t pm = state->cam_pivot_mode;
        if (!multi) {
            add_item(out, "M_c001", 0u, gm == 0u, 0u, h);
            add_item(out, "M_c002", 1u, gm == 1u, 1u, h);
            add_item(out, gm == 2u ? "M_c044" : "M_c004", 2u, gm == 2u, 2u, h);
            add_item(out, "M_c008", 3u, pm == 0u, 3u, h);
            add_item(out, "M_c005", 4u, pm == 1u, 4u, h);
            add_item(out, pm == 2u ? "M_c047" : "M_c007", 5u, pm == 2u, 5u, h);
            add_item(out, "M_c009", 6u, 0u, 6u, h);
        } else {
            /* Portrait icons per heroine: Yuuko=3x, Manaka=2x, Aoi=1x (0x005352c0). */
            unsigned tens = (h == 0u) ? 30u : ((h == 1u) ? 20u : 10u);
            char g0[16], g1[16], p0[16], p1[16];
            snprintf(g0, sizeof(g0), "M_c%03u", tens + 1u);
            snprintf(g1, sizeof(g1), "M_c%03u", tens + 2u);
            snprintf(p0, sizeof(p0), "M_c%03u", tens + 8u);
            snprintf(p1, sizeof(p1), "M_c%03u", tens + 5u);
            add_item(out, g0, 0u, gm == 0u, 0u, h);
            add_item(out, g1, 1u, gm == 1u, 1u, h);
            add_item(out, gm == 2u ? "M_c044" : "M_c004", 2u, gm == 2u, 2u, h);
            add_item(out, p0, 3u, pm == 0u && state->cam_target_heroine == h, 3u, h);
            add_item(out, p1, 4u, pm == 1u && state->cam_target_heroine == h, 4u, h);
            add_item(out, pm == 2u ? "M_c047" : "M_c007", 5u, pm == 2u, 5u, h);
            add_item(out, "M_c009", 6u, 0u, 6u, h);
        }
        return DC_OK;
    }

    if (hub != DC_TYPE7_HUB_CHARA) return DC_RANGE;

    /* P_chara per sub_mode (0x0053ade0). */
    switch (state->sub_mode) {
        case DC_TYPE7_SUB_2P_SEX: {
            out->page = state->chara_page;
            if (state->phase == DC_TYPE7_PHASE_IDLE || state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                static const char *const p_vag[3] = {"M_h014", "M_h015", "M_h016"};
                static const char *const p_ana[3] = {"M_h114", "M_h115", "M_h116"};
                static const uint8_t page_rigs[3] = {2u, 3u, 0u};
                uint8_t pg = state->chara_page % 3u;
                add_item(out, "M_h001", 0u, 0u, ACT_INSERT_VAG, state->rig_mode);
                add_item(out, "M_h002", 1u, 0u, ACT_INSERT_ANAL, state->rig_mode);
                add_item(out, p_vag[pg], 2u, state->rig_mode == page_rigs[pg], ACT_SWITCH_POSTURE, page_rigs[pg]);
                add_item(out, p_ana[pg], 3u, 0u, ACT_SWITCH_POSTURE, (uint8_t)(page_rigs[pg] | 0x80u));
                add_item(out, "M_h017", 4u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_2P_ORAL);
                add_item(out, "M_h013", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_SLOW) {
                add_item(out, "M_h003", 0u, 0u, ACT_SPEED_UP, 0u);
                add_item(out, "M_h005", 1u, 0u, ACT_SWITCH_HOLE, state->hole ^ 1u);
                uint8_t alt_rig = (state->rig_mode == 2u) ? 0u : ((state->rig_mode == 0u) ? 2u
                    : ((state->rig_mode == 3u) ? 5u : 3u));
                add_item(out, "M_h007", 2u, 0u, ACT_SWITCH_POSTURE, alt_rig);
                add_item(out, "M_h008", 3u, 0u, ACT_SWITCH_POSTURE, (state->rig_mode == 2u || state->rig_mode == 0u) ? 3u : 2u);
                add_item(out, "M_h018", 4u, 0u, ACT_PAUSE_HOLD, 0u);
                add_item(out, "M_h017", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_2P_ORAL);
                add_item(out, "M_h013", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_PAUSE_HOLD) {
                add_item(out, "M_h003", 0u, 0u, ACT_RESUME_HOLD, 0u);
                add_item(out, "M_h017", 4u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_2P_ORAL);
                add_item(out, "M_h013", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_FAST) {
                bool full = state->arousal[state->slots[0]] >= 0.85f;
                add_item(out, "M_h004", 0u, 0u, ACT_SPEED_DOWN, 0u);
                add_item(out, "M_h006", 1u, 0u, ACT_EDGE, 0u);
                add_item(out, full ? "M_h019" : "M_h009", 2u, 0u, ACT_FINISH_IN, full ? 1u : 0u);
                add_item(out, full ? "M_h020" : "M_h010", 3u, 0u, ACT_FINISH_OUT, full ? 1u : 0u);
                add_item(out, "M_h013", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else { /* EDGE (0x0053b130) */
                bool full = state->arousal[state->slots[0]] >= 0.85f;
                add_item(out, full ? "M_h026" : "M_h011", 0u, 0u, ACT_FINISH_IN, full ? 1u : 0u);
                add_item(out, full ? "M_h027" : "M_h012", 1u, 0u, ACT_FINISH_OUT, full ? 1u : 0u);
                if (!state->edge_resumed) {
                    add_item(out, "M_h019", 2u, 0u, ACT_RESUME_STYLE, 0u); /* Full Piston */
                    add_item(out, "M_h020", 3u, 0u, ACT_RESUME_STYLE, 1u); /* Shallow Piston */
                    add_item(out, "M_h021", 4u, 0u, ACT_RESUME_STYLE, 2u); /* Grind */
                    add_item(out, "M_h022", 5u, 0u, ACT_RESUME_STYLE, 3u); /* Fast Piston */
                }
                add_item(out, "M_h013", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
        case DC_TYPE7_SUB_2P_ORAL: {
            if (state->phase == DC_TYPE7_PHASE_MOUTH_HOLD) {
                add_item(out, "M_f010", 1u, 0u, ACT_SWALLOW, 0u);
                add_item(out, "M_f011", 3u, 0u, ACT_SPIT, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_EDGE) {
                add_item(out, "M_f008", 0u, 0u, ACT_FINISH_IN, 0u);
                add_item(out, "M_f009", 1u, 0u, ACT_FINISH_OUT, 0u);
                if (state->arousal[state->slots[0]] >= 0.80f) {
                    add_item(out, "M_f015", 2u, 0u, ACT_FINISH_BOTH, 1u);
                }
                add_item(out, "M_f012", 4u, 0u, ACT_CONTINUE, 0u);
                add_item(out, "M_f014", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                add_item(out, "M_f013", 0u, 0u, ACT_RESTART, 0u); /* Restart BJ -> 1 */
                add_item(out, "M_f019", 1u, 0u, ACT_RESTART, 1u); /* Restart Irrumatio -> 80 */
                add_item(out, "M_f016", 2u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_2P_SEX);
                add_item(out, "M_f017", 3u, 0u, ACT_SWITCH_SUBMODE, (uint8_t)(DC_TYPE7_SUB_2P_SEX | 0x80u));
                add_item(out, "M_f014", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else {
                static const char *const act_stems[7] = {
                    "M_f001", "M_f002", "M_f003", "M_f004", "M_f005", "M_f006", "M_f007"
                };
                uint8_t next_pos = (uint8_t)((state->oral_pos + 1u) % 7u);
                add_item(out, act_stems[state->oral_pos % 7u], 0u, state->oral_fast, state->oral_fast ? ACT_SPEED_DOWN : ACT_SPEED_UP, state->oral_pos);
                add_item(out, act_stems[next_pos], 1u, 0u, ACT_ORAL_POS, next_pos);
                add_item(out, "M_f007", 2u, state->oral_pos == 6u, ACT_ORAL_POS, 6u);
                add_item(out, "M_f008", 3u, 0u, ACT_EDGE, 0u);
                add_item(out, "M_f018", 4u, state->phase == DC_TYPE7_PHASE_PAUSE_HOLD,
                    state->phase == DC_TYPE7_PHASE_PAUSE_HOLD ? ACT_RESUME_HOLD : ACT_PAUSE_HOLD, 0u);
                add_item(out, "M_f016", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_2P_SEX);
                add_item(out, "M_f014", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
        case DC_TYPE7_SUB_3P_SEX: {
            if (state->phase == DC_TYPE7_PHASE_IDLE || state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                add_item(out, "M_e001", 0u, 0u, ACT_TARGET_SLOT_VAG, 0u);
                add_item(out, "M_e002", 1u, 0u, ACT_TARGET_SLOT_ANAL, 0u);
                add_item(out, "M_e003", 2u, 0u, ACT_TARGET_SLOT_VAG, 1u);
                add_item(out, "M_e004", 3u, 0u, ACT_TARGET_SLOT_ANAL, 1u);
                add_item(out, "M_e018", 4u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_3P_ORAL);
                add_item(out, "M_e020", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_SLOW) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                uint8_t other = sl ^ 1u;
                add_item(out, "M_e007", 0u, 0u, ACT_SPEED_UP, 0u);
                add_item(out, "M_e021", 1u, 0u, ACT_SWITCH_HOLE, state->hole ^ 1u);
                add_item(out, "M_e024", 2u, 0u, ACT_TARGET_SLOT_VAG, other);
                add_item(out, "M_e027", 3u, 0u, ACT_TARGET_SLOT_ANAL, other);
                add_item(out, state->vibe_mask ? "M_e031" : "M_e030", 4u, state->vibe_mask != 0u, ACT_TOGGLE_VIBE, other);
                add_item(out, "M_e018", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_3P_ORAL);
                add_item(out, "M_e020", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else { /* FAST */
                add_item(out, "M_e008", 0u, 0u, ACT_SPEED_DOWN, 0u);
                add_item(out, "M_e010", 1u, 0u, ACT_FINISH_IN, 0u);
                add_item(out, "M_e011", 2u, 0u, ACT_FINISH_OUT, 0u);
                add_item(out, "M_e038", 3u, 0u, ACT_FINISH_BOTH, 1u);
                add_item(out, "M_e020", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
        case DC_TYPE7_SUB_3P_ORAL: {
            if (state->phase == DC_TYPE7_PHASE_EDGE) {
                add_item(out, "M_w006", 0u, 0u, ACT_FINISH_IN, 0u);
                add_item(out, "M_w007", 1u, 0u, ACT_FINISH_OUT, 0u);
                add_item(out, "M_w011", 2u, 0u, ACT_FINISH_BOTH, 1u);
                add_item(out, "M_w008", 4u, 0u, ACT_CONTINUE, 0u);
                add_item(out, "M_w010", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                add_item(out, "M_w014", 0u, 0u, ACT_RESTART, 0u);
                add_item(out, "M_w009", 2u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_3P_SEX);
                add_item(out, "M_w010", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else {
                static const char *const w_stems[5] = {"M_w001", "M_w002", "M_w003", "M_w004", "M_w005"};
                uint8_t next_pos = (uint8_t)((state->oral_pos + 1u) % 5u);
                add_item(out, w_stems[state->oral_pos % 5u], 0u, state->oral_fast, state->oral_fast ? ACT_SPEED_DOWN : ACT_SPEED_UP, state->oral_pos);
                add_item(out, w_stems[next_pos], 1u, 0u, ACT_ORAL_POS, next_pos);
                add_item(out, "M_w006", 3u, 0u, ACT_EDGE, 0u);
                add_item(out, "M_w009", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_3P_SEX);
                add_item(out, "M_w010", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
        case DC_TYPE7_SUB_4P_SEX: {
            if (state->phase == DC_TYPE7_PHASE_IDLE || state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                add_item(out, "M_x001", 0u, 0u, ACT_TARGET_SLOT_VAG, 0u);
                add_item(out, "M_x002", 1u, 0u, ACT_TARGET_SLOT_ANAL, 0u);
                add_item(out, "M_x003", 2u, 0u, ACT_TARGET_SLOT_VAG, 1u);
                add_item(out, "M_x004", 3u, 0u, ACT_TARGET_SLOT_ANAL, 1u);
                add_item(out, "M_x005", 4u, 0u, ACT_TARGET_SLOT_VAG, 2u);
                add_item(out, "M_x019", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_4P_ORAL);
                add_item(out, "M_x011", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_SLOW) {
                uint8_t sl = (state->active_slot >= 0 && state->active_slot < 3) ? (uint8_t)state->active_slot : 1u;
                uint8_t o0 = (uint8_t)((sl + 1u) % 3u);
                uint8_t o1 = (uint8_t)((sl + 2u) % 3u);
                add_item(out, "M_x007", 0u, 0u, ACT_SPEED_UP, 0u);
                add_item(out, "M_x020", 1u, 0u, ACT_SWITCH_HOLE, state->hole ^ 1u);
                add_item(out, "M_x023", 2u, 0u, ACT_TARGET_SLOT_VAG, o0);
                add_item(out, "M_x026", 3u, 0u, ACT_TARGET_SLOT_VAG, o1);
                add_item(out, (state->vibe_mask & (1u << o0)) ? "M_x034" : "M_x033", 4u,
                    (state->vibe_mask & (1u << o0)) != 0u, ACT_TOGGLE_VIBE, o0);
                add_item(out, "M_x019", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_4P_ORAL);
                add_item(out, "M_x011", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_SECOND_HOLD) {
                add_item(out, "M_x015", 0u, 0u, ACT_FINAL_FINISH, 1u);
                add_item(out, "M_x008", 2u, 0u, ACT_CONTINUE, 0u);
                add_item(out, "M_x011", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else { /* FAST */
                add_item(out, "M_x008", 0u, 0u, ACT_SPEED_DOWN, 0u);
                add_item(out, "M_x012", 1u, 0u, ACT_FINISH_IN, 0u);
                add_item(out, "M_x013", 2u, 0u, ACT_FINISH_OUT, 0u);
                add_item(out, "M_x037", 3u, 0u, ACT_SECOND_WAVE, 1u);
                add_item(out, "M_x011", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
        case DC_TYPE7_SUB_4P_ORAL: {
            if (state->phase == DC_TYPE7_PHASE_EDGE) {
                add_item(out, "M_y002", 0u, 0u, ACT_FINISH_IN, 0u);
                add_item(out, "M_y003", 1u, 0u, ACT_FINISH_OUT, 0u);
                add_item(out, "M_y007", 2u, 0u, ACT_FINISH_BOTH, 1u);
                add_item(out, "M_y004", 4u, 0u, ACT_CONTINUE, 0u);
                add_item(out, "M_y006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                add_item(out, "M_y011", 0u, 0u, ACT_RESTART, 0u);
                add_item(out, "M_y005", 2u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_4P_SEX);
                add_item(out, "M_y006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else {
                uint8_t next_pos = state->oral_pos ^ 1u;
                add_item(out, state->oral_pos == 0u ? "M_y001" : "M_y010", 0u, state->oral_fast,
                    state->oral_fast ? ACT_SPEED_DOWN : ACT_SPEED_UP, state->oral_pos);
                add_item(out, next_pos == 0u ? "M_y001" : "M_y010", 1u, 0u, ACT_ORAL_POS, next_pos);
                add_item(out, "M_y002", 3u, 0u, ACT_EDGE, 0u);
                add_item(out, "M_y005", 5u, 0u, ACT_SWITCH_SUBMODE, DC_TYPE7_SUB_4P_SEX);
                add_item(out, "M_y006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
        case DC_TYPE7_SUB_5P: {
            if (state->phase == DC_TYPE7_PHASE_IDLE || state->phase == DC_TYPE7_PHASE_AFTERGLOW) {
                add_item(out, "M_v001", 0u, 0u, state->phase == DC_TYPE7_PHASE_IDLE ? ACT_INSERT_VAG : ACT_RESTART, 0u);
                add_item(out, "M_v006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_SLOW) {
                add_item(out, "M_v001", 0u, 0u, ACT_SPEED_UP, 0u);
                add_item(out, "M_v006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else if (state->phase == DC_TYPE7_PHASE_SECOND_HOLD) {
                add_item(out, "M_v004", 0u, 0u, ACT_FINAL_FINISH, 1u);
                add_item(out, "M_v005", 2u, 0u, ACT_CONTINUE, 0u);
                add_item(out, "M_v006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            } else { /* FAST */
                add_item(out, "M_v002", 0u, 0u, ACT_FINISH_IN, 1u);
                add_item(out, "M_v007", 1u, 0u, ACT_SECOND_WAVE, 1u);
                add_item(out, "M_v003", 2u, 0u, ACT_FINISH_OUT, 0u);
                add_item(out, "M_v005", 4u, 0u, ACT_CONTINUE, 0u);
                add_item(out, "M_v006", 6u, 0u, ACT_EXIT_SCENE, 0u);
            }
            break;
        }
    }
    return DC_OK;
}

dc_status dc_type7_right_click_menu(dc_type7_state *state, uint8_t hub, uint8_t *consumed) {
    if (!state || !consumed) return DC_ARGUMENT;
    *consumed = 0u;
    if (hub == DC_TYPE7_HUB_CHARA && state->sub_mode == DC_TYPE7_SUB_2P_SEX &&
        (state->phase == DC_TYPE7_PHASE_IDLE || state->phase == DC_TYPE7_PHASE_AFTERGLOW)) {
        state->chara_page = (uint8_t)((state->chara_page + 1u) % 3u);
        *consumed = 1u;
    } else if (hub == DC_TYPE7_HUB_FUKU &&
               (state->sub_mode == DC_TYPE7_SUB_3P_SEX || state->sub_mode == DC_TYPE7_SUB_3P_ORAL)) {
        state->fuku_slot_cursor ^= 1u;
        *consumed = 1u;
    } else if (hub == DC_TYPE7_HUB_CAM && state->heroine_count > 1u) {
        state->cam_slot_cursor = (uint8_t)((state->cam_slot_cursor + 1u) % state->heroine_count);
        state->cam_target_heroine = state->slots[state->cam_slot_cursor];
        *consumed = 1u;
    }
    return DC_OK;
}

static uint8_t count_stripped(const uint8_t fuku[6]) {
    uint8_t n = 0u;
    if (fuku[0] > 0u) n += 2u;
    if (fuku[1] > 0u) n += 2u;
    if (fuku[2] > 0u) n += 2u;
    if (fuku[3] > 0u) n += 3u;
    if (fuku[4] > 0u) n += 2u;
    return n;
}

dc_status dc_type7_select_menu_item(dc_type7_state *state, uint8_t hub,
    uint8_t item_index, dc_type7_plan *out) {
    if (!state || !out) return DC_ARGUMENT;
    dc_type7_menu menu;
    dc_status st = dc_type7_build_menu(state, hub, &menu);
    if (st != DC_OK) return st;
    if (item_index >= menu.count) return DC_RANGE;

    const dc_type7_menu_item *it = &menu.items[item_index];
    uint8_t bc = (state->sub_mode == DC_TYPE7_SUB_4P_SEX || state->sub_mode == DC_TYPE7_SUB_4P_ORAL) ? 4u : 1u;
    clear_plan(out, bc);
    snprintf(out->se_name, sizeof(out->se_name), "se101.wav");

    if (hub == DC_TYPE7_HUB_SYS) {
        state->fade_pending = 1u;
        state->fade_kind = (it->action_id == 1u) ? DC_TYPE7_FADE_SAVE : DC_TYPE7_FADE_CONFIG;
        out->start_fade = 1u;
        out->fade_kind = state->fade_kind;
        return DC_OK;
    }

    if (hub == DC_TYPE7_HUB_FUKU) {
        uint8_t h = it->aux < 3u ? it->aux : state->slots[0];
        uint8_t slot = it->action_id;
        if (slot < 3u) state->fuku_state[h][slot] = (uint8_t)((state->fuku_state[h][slot] + 1u) % 3u);
        else if (slot == 3u) state->fuku_state[h][3] = (uint8_t)((state->fuku_state[h][3] + 1u) % 4u);
        else if (slot == 4u) state->fuku_state[h][4] ^= 1u;
        else if (slot == 5u) {
            /* 0x00537377: conquered heroines cycle accessory across 3 states (0/1/2); unconquered toggle 0/1. */
            if ((state->conquered_mask & (1u << h)) != 0u) {
                state->fuku_state[h][5] = (uint8_t)((state->fuku_state[h][5] + 1u) % 3u);
            } else {
                state->fuku_state[h][5] ^= 1u;
            }
        }
        uint8_t sf = count_stripped(state->fuku_state[h]);
        if (sf > state->metrics[h].stripped_flags) state->metrics[h].stripped_flags = sf;
        return DC_OK;
    }

    if (hub == DC_TYPE7_HUB_CAM) {
        uint8_t h = it->aux < 3u ? it->aux : state->slots[0];
        if (it->action_id <= 2u) {
            state->gaze_mode[h] = (state->gaze_mode[h] == it->action_id && it->action_id == 2u) ? 0u : it->action_id;
        } else if (it->action_id == 3u || it->action_id == 4u) {
            state->cam_pivot_mode = (uint8_t)(it->action_id - 3u);
            state->cam_target_heroine = h;
            out->update_cam_pivot = 1u;
        } else if (it->action_id == 5u) {
            state->cam_pivot_mode = (state->cam_pivot_mode == 2u) ? 0u : 2u;
            state->cam_target_heroine = h;
            out->update_cam_pivot = 1u;
        } else {
            state->gaze_mode[h] = 0u;
            state->cam_pivot_mode = 0u;
            state->cam_target_heroine = h;
            out->reset_cam_preset = 1u;
        }
        return DC_OK;
    }

    if (it->action_id == ACT_EXIT_SCENE) {
        state->fade_pending = 1u;
        state->fade_kind = DC_TYPE7_FADE_EXIT;
        out->start_fade = 1u;
        out->fade_kind = DC_TYPE7_FADE_EXIT;
        return DC_OK;
    }

    if (it->action_id == ACT_SWITCH_SUBMODE) {
        uint8_t target_sub = (uint8_t)(it->aux & 0x7fu);
        state->fade_pending = 1u;
        state->fade_kind = DC_TYPE7_FADE_SWAP;
        state->pending_sub_mode = target_sub;
        state->pending_hole = (it->aux & 0x80u) ? 1u : 0u;
        state->pending_rig_mode = (target_sub == DC_TYPE7_SUB_2P_ORAL) ? 6u
            : ((state->map_id == 4u || state->map_id == 8u) ? 2u : 3u);
        state->pending_slot = state->active_slot;
        out->start_fade = 1u;
        out->fade_kind = DC_TYPE7_FADE_SWAP;
        return DC_OK;
    }

    /* Sub-mode specific action dispatch. */
    switch (state->sub_mode) {
        case DC_TYPE7_SUB_2P_SEX: {
            uint8_t h = state->slots[0];
            uint8_t r = state->rig_mode;
            apply_2p_rig_overrides(r, out);
            if (it->action_id == ACT_INSERT_VAG || it->action_id == ACT_INSERT_ANAL) {
                state->hole = (it->action_id == ACT_INSERT_ANAL) ? 1u : 0u;
                state->sub_style = 0u;
                state->cummed_piston = 0u;
                state->edge_resumed = 0u;
                if (state->hole) { state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u); state->metrics[h].anal_used = 1u; }
                record_posture(state, h);
                state->phase = DC_TYPE7_PHASE_SLOW;
                int32_t p0 = setup_2p_piston_chains(state, r, true, out);
                int32_t intro = k_2p_sex[r][state->hole ? 6u : 2u];
                out->body_clip[0] = intro >= 0 ? intro : p0;
                bump_arousal(state, h, 0.15f);
            } else if (it->action_id == ACT_SWITCH_POSTURE) {
                uint8_t target_rig = (uint8_t)(it->aux & 0x7fu);
                uint8_t new_hole = (it->aux & 0x80u) ? 1u : state->hole;
                bool same_xa = ((r == 0u || r == 2u) == (target_rig == 0u || target_rig == 2u));
                if (same_xa && state->phase == DC_TYPE7_PHASE_SLOW) {
                    state->rig_mode = target_rig;
                    state->hole = new_hole;
                    state->sub_style = 0u;
                    record_posture(state, h);
                    out->body_clip[0] = setup_2p_piston_chains(state, target_rig, false, out);
                } else {
                    state->fade_pending = 1u;
                    state->fade_kind = DC_TYPE7_FADE_SWAP;
                    state->pending_sub_mode = DC_TYPE7_SUB_2P_SEX;
                    state->pending_rig_mode = target_rig;
                    state->pending_hole = new_hole;
                    state->pending_slot = 0;
                    out->start_fade = 1u;
                    out->fade_kind = DC_TYPE7_FADE_SWAP;
                    return DC_OK;
                }
            } else if (it->action_id == ACT_SWITCH_HOLE) {
                state->hole = it->aux & 1u;
                state->sub_style = 0u;
                if (state->hole) { state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u); state->metrics[h].anal_used = 1u; }
                out->body_clip[0] = setup_2p_piston_chains(state, r, false, out);
                bump_arousal(state, h, 0.12f);
            } else if (it->action_id == ACT_SPEED_UP) {
                state->phase = DC_TYPE7_PHASE_FAST;
                int32_t br = k_2p_sex[r][24];
                out->body_clip[0] = br >= 0 ? br : k_2p_sex[r][26];
                bump_arousal(state, h, 0.25f);
            } else if (it->action_id == ACT_SPEED_DOWN || it->action_id == ACT_CONTINUE) {
                state->phase = DC_TYPE7_PHASE_SLOW;
                int32_t p0 = setup_2p_piston_chains(state, r, true, out);
                int32_t br = k_2p_sex[r][53];
                out->body_clip[0] = br >= 0 ? br : p0;
            } else if (it->action_id == ACT_RESUME_STYLE) {
                state->edge_resumed = 1u;
                state->cummed_piston = 1u;
                if (it->aux == 3u) {
                    state->phase = DC_TYPE7_PHASE_FAST;
                    int32_t br = k_2p_sex[r][24];
                    out->body_clip[0] = br >= 0 ? br : k_2p_sex[r][26];
                } else {
                    state->sub_style = (uint8_t)(it->aux % 3u);
                    state->phase = DC_TYPE7_PHASE_SLOW;
                    out->body_clip[0] = setup_2p_piston_chains(state, r, false, out);
                }
                bump_arousal(state, h, 0.10f);
            } else if (it->action_id == ACT_PAUSE_HOLD) {
                state->phase = DC_TYPE7_PHASE_PAUSE_HOLD;
                int32_t hc = k_2p_sex[r][state->hole ? 99u : 92u];
                out->body_clip[0] = hc >= 0 ? hc : k_2p_sex[r][10];
            } else if (it->action_id == ACT_RESUME_HOLD) {
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = setup_2p_piston_chains(state, r, false, out);
            } else if (it->action_id == ACT_EDGE) {
                state->phase = DC_TYPE7_PHASE_EDGE;
                int32_t br = k_2p_sex[r][33];
                out->body_clip[0] = br >= 0 ? br : k_2p_sex[r][39];
                bump_arousal(state, h, 0.30f);
            } else if (it->action_id == ACT_FINISH_IN) {
                if (state->hole) state->metrics[h].anal_in_ejac = sat10000(state->metrics[h].anal_in_ejac + 1u);
                else state->metrics[h].vaginal_in_ejac = sat10000(state->metrics[h].vaginal_in_ejac + 1u);
                if (it->aux || state->arousal[h] >= 0.85f) state->metrics[h].heroine_climaxes = sat10000(state->metrics[h].heroine_climaxes + 1u);
                state->arousal[h] = 0.0f;
                state->edge_resumed = 0u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                int32_t cl = k_2p_sex[r][30];
                out->body_clip[0] = cl >= 0 ? cl : k_2p_sex[r][55];
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT) {
                state->metrics[h].out_ejac = sat10000(state->metrics[h].out_ejac + 1u);
                if (it->aux || state->arousal[h] >= 0.85f) state->metrics[h].heroine_climaxes = sat10000(state->metrics[h].heroine_climaxes + 1u);
                state->arousal[h] = 0.0f;
                state->edge_resumed = 0u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                int32_t cl = k_2p_sex[r][54];
                out->body_clip[0] = cl >= 0 ? cl : k_2p_sex[r][55];
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            }
            break;
        }
        case DC_TYPE7_SUB_2P_ORAL: {
            uint8_t h = state->slots[0];
            state->metrics[h].caress_used = 1u;
            if (it->action_id == ACT_ORAL_POS) {
                state->oral_pos = it->aux % 7u;
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = k_2p_oral[state->oral_pos][0];
                bump_arousal(state, h, 0.15f);
            } else if (it->action_id == ACT_SPEED_UP) {
                state->oral_fast = 1u;
                state->phase = DC_TYPE7_PHASE_FAST;
                out->body_clip[0] = k_2p_oral[state->oral_pos][1]; /* chains to [2] */
                bump_arousal(state, h, 0.25f);
            } else if (it->action_id == ACT_SPEED_DOWN) {
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = k_2p_oral[state->oral_pos][3]; /* chains to [0] */
            } else if (it->action_id == ACT_PAUSE_HOLD) {
                state->phase = DC_TYPE7_PHASE_PAUSE_HOLD;
                out->body_clip[0] = 80;
            } else if (it->action_id == ACT_RESUME_HOLD || it->action_id == ACT_CONTINUE) {
                state->phase = DC_TYPE7_PHASE_SLOW;
                state->oral_fast = 0u;
                out->body_clip[0] = k_2p_oral[state->oral_pos][0];
            } else if (it->action_id == ACT_EDGE) {
                state->phase = DC_TYPE7_PHASE_EDGE;
                out->body_clip[0] = 107;
                bump_arousal(state, h, 0.30f);
            } else if (it->action_id == ACT_FINISH_IN) {
                /* Oral in-mouth ejaculation -> 101..103 -> 111 Mouth-Hold Idle! */
                state->metrics[h].oral_in_ejac = sat10000(state->metrics[h].oral_in_ejac + 1u);
                state->hold_timer_ms = 0u;
                state->phase = DC_TYPE7_PHASE_MOUTH_HOLD;
                out->body_clip[0] = 101;
                out->body_next_clip[0] = 111;
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT || it->action_id == ACT_FINISH_BOTH) {
                state->metrics[h].oral_out_ejac = sat10000(state->metrics[h].oral_out_ejac + 1u);
                if (it->action_id == ACT_FINISH_BOTH) state->metrics[h].heroine_climaxes = sat10000(state->metrics[h].heroine_climaxes + 1u);
                state->arousal[h] = 0.0f;
                state->oral_afterglow_irrumatio = 0u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = (it->action_id == ACT_FINISH_BOTH) ? 124 : 104;
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            } else if (it->action_id == ACT_SWALLOW) {
                state->metrics[h].swallowed = 2u; /* > 1 triggers raw+0x00 in 0x0047d000 */
                state->arousal[h] = 0.0f;
                state->hold_timer_ms = 0u;
                state->oral_afterglow_irrumatio = 0u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = 112; /* 112 -> 113 -> 134 */
            } else if (it->action_id == ACT_SPIT) {
                if (state->metrics[h].swallowed == 0u) state->metrics[h].swallowed = 1u;
                state->arousal[h] = 0.0f;
                state->hold_timer_ms = 0u;
                state->oral_afterglow_irrumatio = 0u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = 114; /* 114 -> 115 -> 134 */
            } else if (it->action_id == ACT_RESTART) {
                state->oral_pos = 0u;
                state->oral_fast = 0u;
                if (it->aux == 1u) {
                    /* Restart Irrumatio -> 80 (138->139->80 from 134, 141->142->80 from 136). */
                    state->phase = DC_TYPE7_PHASE_PAUSE_HOLD;
                    out->body_clip[0] = state->oral_afterglow_irrumatio ? 141 : 138;
                } else {
                    /* Restart BJ -> 1 (137->1 from 134, 140->1 from 136). */
                    state->phase = DC_TYPE7_PHASE_SLOW;
                    out->body_clip[0] = state->oral_afterglow_irrumatio ? 140 : 137;
                }
            }
            break;
        }
        case DC_TYPE7_SUB_3P_SEX: {
            if (it->action_id == ACT_TARGET_SLOT_VAG || it->action_id == ACT_TARGET_SLOT_ANAL) {
                uint8_t sl = it->aux & 1u;
                uint8_t h = state->slots[sl];
                state->active_slot = (int8_t)sl;
                state->primary_heroine = h;
                state->hole = (it->action_id == ACT_TARGET_SLOT_ANAL) ? 1u : 0u;
                if (state->hole) { state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u); state->metrics[h].anal_used = 1u; }
                state->phase = DC_TYPE7_PHASE_SLOW;
                if (!state->vibe_mask) setup_3p_piston_chains(sl, true, out);
                out->body_clip[0] = k_3p_sex[sl][state->hole ? 6u : 2u];
                bump_arousal(state, h, 0.20f);
            } else if (it->action_id == ACT_SWITCH_HOLE) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                uint8_t h = state->slots[sl];
                state->hole = it->aux & 1u;
                if (state->hole) { state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u); state->metrics[h].anal_used = 1u; }
                out->body_clip[0] = state->vibe_mask ? k_3p_vibe[sl][2] : setup_3p_piston_chains(sl, false, out);
                bump_arousal(state, h, 0.15f);
            } else if (it->action_id == ACT_TOGGLE_VIBE) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                state->vibe_mask ^= (uint8_t)(1u << (sl ^ 1u));
                if (state->vibe_mask) {
                    out->body_clip[0] = k_3p_vibe[sl][0];
                } else {
                    plan_add_chain(out, 0u, k_3p_vibe[sl][6], setup_3p_piston_chains(sl, false, out));
                    out->body_clip[0] = k_3p_vibe[sl][6];
                }
                bump_arousal(state, state->slots[sl ^ 1u], 0.20f);
            } else if (it->action_id == ACT_SPEED_UP) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                state->phase = DC_TYPE7_PHASE_FAST;
                out->body_clip[0] = state->vibe_mask ? k_3p_vibe[sl][3] : k_3p_sex[sl][24];
                bump_arousal(state, state->slots[0], 0.25f);
                bump_arousal(state, state->slots[1], 0.20f);
            } else if (it->action_id == ACT_SPEED_DOWN) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = state->vibe_mask ? k_3p_vibe[sl][5] : setup_3p_piston_chains(sl, false, out);
            } else if (it->action_id == ACT_FINISH_IN || it->action_id == ACT_FINISH_BOTH) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                uint8_t h = state->slots[sl];
                if (state->hole) state->metrics[h].anal_in_ejac = sat10000(state->metrics[h].anal_in_ejac + 1u);
                else state->metrics[h].vaginal_in_ejac = sat10000(state->metrics[h].vaginal_in_ejac + 1u);
                state->metrics[h].heroine_climaxes = sat10000(state->metrics[h].heroine_climaxes + 1u);
                state->arousal[state->slots[0]] = 0.0f;
                state->arousal[state->slots[1]] = 0.0f;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = k_3p_sex[sl][29]; /* 29->30->31->38 or 81->82->83->38 */
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT) {
                uint8_t sl = (state->active_slot == 1) ? 1u : 0u;
                uint8_t h = state->slots[sl];
                state->metrics[h].out_ejac = sat10000(state->metrics[h].out_ejac + 1u);
                state->arousal[h] = 0.0f;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = k_3p_sex[sl][32]; /* 32->33->34->38 or 84->85->86->38 */
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            }
            break;
        }
        case DC_TYPE7_SUB_3P_ORAL: {
            state->metrics[state->slots[0]].caress_used = 1u;
            state->metrics[state->slots[1]].caress_used = 1u;
            if (it->action_id == ACT_ORAL_POS) {
                state->oral_pos = it->aux % 5u;
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = k_3p_oral[state->oral_pos][0];
            } else if (it->action_id == ACT_SPEED_UP) {
                state->oral_fast = 1u;
                state->phase = DC_TYPE7_PHASE_FAST;
                out->body_clip[0] = k_3p_oral[state->oral_pos][1];
                setup_3p_oral_loops(k_3p_oral[state->oral_pos][2], out);
                bump_arousal(state, state->slots[0], 0.25f);
                bump_arousal(state, state->slots[1], 0.25f);
            } else if (it->action_id == ACT_SPEED_DOWN || it->action_id == ACT_CONTINUE) {
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = k_3p_oral[state->oral_pos][0];
            } else if (it->action_id == ACT_EDGE) {
                state->phase = DC_TYPE7_PHASE_EDGE;
                out->body_clip[0] = 67;
            } else if (it->action_id == ACT_FINISH_IN || it->action_id == ACT_FINISH_BOTH) {
                state->metrics[state->slots[0]].swallowed = 2u;
                state->metrics[state->slots[1]].swallowed = 2u;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = (it->action_id == ACT_FINISH_BOTH) ? 77 : 68;
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT) {
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = 71;
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            } else if (it->action_id == ACT_RESTART) {
                state->oral_pos = 0u;
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                out->body_clip[0] = 79;
                setup_3p_oral_loops(1, out);
            }
            setup_3p_oral_loops(out->body_clip[0], out);
            break;
        }
        case DC_TYPE7_SUB_4P_SEX: {
            uint8_t cur_sl = (state->active_slot >= 0 && state->active_slot < 3) ? (uint8_t)state->active_slot : 1u;
            if (it->action_id == ACT_TARGET_SLOT_VAG || it->action_id == ACT_TARGET_SLOT_ANAL) {
                uint8_t to_sl = it->aux % 3u;
                uint8_t new_hole = (it->action_id == ACT_TARGET_SLOT_ANAL) ? 1u : 0u;
                int32_t sw = k_4p_switch[cur_sl][to_sl];
                if (cur_sl != to_sl && sw < 0) {
                    /* Non-adjacent 4P switch (0 <-> 2) fades via 0x005282f0. */
                    state->fade_pending = 1u;
                    state->fade_kind = DC_TYPE7_FADE_SWAP;
                    state->pending_sub_mode = DC_TYPE7_SUB_4P_SEX;
                    state->pending_rig_mode = state->rig_mode;
                    state->pending_slot = (int8_t)to_sl;
                    state->pending_hole = new_hole;
                    out->start_fade = 1u;
                    out->fade_kind = DC_TYPE7_FADE_SWAP;
                    return DC_OK;
                }
                state->active_slot = (int8_t)to_sl;
                state->vibe_mask &= (uint8_t)~(1u << to_sl);
                uint8_t h = state->slots[to_sl];
                state->primary_heroine = h;
                state->hole = new_hole;
                if (new_hole) { state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u); state->metrics[h].anal_used = 1u; }
                state->phase = DC_TYPE7_PHASE_SLOW;
                setup_4p_piston_chains(to_sl, true, out);
                out->body_clip[0] = k_4p_sex[to_sl][new_hole ? 6u : 2u];
                fill_4p_heroine_clips(state, new_hole ? 6 : 2, out);
                bump_arousal(state, h, 0.20f);
            } else if (it->action_id == ACT_SWITCH_HOLE) {
                uint8_t h = state->slots[cur_sl];
                state->hole = it->aux & 1u;
                if (state->hole) { state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u); state->metrics[h].anal_used = 1u; }
                setup_4p_piston_chains(cur_sl, false, out);
                out->body_clip[0] = k_4p_sex[cur_sl][11];
                fill_4p_heroine_clips(state, 11, out);
            } else if (it->action_id == ACT_TOGGLE_VIBE) {
                uint8_t vsl = it->aux % 3u;
                if (vsl != cur_sl) state->vibe_mask ^= (uint8_t)(1u << vsl);
                setup_4p_piston_chains(cur_sl, false, out);
                out->body_clip[0] = k_4p_sex[cur_sl][11];
                fill_4p_heroine_clips(state, 11, out);
                bump_arousal(state, state->slots[vsl], 0.20f);
            } else if (it->action_id == ACT_SPEED_UP) {
                state->phase = DC_TYPE7_PHASE_FAST;
                out->body_clip[0] = k_4p_sex[cur_sl][24];
                fill_4p_heroine_clips(state, 24, out);
                bump_arousal(state, state->slots[cur_sl], 0.25f);
            } else if (it->action_id == ACT_SPEED_DOWN || it->action_id == ACT_CONTINUE) {
                state->phase = DC_TYPE7_PHASE_SLOW;
                setup_4p_piston_chains(cur_sl, true, out);
                out->body_clip[0] = k_4p_sex[cur_sl][51];
                fill_4p_heroine_clips(state, 51, out);
            } else if (it->action_id == ACT_SECOND_WAVE) {
                uint8_t h = state->slots[cur_sl];
                if (state->hole) state->metrics[h].anal_in_ejac = sat10000(state->metrics[h].anal_in_ejac + 1u);
                else state->metrics[h].vaginal_in_ejac = sat10000(state->metrics[h].vaginal_in_ejac + 1u);
                state->phase = DC_TYPE7_PHASE_SECOND_HOLD;
                out->body_clip[0] = k_4p_sex[cur_sl][26];
                fill_4p_heroine_clips(state, 26, out);
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_IN || it->action_id == ACT_FINAL_FINISH) {
                uint8_t h = state->slots[cur_sl];
                if (state->hole) state->metrics[h].anal_in_ejac = sat10000(state->metrics[h].anal_in_ejac + 1u);
                else state->metrics[h].vaginal_in_ejac = sat10000(state->metrics[h].vaginal_in_ejac + 1u);
                state->metrics[h].heroine_climaxes = sat10000(state->metrics[h].heroine_climaxes + 1u);
                state->arousal[h] = 0.0f;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                int32_t idx = (it->action_id == ACT_FINAL_FINISH) ? 52 : 29;
                out->body_clip[0] = k_4p_sex[cur_sl][idx];
                fill_4p_heroine_clips(state, idx, out);
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT) {
                uint8_t h = state->slots[cur_sl];
                state->metrics[h].out_ejac = sat10000(state->metrics[h].out_ejac + 1u);
                state->arousal[h] = 0.0f;
                state->phase = DC_TYPE7_PHASE_SECOND_HOLD;
                out->body_clip[0] = k_4p_sex[cur_sl][32];
                fill_4p_heroine_clips(state, 32, out);
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            }
            break;
        }
        case DC_TYPE7_SUB_4P_ORAL: {
            for (uint8_t i = 0; i < 3u; ++i) state->metrics[i].caress_used = 1u;
            int32_t target = 1;
            if (it->action_id == ACT_ORAL_POS) {
                state->oral_pos = it->aux & 1u;
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                target = k_4p_oral[state->oral_pos][0];
            } else if (it->action_id == ACT_SPEED_UP) {
                state->oral_fast = 1u;
                state->phase = DC_TYPE7_PHASE_FAST;
                target = k_4p_oral[state->oral_pos][1];
                setup_4p_oral_loops(k_4p_oral[state->oral_pos][2], out);
                for (uint8_t i = 0; i < 3u; ++i) bump_arousal(state, i, 0.25f);
            } else if (it->action_id == ACT_SPEED_DOWN || it->action_id == ACT_CONTINUE) {
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                target = k_4p_oral[state->oral_pos][0];
            } else if (it->action_id == ACT_EDGE) {
                state->phase = DC_TYPE7_PHASE_EDGE;
                target = 18;
            } else if (it->action_id == ACT_FINISH_IN || it->action_id == ACT_FINISH_BOTH) {
                for (uint8_t i = 0; i < 3u; ++i) { state->metrics[i].swallowed = 2u; state->arousal[i] = 0.0f; }
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                target = (it->action_id == ACT_FINISH_BOTH) ? 29 : 19;
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT) {
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                target = 25;
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            } else if (it->action_id == ACT_RESTART) {
                state->oral_pos = 0u;
                state->oral_fast = 0u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                target = 30;
                setup_4p_oral_loops(1, out);
            }
            setup_4p_oral_loops(target, out);
            for (uint8_t b = 0; b < 4u; ++b) out->body_clip[b] = target;
            break;
        }
        case DC_TYPE7_SUB_5P: {
            uint8_t h = state->slots[0];
            if (it->action_id == ACT_INSERT_VAG) {
                state->cummed_piston = 0u;
                state->metrics[h].anal_penetrations = sat10000(state->metrics[h].anal_penetrations + 1u);
                state->metrics[h].anal_used = 1u;
                state->metrics[h].posture_a_used = 1u;
                state->metrics[h].posture_b_used = 1u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                setup_5p_piston_chains(false, true, out);
                out->body_clip[0] = 2; /* 2..9 -> 10 -> 11..14 */
                bump_arousal(state, h, 0.25f);
            } else if (it->action_id == ACT_SPEED_UP) {
                state->phase = DC_TYPE7_PHASE_FAST;
                out->body_clip[0] = 24; /* 24 -> 25 */
                bump_arousal(state, h, 0.35f);
            } else if (it->action_id == ACT_CONTINUE) {
                state->cummed_piston = 1u;
                state->phase = DC_TYPE7_PHASE_SLOW;
                setup_5p_piston_chains(true, true, out);
                out->body_clip[0] = 51; /* 51 -> 10 -> 39..42 */
            } else if (it->action_id == ACT_SECOND_WAVE) {
                state->metrics[h].vaginal_in_ejac = sat10000(state->metrics[h].vaginal_in_ejac + 1u);
                state->metrics[h].swallowed = 2u;
                state->phase = DC_TYPE7_PHASE_SECOND_HOLD;
                out->body_clip[0] = 26; /* 26->27->28->38 */
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
                bump_arousal(state, h, 0.30f);
            } else if (it->action_id == ACT_FINISH_IN || it->action_id == ACT_FINAL_FINISH) {
                state->metrics[h].vaginal_in_ejac = sat10000(state->metrics[h].vaginal_in_ejac + 1u);
                state->metrics[h].anal_in_ejac = sat10000(state->metrics[h].anal_in_ejac + 1u);
                state->metrics[h].heroine_climaxes = sat10000(state->metrics[h].heroine_climaxes + 1u);
                state->metrics[h].swallowed = 2u;
                state->arousal[h] = 0.0f;
                state->phase = DC_TYPE7_PHASE_AFTERGLOW;
                out->body_clip[0] = (it->action_id == ACT_FINAL_FINISH) ? 52 : 29; /* -> 53 */
                snprintf(out->se_name, sizeof(out->se_name), "se330.wav");
            } else if (it->action_id == ACT_FINISH_OUT) {
                state->metrics[h].out_ejac = sat10000(state->metrics[h].out_ejac + 1u);
                state->phase = DC_TYPE7_PHASE_SECOND_HOLD;
                out->body_clip[0] = 32; /* 32->33->34->38 */
                snprintf(out->se_name, sizeof(out->se_name), "se331.wav");
            } else if (it->action_id == ACT_RESTART) {
                state->phase = DC_TYPE7_PHASE_IDLE;
                out->body_clip[0] = 56; /* 56 -> 1 */
            }
            break;
        }
    }

    dc_type7_voice_stem(state, &out->voice_heroine, out->voice_stem);
    return DC_OK;
}

dc_status dc_type7_complete_fade(dc_type7_state *state, dc_type7_plan *out) {
    if (!state || !out) return DC_ARGUMENT;
    if (!state->fade_pending || state->fade_kind != DC_TYPE7_FADE_SWAP) return DC_RANGE;

    state->fade_pending = 0u;
    state->fade_kind = DC_TYPE7_FADE_NONE;
    state->sub_mode = state->pending_sub_mode;
    state->rig_mode = state->pending_rig_mode;
    state->hole = state->pending_hole;
    state->oral_pos = 0u;
    state->oral_fast = 0u;
    state->vibe_mask = 0u;

    uint8_t bc = (state->sub_mode == DC_TYPE7_SUB_4P_SEX || state->sub_mode == DC_TYPE7_SUB_4P_ORAL) ? 4u : 1u;
    clear_plan(out, bc);
    out->reset_cam_preset = 1u;

    switch (state->sub_mode) {
        case DC_TYPE7_SUB_2P_SEX: {
            uint8_t r = state->rig_mode;
            apply_2p_rig_overrides(r, out);
            int32_t idle = k_2p_sex[r][1];
            if (idle >= 0) {
                state->phase = DC_TYPE7_PHASE_IDLE;
                out->body_clip[0] = idle;
            } else {
                state->phase = DC_TYPE7_PHASE_SLOW;
                state->sub_style = 0u;
                record_posture(state, state->slots[0]);
                out->body_clip[0] = (r == 1u || r == 4u) ? k_2p_sex[r][10]
                    : setup_2p_piston_chains(state, r, false, out);
            }
            break;
        }
        case DC_TYPE7_SUB_2P_ORAL:
            state->phase = DC_TYPE7_PHASE_SLOW;
            state->metrics[state->slots[0]].caress_used = 1u;
            out->body_clip[0] = k_2p_oral[0][0];
            break;
        case DC_TYPE7_SUB_3P_SEX:
            state->phase = DC_TYPE7_PHASE_IDLE;
            state->active_slot = -1;
            out->body_clip[0] = 1;
            break;
        case DC_TYPE7_SUB_3P_ORAL:
            state->phase = DC_TYPE7_PHASE_SLOW;
            state->metrics[state->slots[0]].caress_used = 1u;
            state->metrics[state->slots[1]].caress_used = 1u;
            out->body_clip[0] = k_3p_oral[0][0];
            break;
        case DC_TYPE7_SUB_4P_SEX: {
            uint8_t sl = (state->pending_slot >= 0 && state->pending_slot < 3) ? (uint8_t)state->pending_slot : 1u;
            state->active_slot = (int8_t)sl;
            state->primary_heroine = state->slots[sl];
            state->phase = DC_TYPE7_PHASE_SLOW;
            setup_4p_piston_chains(sl, false, out);
            out->body_clip[0] = k_4p_sex[sl][11];
            fill_4p_heroine_clips(state, 11, out);
            break;
        }
        case DC_TYPE7_SUB_4P_ORAL:
            state->phase = DC_TYPE7_PHASE_SLOW;
            for (uint8_t i = 0; i < 3u; ++i) state->metrics[i].caress_used = 1u;
            setup_4p_oral_loops(k_4p_oral[0][0], out);
            for (uint8_t b = 0; b < 4u; ++b) out->body_clip[b] = k_4p_oral[0][0];
            break;
        case DC_TYPE7_SUB_5P:
            state->phase = DC_TYPE7_PHASE_IDLE;
            out->body_clip[0] = 1;
            break;
    }

    dc_type7_voice_stem(state, &out->voice_heroine, out->voice_stem);
    return DC_OK;
}

dc_status dc_type7_voice_stem(dc_type7_state *state, uint8_t *out_heroine,
    char out_stem[DC_TYPE7_NAME_CAP]) {
    if (!state || !out_stem) return DC_ARGUMENT;
    uint8_t sl = 0u;
    if (state->heroine_count > 1u) {
        sl = (state->active_slot >= 0 && state->active_slot < (int8_t)state->heroine_count)
            ? (uint8_t)state->active_slot
            : (uint8_t)(state->voice_serial % state->heroine_count);
    }
    uint8_t h = state->slots[sl];
    if (out_heroine) *out_heroine = h;
    char c = dc_type7_heroine_prefix(h);
    bool conq = (state->conquered_mask & (1u << h)) != 0u;
    uint32_t seq = (state->voice_serial++ % 3u) + 1u;

    /* All stems below are verified present in Data/RPP_11..13.pp. */
    if (state->sub_mode == DC_TYPE7_SUB_2P_SEX) {
        if (h == 2u && state->fuku_state[2][5] == 0u &&
            (state->phase == DC_TYPE7_PHASE_SLOW || state->phase == DC_TYPE7_PHASE_FAST)) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "akx701_%02u.wav", (unsigned)seq);
        } else if (state->phase == DC_TYPE7_PHASE_SLOW || state->phase == DC_TYPE7_PHASE_FAST ||
                   state->phase == DC_TYPE7_PHASE_EDGE) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%ckx501_%02u.wav", c, (unsigned)seq);
        } else {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%c%s001_%02u.wav", c, conq ? "hd" : "hg", (unsigned)seq);
        }
    } else if (state->sub_mode == DC_TYPE7_SUB_2P_ORAL) {
        if (h == 2u && state->fuku_state[2][5] == 0u && state->phase == DC_TYPE7_PHASE_FAST) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "afx701_%02u.wav", (unsigned)seq);
        } else if (state->phase == DC_TYPE7_PHASE_FAST || state->phase == DC_TYPE7_PHASE_MOUTH_HOLD) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%cfx00%u_01.wav", c, (unsigned)seq);
        } else {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%c%s001_01.wav", c, conq ? "fd" : "fg");
        }
    } else if (state->sub_mode == DC_TYPE7_SUB_3P_SEX) {
        if (state->phase == DC_TYPE7_PHASE_SLOW || state->phase == DC_TYPE7_PHASE_FAST) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%ckx501_%02u.wav", c, (unsigned)seq);
        } else {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%c%s002_01.wav", c, conq ? "ed" : "eg");
        }
    } else if (state->sub_mode == DC_TYPE7_SUB_3P_ORAL) {
        snprintf(out_stem, DC_TYPE7_NAME_CAP, "%cwd%s_01.wav", c, (h == 1u) ? "101" : "001");
    } else if (state->sub_mode == DC_TYPE7_SUB_4P_SEX) {
        if (state->vibe_mask && state->phase == DC_TYPE7_PHASE_SLOW) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%cid001_%02u.wav", c, (unsigned)seq);
        } else if (state->phase == DC_TYPE7_PHASE_SLOW || state->phase == DC_TYPE7_PHASE_FAST) {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%ckx501_%02u.wav", c, (unsigned)seq);
        } else {
            snprintf(out_stem, DC_TYPE7_NAME_CAP, "%cxd00%u_01.wav", c, (unsigned)seq);
        }
    } else if (state->sub_mode == DC_TYPE7_SUB_4P_ORAL) {
        snprintf(out_stem, DC_TYPE7_NAME_CAP, "%cxd00%u_01.wav", c, (unsigned)seq);
    } else {
        snprintf(out_stem, DC_TYPE7_NAME_CAP, "%c%s001_%02u.wav", c, conq ? "vd" : "vg", (unsigned)((seq & 1u) + 1u));
    }
    return DC_OK;
}

static void eval_badges_and_conquest(uint8_t *raw_all, uint8_t h, dc_type7_exit_outcome *out) {
    /* Exact 0x00552ce0: unlock at most ONE new badge per 2P climax session, and promote
     * raw[0x23] = 2 only when all 9 badges were ALREADY held prior to this session (0x00552e63). */
    uint8_t *raw = raw_all + (size_t)h * DC_FLOW_STAGE_BYTES;
    if (raw[0x23] != 1u) return;

    uint8_t prior_total = 0u;
    for (uint8_t b = 0; b < 9u; ++b) {
        if (raw[0x03u + b]) ++prior_total;
    }
    bool had_all_nine_before = (prior_total >= 9u || raw[0x02] >= 9u);

    uint8_t cond[9];
    cond[0] = (h != 1u && rd32(raw + 0x30) > 0u && rd32(raw + 0x30) <= 90000u) ? 1u : 0u;
    cond[1] = (h != 0u && rd16(raw + 0x14) >= 2u) ? 1u : 0u;
    cond[2] = ((uint32_t)rd16(raw + 0x16) + (uint32_t)rd16(raw + 0x18) >= 2u) ? 1u : 0u;
    cond[3] = (rd16(raw + 0x1a) >= 5u) ? 1u : 0u;
    cond[4] = (rd16(raw + 0x1c) >= 3u) ? 1u : 0u;
    cond[5] = (rd16(raw + 0x10) >= 5u) ? 1u : 0u;
    cond[6] = (rd16(raw + 0x2c) >= 1u) ? 1u : 0u;
    cond[7] = (rd16(raw + 0x1e) >= 2u) ? 1u : 0u;
    cond[8] = (rd16(raw + 0x20) >= 2u) ? 1u : 0u;

    uint8_t total = 0u;
    for (uint8_t b = 0; b < 9u; ++b) {
        if (!raw[0x03u + b] && cond[b] && !out->badge_awarded) {
            raw[0x03u + b] = 1u;
            out->badge_awarded = 1u;
            out->badge_heroine = h;
            out->badge_index = b;
        }
        if (raw[0x03u + b]) ++total;
    }
    raw[0x02] = total;
    if (had_all_nine_before && total >= 9u) {
        raw[0x23] = 2u; /* Full conquest promoted on post-9-badge 2P climax! */
        out->promoted_conquest_mask |= (uint8_t)(1u << h);
    }
}

dc_status dc_type7_commit_exit(const dc_type7_state *state, dc_flow_state *flow,
    dc_type7_exit_outcome *out) {
    if (!state || !flow || !out) return DC_ARGUMENT;
    memset(out, 0, sizeof(*out));

    bool is_2p_or_5p = (state->initial_sub_mode == DC_TYPE7_SUB_2P_SEX ||
                        state->initial_sub_mode == DC_TYPE7_SUB_5P ||
                        state->sub_mode == DC_TYPE7_SUB_2P_SEX ||
                        state->sub_mode == DC_TYPE7_SUB_2P_ORAL ||
                        state->sub_mode == DC_TYPE7_SUB_5P) &&
                       (state->heroine_count == 1u);
    bool is_pure_2p = (state->initial_sub_mode == DC_TYPE7_SUB_2P_SEX &&
                       state->heroine_count == 1u);
    uint8_t h0_progress_before = flow->raw[0x23u];
    uint8_t h0_discovery_before = flow->raw[0x2au];
    (void)h0_discovery_before;

    for (uint8_t i = 0; i < state->heroine_count; ++i) {
        uint8_t h = state->slots[i];
        if (h >= 3u) continue;
        uint8_t *raw = flow->raw + (size_t)h * DC_FLOW_STAGE_BYTES;
        const dc_type7_heroine_metrics *m = &state->metrics[h];
        bool climaxed = (m->vaginal_in_ejac > 0u || m->anal_in_ejac > 0u ||
                         m->out_ejac > 0u || m->oral_in_ejac > 0u ||
                         m->oral_out_ejac > 0u || m->heroine_climaxes > 0u);

        /* Step 1: 0x0047caa0 (unconquered 2P/5P) vs 0x0047ceb0 (conquered or 3P/4P). */
        wr16(raw + 0x26, sat10000((uint32_t)rd16(raw + 0x26) + 1u));
        wr16(raw + 0x0c, sat10000((uint32_t)rd16(raw + 0x0c) + m->vaginal_in_ejac));
        wr16(raw + 0x0e, sat10000((uint32_t)rd16(raw + 0x0e) + m->anal_in_ejac));
        if (m->vaginal_in_ejac > 0u || m->anal_in_ejac > 0u) {
            wr16(raw + 0x10, sat10000((uint32_t)rd16(raw + 0x10) + 1u));
        }
        if (raw[0x22] == 2u && m->vaginal_in_ejac > 0u) {
            raw[0x24] = 1u; /* Unsafe-day conception flag */
        }

        if (is_2p_or_5p && raw[0x23] == 1u) {
            if (h == 0u && raw[0x2a] == 0u && raw[0x22] < 4u &&
                (flow->raw[DC_FLOW_STAGE_BYTES + 0x22u] > 3u ||
                 flow->raw[2u * DC_FLOW_STAGE_BYTES + 0x22u] > 3u)) {
                raw[0x2a] = 1u;
            }
            if (m->anal_penetrations > 0u) wr16(raw + 0x14, sat10000((uint32_t)rd16(raw + 0x14) + 1u));
            if (m->posture_a_used) wr16(raw + 0x16, sat10000((uint32_t)rd16(raw + 0x16) + 1u));
            if (m->posture_b_used) wr16(raw + 0x18, sat10000((uint32_t)rd16(raw + 0x18) + 1u));
            if (m->oral_in_ejac > 0u || m->oral_out_ejac > 0u || m->swallowed > 0u) {
                wr16(raw + 0x1a, sat10000((uint32_t)rd16(raw + 0x1a) + 1u));
            }
            if (m->heroine_climaxes > 0u) wr16(raw + 0x1c, sat10000((uint32_t)rd16(raw + 0x1c) + 1u));
            if (m->caress_used || (climaxed && state->map_id != 4u && state->map_id != 8u)) {
                wr16(raw + 0x20, sat10000((uint32_t)rd16(raw + 0x20) + 1u));
            }
            if (m->stripped_flags >= 6u) wr16(raw + 0x2c, sat10000((uint32_t)rd16(raw + 0x2c) + 1u));
            if (m->special_event) raw[0x28] = 1u;
            if (state->sub_mode == DC_TYPE7_SUB_5P || state->initial_sub_mode == DC_TYPE7_SUB_5P) {
                raw[0x29] = 1u;
            }
            if (is_pure_2p && climaxed) {
                eval_badges_and_conquest(flow->raw, h, out);
            }
        }
        if (raw[0x22] == 4u && (raw[0x38] == 0u || raw[0x38] == 1u)) raw[0x38] = 2u;
        else if (raw[0x22] == 3u && raw[0x38] == 0u) raw[0x38] = 1u;

        /* Step 2: 0x0047d000 experience flags + 2P/5P-only menstrual cycle init. */
        if (m->swallowed > 1u) raw[0x00] = 1u;
        if (m->anal_penetrations > 0u || m->anal_used) raw[0x01] = 1u;
        if (is_2p_or_5p && raw[0x34] == 0u) {
            raw[0x34] = 1u;
            raw[0x35] = 5u;
            raw[0x36] = 10u;
            raw[0x37] = 6u;
        }
    }

    uint8_t h0 = state->slots[0] < 3u ? state->slots[0] : 0u;
    char c0 = dc_type7_heroine_prefix(h0);
    bool conq0 = flow->raw[(size_t)h0 * DC_FLOW_STAGE_BYTES + 0x23u] == 2u;
    if (out->promoted_conquest_mask) {
        snprintf(out->exit_voice, sizeof(out->exit_voice), "%ceg002_01.wav", c0);
    } else if (out->badge_awarded) {
        char bc = dc_type7_heroine_prefix(out->badge_heroine);
        snprintf(out->exit_voice, sizeof(out->exit_voice), "%ceg%03u_01.wav", bc, 8u + (unsigned)out->badge_index);
    } else {
        snprintf(out->exit_voice, sizeof(out->exit_voice), "%c%s001_01.wav", c0, conq0 ? "zd" : "zg");
    }

    /* Check Ch.26 (14.txt) triggers:
     * 1) Yuuko & Manaka both conquered while Aoi still locked.
     * 2) Single 2P Ayano (h0==0, unconquered) climax when r0[0x22]==3 or another heroine is visibly pregnant (>3). */
    const uint8_t *r0 = flow->raw;
    const uint8_t *r1 = flow->raw + DC_FLOW_STAGE_BYTES;
    uint8_t *r2 = flow->raw + 2u * DC_FLOW_STAGE_BYTES;
    const dc_type7_heroine_metrics *m0 = &state->metrics[0];
    bool h0_climaxed = (m0->vaginal_in_ejac > 0u || m0->anal_in_ejac > 0u ||
                        m0->out_ejac > 0u || m0->oral_in_ejac > 0u ||
                        m0->oral_out_ejac > 0u || m0->heroine_climaxes > 0u);
    bool h0_internal_ejac = (m0->vaginal_in_ejac + m0->anal_in_ejac) > 0u;
    bool ayano_ch26 = (h0 == 0u && state->heroine_count == 1u &&
                       state->initial_sub_mode == DC_TYPE7_SUB_2P_SEX &&
                       h0_progress_before != 2u && h0_climaxed &&
                       ((r0[0x22] == 3u && h0_internal_ejac) ||
                        (r0[0x22] < 4u && (r1[0x22] > 3u || r2[0x22] > 3u))));
    if ((r0[0x23] == 2u && r1[0x23] == 2u && r2[0x23] == 0u) || ayano_ch26) {
        uint8_t dst_stage = ayano_ch26 ? 0u : 2u;
        flow->meta.previous_type = 7u;
        flow->meta.scene_type = 3u;
        flow->meta.chapter = 26u;
        flow->meta.stage = dst_stage;
        out->destination_type = 3u;
        out->destination_chapter = 26u;
        out->destination_stage = dst_stage;
        return DC_OK;
    }

    /* Step 3: 0x0047d2d0 menstrual cycle advance & pregnancy/childbirth check. */
    flow->meta.previous_type = 7u;
    flow->meta.scene_type = 7u;
    flow->meta.chapter = 24u;
    flow->meta.stage = h0;
    uint32_t sched_val = 0u;
    if (dc_flow_scheduler(flow, &sched_val) == DC_OK && sched_val != 0u) {
        if (sched_val == 1u) {
            out->destination_type = 13u;
            out->destination_chapter = 27u;
            out->destination_stage = h0;
        } else {
            flow->meta.scene_type = 3u;
            flow->meta.chapter = 25u;
            out->destination_type = 3u;
            out->destination_chapter = 25u;
            out->destination_stage = h0;
        }
    } else {
        flow->meta.scene_type = 2u;
        flow->meta.chapter = 24u;
        out->destination_type = 2u;
        out->destination_chapter = 24u;
        out->destination_stage = h0;
    }
    return DC_OK;
}
