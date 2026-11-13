#include "dc_edit.h"
#include "dc_type7.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static const uint8_t k_map_ids[8] = {0u, 1u, 3u, 4u, 5u, 6u, 7u, 8u};

static const char *const k_combo_prefixes[10] = {
    "2mana", "2yuko", "2aoi",
    "5mana", "5yuko", "5aoi",
    "3m&y", "3y&a", "3m&a",
    "4p"
};

static const char *const k_map_prefixes[8] = {
    "station", "train", "toilet", "hotel", "road", "park1", "park2", "room"
};

static const int32_t k_default_cloth[6] = {2, 2, 1, 3, 1, 1};

/* Exact sprite stem table (0x0063ead8) and _da suffix flags for motions 0..75. */
static const char *const k_motion_stems[DC_EDIT_MOTION_COUNT] = {
    "no01", "no02", "no03", "no04", "no05", "no06",
    "no07", "no09", "no10", "no11", "no12", "no13",
    "no14", "no15", "no16", "no16", "no17", "no17",
    "no18", "no19", "no20", "no21", "no22", "no23",
    "no24", "no28", "no25", "no26", "no27", "no28",
    "no42", "no43", "no44", "no45", "no46", "no47",
    "no48", "no49",
    "no50", "no50", "no51", "no51", "no52", "no52",
    "no53", "no53", "no54", "no54", "no55", "no55",
    "no56", "no56", "no57", "no57", "no58", "no58",
    "no59", "no59", "no60", "no60",
    "no61", "no62", "no63", "no68", "no69", "no70",
    "no71", "no72", "no73", "no74", "no75", "no76",
    "no77", "no78", "no79", "no80"
};

static const uint8_t k_motion_is_da[DC_EDIT_MOTION_COUNT] = {
    0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,1,0,1, 0,0,0,0,0,0,
    0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,
    0,1,0,1,0,1, 0,1,0,1,0,1, 0,1,0,1,0,1, 0,1,0,1,
    0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0
};

/* Exact parameter kind table (0x0076ff88): -1=none, 0=loop, 1=speed, 2=heroine, 3=hole, 4=strip. */
static const int8_t k_param_kind[DC_EDIT_MOTION_COUNT][2] = {
    { 4,  2}, { 4,  2}, { 3,  2}, { 3,  2}, {-1, -1}, {-1, -1},
    { 1, -1}, { 1, -1}, { 1, -1}, { 1, -1}, { 1,  3}, { 1,  3},
    { 3,  2}, { 3, -1}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0},
    {-1, -1}, { 1,  0}, { 1,  0}, { 1,  0}, {-1, -1}, {-1, -1},
    {-1, -1}, { 1,  0}, {-1, -1}, {-1, -1}, {-1, -1}, { 1,  0},
    { 1,  0}, {-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}, { 1,  0},
    { 1,  0}, { 1,  0},
    { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0},
    { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0},
    { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0},
    { 1,  0}, { 1,  0}, { 1,  0}, { 1,  0},
    { 1,  0}, {-1, -1}, {-1, -1}, { 1,  0}, { 1, -1}, { 1,  0},
    { 1,  0}, { 1,  0}, { 1, -1}, { 1,  0}, { 1,  0}, { 1,  0},
    { 1,  0}, {-1, -1}, {-1, -1}, {-1, -1}
};

static const uint8_t k_catalog_count[5] = {17u, 57u, 19u, 41u, 33u};

/* Exact per-mode motion catalog (0x007706d0). */
static const int32_t k_mode_catalog[5][DC_EDIT_MAX_CATALOG] = {
    /* Mode 0: 1P Resistance (17) */
    {0,1,6,7,8,9,12,19,20,21,30,31,34,35,36,37,75},
    /* Mode 1: 2P Kiryu (57) */
    {0,1,6,7,8,9,10,11,12,13,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,
     38,39,42,43,44,45,46,47,52,53,54,55,56,57,60,61,62,64,65,68,69,70,71,72,73,74,75},
    /* Mode 2: 2P Sub-Male (19) */
    {0,1,6,7,8,9,12,19,20,21,30,31,32,33,34,35,36,37,75},
    /* Mode 3: 3P (41) */
    {0,1,2,3,4,5,6,7,9,12,14,15,16,17,18,19,20,21,30,31,32,33,34,35,36,37,
     38,39,42,43,44,45,48,49,58,59,60,61,62,66,75},
    /* Mode 4: 4P (33) */
    {0,1,2,3,4,5,6,7,8,9,12,18,19,20,21,30,31,32,33,34,35,36,37,
     40,41,50,51,60,61,62,63,67,75}
};

/* Exact transition bitmask table (0x00770cc0). */
static const uint64_t k_trans_mask[5][DC_EDIT_MAX_CATALOG] = {
    /* Mode 0 */
    {
        0x1003fULL, 0x1003fULL, 0x10047ULL, 0x1038bULL, 0x1e03bULL, 0x10063ULL,
        0x10008ULL, 0x10788ULL, 0x10788ULL, 0x10788ULL, 0x11c00ULL, 0x10010ULL,
        0x10020ULL, 0x1e030ULL, 0x1e030ULL, 0x1e030ULL, 0ULL
    },
    /* Mode 1 */
    {
        0x010000000000003fULL, 0x010000000000003fULL, 0x01000000000007c7ULL, 0x01000000003ff80bULL,
        0x010000003800003bULL, 0x01000000000007e3ULL, 0x0100000000000140ULL, 0x0100000000000180ULL,
        0x0100000000000008ULL, 0x0100000000000008ULL, 0x0100000040000000ULL, 0x01000000007ff808ULL,
        0x01000000007ff808ULL, 0x01000000007ff808ULL, 0x0100000000000008ULL, 0x0100000000017808ULL,
        0x010000000022b808ULL, 0x0100000000430000ULL, 0x0100000000000008ULL, 0x0100000000143808ULL,
        0x0100000000283808ULL, 0x0100000000700000ULL, 0x0100000007c00000ULL, 0x0100000000000010ULL,
        0x0100000000000010ULL, 0x0100000000000010ULL, 0x0100000000000020ULL, 0x0100000038000030ULL,
        0x0100000038000030ULL, 0x0100000038000030ULL, 0x01001111c0000000ULL, 0x01001000c0000000ULL,
        0x0100101740000000ULL, 0x0100100300000000ULL, 0x0100141c40000000ULL, 0x0100100c00000000ULL,
        0x0102103140000000ULL, 0x0100103000000000ULL, 0x010210d040000000ULL, 0x010010c000000000ULL,
        0x0100134140000000ULL, 0x0100130000000000ULL, 0x01001c1440000000ULL, 0x01001c0000000000ULL,
        0x0100700000000000ULL, 0x0101800000000000ULL, 0x0101800000000000ULL, 0x0100800040000004ULL,
        0x0101000040000004ULL, 0x011e001040000000ULL, 0x013e001040000000ULL, 0x013e001040000000ULL,
        0x013e001040000000ULL, 0x01e0000000000000ULL, 0x0101800000000000ULL, 0x0101800000000000ULL,
        0ULL
    },
    /* Mode 2 */
    {
        0x4003fULL, 0x4003fULL, 0x40047ULL, 0x4038bULL, 0x7803bULL, 0x40063ULL,
        0x40008ULL, 0x40788ULL, 0x40788ULL, 0x40788ULL, 0x47c00ULL, 0x40010ULL,
        0x40010ULL, 0x40010ULL, 0x40020ULL, 0x78030ULL, 0x78030ULL, 0x78030ULL, 0ULL
    },
    /* Mode 3 */
    {
        0x00000100000001ffULL, 0x00000100000001ffULL, 0x00000100000000bfULL, 0x00000100000000bfULL,
        0x00000100000000bfULL, 0x00000100000000bfULL, 0x0000010000005643ULL, 0x00000100000380bfULL,
        0x0000010003805703ULL, 0x0000010000000080ULL, 0x0000010000000e00ULL, 0x0000010000000e00ULL,
        0x0000010000003200ULL, 0x0000010000003200ULL, 0x0000010004000000ULL, 0x0000010000078080ULL,
        0x0000010000078080ULL, 0x0000010000078080ULL, 0x00000100007c0000ULL, 0x0000010000000100ULL,
        0x0000010000000100ULL, 0x0000010000000100ULL, 0x0000010000000100ULL, 0x0000010003800100ULL,
        0x0000010003800100ULL, 0x0000010003800100ULL, 0x000001115c000000ULL, 0x000001100c000000ULL,
        0x0000011174000000ULL, 0x0000011030000000ULL, 0x00000114d4000000ULL, 0x00000110c0000000ULL,
        0x0000011714000000ULL, 0x0000011300000000ULL, 0x0000011c54000000ULL, 0x0000011c00000000ULL,
        0x0000017000000000ULL, 0x0000018000000000ULL, 0x0000018000000000ULL, 0x0000018004000040ULL,
        0ULL
    },
    /* Mode 4 */
    {
        0x00000001000003ffULL, 0x00000001000003ffULL, 0x00000001000000bfULL, 0x00000001000000bfULL,
        0x00000001000000bfULL, 0x00000001000000bfULL, 0x0000000100000c43ULL, 0x00000001000070bfULL,
        0x0000000100700383ULL, 0x0000000100000e03ULL, 0x0000000100000080ULL, 0x0000000100800000ULL,
        0x000000010000f080ULL, 0x000000010000f080ULL, 0x000000010000f080ULL, 0x00000001000f8000ULL,
        0x0000000100000100ULL, 0x0000000100000100ULL, 0x0000000100000100ULL, 0x0000000100000200ULL,
        0x0000000100700300ULL, 0x0000000100700300ULL, 0x0000000100700300ULL, 0x000000010b800000ULL,
        0x0000000109800000ULL, 0x000000010e800000ULL, 0x000000010e000000ULL, 0x0000000138000000ULL,
        0x0000000140000000ULL, 0x0000000140000000ULL, 0x00000001c0000000ULL, 0x0000000180800040ULL,
        0ULL
    }
};

/* Exact pose transition guard table (0x0078d000) for M22..M29. */
static const uint8_t k_pose_ok[8][8] = {
    {0, 1, 0, 0, 1, 0, 0, 0},
    {1, 0, 1, 0, 0, 0, 0, 0},
    {0, 1, 0, 1, 0, 0, 0, 0},
    {0, 0, 1, 1, 0, 0, 0, 0},
    {1, 0, 0, 0, 0, 1, 0, 0},
    {0, 0, 0, 0, 1, 0, 1, 0},
    {0, 0, 0, 0, 0, 1, 0, 1},
    {0, 0, 0, 0, 0, 0, 1, 1}
};

static const uint8_t k_pose_dest[8] = {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u};

static int32_t rd_i32_le(const uint8_t *p) {
    uint32_t u = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                 ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    return (int32_t)u;
}

static void wr_i32_le(uint8_t *p, int32_t v) {
    uint32_t u = (uint32_t)v;
    p[0] = (uint8_t)(u & 0xffu);
    p[1] = (uint8_t)((u >> 8) & 0xffu);
    p[2] = (uint8_t)((u >> 16) & 0xffu);
    p[3] = (uint8_t)((u >> 24) & 0xffu);
}

static uint8_t combo_active_mask(int32_t combo_idx) {
    static const uint8_t masks[10] = {
        0x4u, 0x2u, 0x1u,
        0x4u, 0x2u, 0x1u,
        0x6u, 0x3u, 0x5u,
        0x7u
    };
    return (combo_idx >= 0 && combo_idx < 10) ? masks[combo_idx] : 0x4u;
}

static uint8_t combo_primary_heroine(int32_t combo_idx) {
    static const uint8_t prim[10] = {2u, 1u, 0u, 2u, 1u, 0u, 1u, 0u, 2u, 0u};
    return (combo_idx >= 0 && combo_idx < 10) ? prim[combo_idx] : 2u;
}

static void combo_3p_slots(int32_t combo_idx, uint8_t *out_s0, uint8_t *out_s1) {
    /* Matches RPP_06.pp cyclic pairs: (1,2)->dm00_01, (2,0)->dm00_03, (0,1)->dm00_05. */
    if (combo_idx == 6) { *out_s0 = 1u; *out_s1 = 2u; }
    else if (combo_idx == 8) { *out_s0 = 2u; *out_s1 = 0u; }
    else { *out_s0 = 0u; *out_s1 = 1u; }
}

static uint8_t compute_edit_mode(int32_t combo_idx, const int32_t pers[3]) {
    if (combo_idx <= 2) {
        uint8_t h = combo_primary_heroine(combo_idx);
        return (pers[h] == 0) ? DC_EDIT_MODE_1P_RESIST : DC_EDIT_MODE_2P_KIRYU;
    }
    if (combo_idx <= 5) return DC_EDIT_MODE_2P_SUB;
    if (combo_idx <= 8) return DC_EDIT_MODE_3P;
    return DC_EDIT_MODE_4P;
}

static const char *map_cam_prefix(uint8_t map_id) {
    switch (map_id) {
        case 0u: return "home";
        case 1u: return "trai";
        case 3u: return "toil";
        case 4u: return "hote";
        case 5u: return "roji";
        case 6u: return "park";
        case 7u: return "park";
        case 8u: return "mana";
        default: return "home";
    }
}

static void compute_default_init_cloth(int32_t combo_idx, int32_t map_idx,
    uint8_t active_mask, const int32_t pers[3], int32_t out_cloth[3][6]) {
    /* Exact 0x005ff900 / 0x005feeb0 / 0x005fef30 per-combo/map/heroine initial cloth slots. */
    bool bed = (map_idx == 3 || map_idx == 7);
    for (uint8_t h = 0; h < 3u; ++h) {
        if ((active_mask & (1u << h)) == 0u) {
            for (int c = 0; c < 6; ++c) out_cloth[h][c] = 0;
            continue;
        }
        int32_t hair = (pers[h] == 0) ? -1 : ((h == DC_EDIT_HEROINE_AOI) ? 1 : 0);
        if (combo_idx >= 9) {
            for (int c = 0; c < 5; ++c) out_cloth[h][c] = -1;
            out_cloth[h][5] = (h == DC_EDIT_HEROINE_AOI) ? 1 : 0;
        } else if (combo_idx >= 6) {
            out_cloth[h][0] = -1;
            out_cloth[h][1] = (h == DC_EDIT_HEROINE_MANAKA) ? -1 : 2;
            out_cloth[h][2] = -1;
            out_cloth[h][3] = 3;
            out_cloth[h][4] = bed ? 0 : 1;
            out_cloth[h][5] = (h == DC_EDIT_HEROINE_AOI) ? 1 : 0;
        } else {
            out_cloth[h][0] = 2;
            out_cloth[h][1] = (h == DC_EDIT_HEROINE_MANAKA) ? -1 : 2;
            out_cloth[h][2] = 1;
            out_cloth[h][3] = 3;
            out_cloth[h][4] = bed ? 0 : 1;
            out_cloth[h][5] = hair;
        }
    }
}

static void sync_mode_and_constraints(dc_edit_state *s) {
    s->active_mask = combo_active_mask(s->combo_idx);
    if ((s->active_mask & (1u << s->chara_heroine)) == 0u) {
        s->chara_heroine = combo_primary_heroine(s->combo_idx);
    }

    /* Enforce Yuko non-virgin & locked badges (Aoi koukan[1]=1, Yuko tijoku[0]=1). */
    s->non_virgin[DC_EDIT_HEROINE_YUKO] = 1u;
    s->badges[DC_EDIT_HEROINE_AOI][1] = 1u;
    s->badges[DC_EDIT_HEROINE_YUKO][0] = 1u;

    /* Resistance personality (0) is allowed only in combos 0..2. */
    if (s->combo_idx > 2) {
        for (uint8_t h = 0; h < 3u; ++h) {
            if (s->personality[h] == 0) s->personality[h] = 1;
        }
        if (s->map_idx == 2) s->map_idx = 0; /* Toilet disabled in multi-actor combos. */
    }

    /* 3P combos (6..8) forbid bote pregnancy (5). */
    if (s->combo_idx >= 6 && s->combo_idx <= 8) {
        for (uint8_t h = 0; h < 3u; ++h) {
            if (s->pregnancy[h] == 5) s->pregnancy[h] = 0;
        }
    }

    for (uint8_t h = 0; h < 3u; ++h) {
        if (!s->non_virgin[h] && s->pregnancy[h] >= 3) {
            s->pregnancy[h] = 0;
        }
        if (s->personality[h] == 0) {
            s->pregnancy[h] = 0;
        } else if (s->personality[h] == 2) {
            s->pubic_hair[h] = 0u;
        }
    }

    if (s->combo_idx <= 2) {
        uint8_t ph = combo_primary_heroine(s->combo_idx);
        if (s->personality[ph] == 0) {
            /* Resistance locks map: Aoi->hotel(3), Yuko->park_hiru(5), Manaka->toilet(2). */
            static const int32_t resist_map[3] = {3, 5, 2};
            s->map_idx = resist_map[ph];
        }
    }

    compute_default_init_cloth(s->combo_idx, s->map_idx, s->active_mask, s->personality, s->init_cloth);
    s->edit_mode = compute_edit_mode(s->combo_idx, s->personality);
}

static void reset_playlist_to_base(dc_edit_state *s) {
    sync_mode_and_constraints(s);
    int32_t cidx = dc_edit_catalog_index_of(s->edit_mode, 6);
    if (cidx < 0) cidx = 0;
    s->step_count = 1;
    memset(s->steps, 0, sizeof(s->steps));
    s->steps[0].cat_idx = cidx;
    s->steps[0].motion_id = dc_edit_catalog_motion(s->edit_mode, cidx);
    s->steps[0].param1 = 0;
    s->steps[0].param2 = -1;
    s->selected_step = 0;
    s->list_scroll = 0;
    s->cand_page = 0u;
    s->keypad_overwrite = 1u;
    dc_edit_replay_state(s);
}

static uint8_t heroine_strippable_mask(const dc_edit_state *s, uint8_t h) {
    if (h >= 3u || (s->active_mask & (1u << h)) == 0u) return 0u;
    uint8_t m = 0u;
    for (uint8_t c = 0; c < 5u; ++c) {
        if (c == 1u && s->cur_cloth[h][0] >= 2) continue; /* Bra blocked under full top. */
        if (s->cur_cloth[h][c] > 0) m |= (uint8_t)(1u << c);
    }
    if (s->cur_cloth[h][5] > 0) m |= (1u << 5);
    if (s->cur_acc[h][0] != 0u) m |= (1u << 6);
    if (s->cur_acc[h][1] != 0u) m |= (1u << 7);
    return m;
}

static uint8_t heroine_wearable_mask(const dc_edit_state *s, uint8_t h) {
    if (h >= 3u || (s->active_mask & (1u << h)) == 0u) return 0u;
    uint8_t m = 0u;
    for (uint8_t c = 0; c < 5u; ++c) {
        if (c == 0u && s->cur_cloth[h][1] == 1) continue;
        if (c == 1u && s->cur_cloth[h][0] == 2 && s->cur_cloth[h][1] == 0) continue;
        if (s->cur_cloth[h][c] == 0) m |= (uint8_t)(1u << c);
    }
    if (s->cur_cloth[h][5] == 0) m |= (1u << 5);
    if (s->personality[h] != 0) {
        if (s->cur_acc[h][0] == 0u) m |= (1u << 6);
        if (s->cur_acc[h][1] == 0u) m |= (1u << 7);
    }
    return m;
}

static int first_bit8(uint8_t mask) {
    for (int i = 0; i < 8; ++i) {
        if (mask & (1u << i)) return i;
    }
    return -1;
}

static int penetrated_heroine_and_hole(const dc_edit_state *s, uint8_t *out_hole) {
    for (uint8_t h = 0; h < 3u; ++h) {
        if ((s->active_mask & (1u << h)) == 0u) continue;
        for (uint8_t hl = 0; hl < 2u; ++hl) {
            if (s->hole_occ[h][hl] == 1u) {
                if (out_hole) *out_hole = hl;
                return (int)h;
            }
        }
    }
    if (out_hole) *out_hole = 0u;
    return (int)combo_primary_heroine(s->combo_idx);
}

static bool motion_guard_ok(const dc_edit_state *s, int32_t prev_m, int32_t m) {
    uint8_t prim_h = combo_primary_heroine(s->combo_idx);
    uint8_t pen_hole = 0u;
    int pen_h = penetrated_heroine_and_hole(s, &pen_hole);

    if (m == 0) {
        for (uint8_t h = 0; h < 3u; ++h) {
            if (heroine_strippable_mask(s, h) != 0u) return true;
        }
        return false;
    }
    if (m == 1) {
        for (uint8_t h = 0; h < 3u; ++h) {
            if (heroine_wearable_mask(s, h) != 0u) return true;
        }
        return false;
    }
    if (m == 2) {
        if (s->last_pos_motion != 7) return false;
        for (uint8_t h = 0; h < 3u; ++h) {
            if ((s->active_mask & (1u << h)) == 0u) continue;
            if (s->hole_occ[h][0] == 0u || s->hole_occ[h][1] == 0u) return true;
        }
        return false;
    }
    if (m == 3) {
        if (s->last_pos_motion != 7) return false;
        for (uint8_t h = 0; h < 3u; ++h) {
            if ((s->active_mask & (1u << h)) == 0u) continue;
            if (s->hole_occ[h][0] == 2u || s->hole_occ[h][1] == 2u) return true;
        }
        return false;
    }
    if (m == 4 || m == 5) {
        if (s->last_pos_motion != 7) return false;
        bool has_vibe = false;
        for (uint8_t h = 0; h < 3u; ++h) {
            if (s->hole_occ[h][0] == 2u || s->hole_occ[h][1] == 2u) has_vibe = true;
        }
        if (!has_vibe) return false;
        return (m == 4) ? (s->vibe_fast == 0u) : (s->vibe_fast != 0u);
    }
    if (m >= 6 && m <= 9) {
        if (prev_m == 0 || prev_m == 1) return m == s->last_pos_motion;
        return true;
    }
    if (m >= 22 && m <= 29) {
        uint8_t ps = s->pose_state < 8u ? s->pose_state : 4u;
        return k_pose_ok[ps][m - 22] != 0u;
    }
    if (m == 32 || m == 33) {
        if (pen_hole == 0u) return s->non_virgin[pen_h] != 0u;
        return s->badges[pen_h][1] != 0u || s->non_virgin[pen_h] != 0u;
    }
    if (m == 52 || m == 56) {
        return s->badges[prim_h][3] != 0u; /* kouin badge */
    }
    if (m == 64) {
        return s->personality[prim_h] == 1;
    }
    if (m == 65) {
        return s->personality[prim_h] == 2;
    }
    return true;
}

static void replay_up_to(dc_edit_state *s, int32_t limit_steps) {
    sync_mode_and_constraints(s);
    for (uint8_t h = 0; h < 3u; ++h) {
        for (int c = 0; c < 6; ++c) s->cur_cloth[h][c] = s->init_cloth[h][c];
        s->cur_acc[h][0] = 0u;
        s->cur_acc[h][1] = 0u;
        s->hole_occ[h][0] = 0u;
        s->hole_occ[h][1] = 0u;
    }
    s->vibe_fast = 0u;
    s->pose_state = (s->map_idx == 3 || s->map_idx == 7) ? 0u : 4u;
    s->last_pos_motion = 6;

    int32_t count = (limit_steps < s->step_count) ? limit_steps : s->step_count;
    uint8_t prim_h = combo_primary_heroine(s->combo_idx);

    for (int32_t i = 0; i < count; ++i) {
        dc_edit_step *st = &s->steps[i];
        if (st->cat_idx < 0 || st->cat_idx >= (int32_t)k_catalog_count[s->edit_mode]) {
            st->cat_idx = 0;
        }
        st->motion_id = k_mode_catalog[s->edit_mode][st->cat_idx];
        int32_t m = st->motion_id;

        if (m == 0) {
            uint8_t h = (st->param2 >= 0 && st->param2 < 3) ? (uint8_t)st->param2 : prim_h;
            int32_t sl = st->param1;
            if (sl >= 0 && sl < 6) {
                if (s->cur_cloth[h][sl] > 0) s->cur_cloth[h][sl] = 0;
            } else if (sl == 6) s->cur_acc[h][0] = 0u;
            else if (sl == 7) s->cur_acc[h][1] = 0u;
        } else if (m == 1) {
            uint8_t h = (st->param2 >= 0 && st->param2 < 3) ? (uint8_t)st->param2 : prim_h;
            int32_t sl = st->param1;
            if (sl >= 0 && sl < 6) {
                if (s->cur_cloth[h][sl] == 0) s->cur_cloth[h][sl] = k_default_cloth[sl];
            } else if (sl == 6) {
                s->cur_acc[h][0] = 1u;
            } else if (sl == 7) {
                s->cur_acc[h][1] = 1u;
            }
        } else if (m == 2) {
            uint8_t h = (st->param2 >= 0 && st->param2 < 3) ? (uint8_t)st->param2 : prim_h;
            uint8_t hl = (st->param1 == 1) ? 1u : 0u;
            s->hole_occ[h][hl] = 2u;
        } else if (m == 3) {
            uint8_t h = (st->param2 >= 0 && st->param2 < 3) ? (uint8_t)st->param2 : prim_h;
            uint8_t hl = (st->param1 == 1) ? 1u : 0u;
            if (s->hole_occ[h][hl] == 2u) s->hole_occ[h][hl] = 0u;
            bool any_v = false;
            for (uint8_t hh = 0; hh < 3u; ++hh) {
                if (s->hole_occ[hh][0] == 2u || s->hole_occ[hh][1] == 2u) any_v = true;
            }
            if (!any_v) s->vibe_fast = 0u;
        } else if (m == 4) {
            s->vibe_fast = 1u;
        } else if (m == 5) {
            s->vibe_fast = 0u;
        } else if (m >= 6 && m <= 9) {
            s->last_pos_motion = m;
            if (m == 6 || m == 8) {
                for (uint8_t hh = 0; hh < 3u; ++hh) {
                    if (s->hole_occ[hh][0] == 1u) s->hole_occ[hh][0] = 0u;
                    if (s->hole_occ[hh][1] == 1u) s->hole_occ[hh][1] = 0u;
                }
            }
        } else if (m == 12 || m == 13) {
            uint8_t h = (m == 12 && st->param2 >= 0 && st->param2 < 3 && (s->active_mask & (1u << st->param2)))
                ? (uint8_t)st->param2 : prim_h;
            uint8_t hl = (st->param1 == 1) ? 1u : 0u;
            for (uint8_t hh = 0; hh < 3u; ++hh) {
                if (s->hole_occ[hh][0] == 1u) s->hole_occ[hh][0] = 0u;
                if (s->hole_occ[hh][1] == 1u) s->hole_occ[hh][1] = 0u;
            }
            s->hole_occ[h][hl] = 1u;
            s->last_pos_motion = (hl == 0u) ? 7 : 9;
        } else if (m == 18 || m == 34 || m == 61 || m == 62) {
            for (uint8_t hh = 0; hh < 3u; ++hh) {
                if (s->hole_occ[hh][0] == 1u) s->hole_occ[hh][0] = 0u;
                if (s->hole_occ[hh][1] == 1u) s->hole_occ[hh][1] = 0u;
            }
            s->last_pos_motion = 6;
        } else if (m >= 22 && m <= 29) {
            s->pose_state = k_pose_dest[m - 22];
        } else if (m == 31 || m == 32 || m == 33) {
            s->last_pos_motion = 8;
        }
    }
}

char dc_edit_heroine_prefix(uint8_t heroine) {
    static const char prefixes[3] = {'b', 'c', 'a'};
    return heroine < 3u ? prefixes[heroine] : 'b';
}

uint8_t dc_edit_map_id_from_index(int32_t map_idx) {
    return (map_idx >= 0 && map_idx < 8) ? k_map_ids[map_idx] : 0u;
}

int32_t dc_edit_map_index_from_id(uint8_t map_id) {
    for (int32_t i = 0; i < 8; ++i) {
        if (k_map_ids[i] == map_id) return i;
    }
    return 0;
}

dc_status dc_edit_motion_sprite_name(int32_t motion_id, uint8_t selected,
    char out_name[DC_EDIT_NAME_CAP]) {
    if (!out_name) return DC_ARGUMENT;
    if (motion_id < 0 || motion_id >= DC_EDIT_MOTION_COUNT) return DC_RANGE;
    const char *stem = k_motion_stems[motion_id];
    char state_ch = selected ? 'S' : 'N';
    if (k_motion_is_da[motion_id]) {
        snprintf(out_name, DC_EDIT_NAME_CAP, "%s_%c_da.ema", stem, state_ch);
    } else {
        snprintf(out_name, DC_EDIT_NAME_CAP, "%s_%c.ema", stem, state_ch);
    }
    return DC_OK;
}

dc_status dc_edit_motion_param_kinds(int32_t motion_id, int8_t *out_p1, int8_t *out_p2) {
    if (motion_id < 0 || motion_id >= DC_EDIT_MOTION_COUNT) return DC_RANGE;
    if (out_p1) *out_p1 = k_param_kind[motion_id][0];
    if (out_p2) *out_p2 = k_param_kind[motion_id][1];
    return DC_OK;
}

uint8_t dc_edit_catalog_count(uint8_t edit_mode) {
    return edit_mode < 5u ? k_catalog_count[edit_mode] : 0u;
}

int32_t dc_edit_catalog_motion(uint8_t edit_mode, int32_t cat_idx) {
    if (edit_mode >= 5u || cat_idx < 0 || cat_idx >= (int32_t)k_catalog_count[edit_mode]) return -1;
    return k_mode_catalog[edit_mode][cat_idx];
}

int32_t dc_edit_catalog_index_of(uint8_t edit_mode, int32_t motion_id) {
    if (edit_mode >= 5u) return -1;
    uint8_t cnt = k_catalog_count[edit_mode];
    for (uint8_t i = 0; i < cnt; ++i) {
        if (k_mode_catalog[edit_mode][i] == motion_id) return (int32_t)i;
    }
    return -1;
}

dc_status dc_edit_format_autoname(int32_t combo_idx, int32_t map_idx, uint32_t serial,
    char out_filename[DC_EDIT_FILENAME_CAP]) {
    if (!out_filename) return DC_ARGUMENT;
    if (combo_idx < 0 || combo_idx >= 10 || map_idx < 0 || map_idx >= 8 || serial > 999u) {
        return DC_RANGE;
    }
    snprintf(out_filename, DC_EDIT_FILENAME_CAP, "%s%s_%03u.edt",
        k_combo_prefixes[combo_idx], k_map_prefixes[map_idx], (unsigned)serial);
    return DC_OK;
}

dc_status dc_edit_init(dc_edit_state *state) {
    if (!state) return DC_ARGUMENT;
    memset(state, 0, sizeof(*state));

    state->combo_idx = 0;
    state->map_idx = 0;
    state->tab = DC_EDIT_TAB_CHARA;
    state->chara_heroine = DC_EDIT_HEROINE_MANAKA;

    for (uint8_t h = 0; h < 3u; ++h) {
        state->personality[h] = 1;
        state->pregnancy[h] = 0;
        for (int c = 0; c < 6; ++c) state->init_cloth[h][c] = k_default_cloth[c];
    }

    /* Fresh default flags (0x005f19f0): Aoi virgin+pubic+koukan, Yuko non-virgin+hairless+tijoku, Manaka virgin+pubic. */
    state->non_virgin[DC_EDIT_HEROINE_AOI] = 0u;
    state->pubic_hair[DC_EDIT_HEROINE_AOI] = 1u;
    state->badges[DC_EDIT_HEROINE_AOI][1] = 1u;

    state->non_virgin[DC_EDIT_HEROINE_YUKO] = 1u;
    state->pubic_hair[DC_EDIT_HEROINE_YUKO] = 0u;
    state->badges[DC_EDIT_HEROINE_YUKO][0] = 1u;

    state->non_virgin[DC_EDIT_HEROINE_MANAKA] = 0u;
    state->pubic_hair[DC_EDIT_HEROINE_MANAKA] = 1u;

    reset_playlist_to_base(state);
    return DC_OK;
}

size_t dc_edit_serialized_size(const dc_edit_state *state) {
    if (!state || state->step_count < 1 || state->step_count > DC_EDIT_MAX_STEPS) return 0u;
    return (size_t)DC_EDIT_EDT_HEADER_BYTES + (size_t)state->step_count * (size_t)DC_EDIT_EDT_STEP_BYTES;
}

dc_status dc_edit_serialize(const dc_edit_state *state, uint8_t *out_buf,
    size_t buf_cap, size_t *out_written) {
    if (!state || !out_buf) return DC_ARGUMENT;
    if (state->step_count < 1 || state->step_count > DC_EDIT_MAX_STEPS) return DC_RANGE;
    size_t need = dc_edit_serialized_size(state);
    if (buf_cap < need) return DC_RANGE;

    /* Exact 0x00602e90 Data\edit\*.edt binary layout (150-byte header + 12*N steps). */
    memset(out_buf, 0, need);
    wr_i32_le(out_buf + 0x00, state->combo_idx);
    wr_i32_le(out_buf + 0x04, state->map_idx);
    wr_i32_le(out_buf + 0x08, (int32_t)state->edit_mode);
    wr_i32_le(out_buf + 0x0c, (int32_t)state->pose_state);
    wr_i32_le(out_buf + 0x10, state->last_pos_motion);
    out_buf[0x14] = state->vibe_fast ? 1u : 0u;
    wr_i32_le(out_buf + 0x15, 0);
    for (int h = 0; h < 3; ++h) {
        uint8_t *fl = out_buf + 0x19 + h * 14;
        fl[0] = (uint8_t)state->personality[h];
        fl[1] = (uint8_t)state->pregnancy[h];
        fl[2] = state->non_virgin[h] ? 1u : 0u;
        fl[3] = state->pubic_hair[h] ? 1u : 0u;
        fl[4] = 0u;
        for (int b = 0; b < 9; ++b) fl[5 + b] = state->badges[h][b] ? 1u : 0u;
    }
    out_buf[0x43] = state->active_mask;
    for (int h = 0; h < 3; ++h) {
        out_buf[0x44 + h * 2 + 0] = state->cur_acc[h][0] ? 1u : 0u;
        out_buf[0x44 + h * 2 + 1] = state->cur_acc[h][1] ? 1u : 0u;
    }
    for (int h = 0; h < 3; ++h) {
        for (int c = 0; c < 6; ++c) {
            wr_i32_le(out_buf + 0x4a + (h * 6 + c) * 4, state->cur_cloth[h][c]);
        }
    }
    wr_i32_le(out_buf + 0x92, state->step_count);
    for (int32_t i = 0; i < state->step_count; ++i) {
        uint8_t *sp = out_buf + 0x96 + (size_t)i * 12u;
        wr_i32_le(sp + 0, state->steps[i].cat_idx);
        wr_i32_le(sp + 4, state->steps[i].param1);
        wr_i32_le(sp + 8, state->steps[i].param2);
    }
    if (out_written) *out_written = need;
    return DC_OK;
}

dc_status dc_edit_deserialize(dc_edit_state *state, const uint8_t *buf,
    size_t buf_len, const char *filename) {
    if (!state || !buf) return DC_ARGUMENT;
    if (buf_len < (size_t)(DC_EDIT_EDT_HEADER_BYTES + DC_EDIT_EDT_STEP_BYTES)) return DC_FORMAT;

    int32_t combo = rd_i32_le(buf + 0x00);
    int32_t map_i = rd_i32_le(buf + 0x04);
    int32_t sc = rd_i32_le(buf + 0x92);
    if (combo < 0 || combo >= 10 || map_i < 0 || map_i >= 8) return DC_FORMAT;
    if (sc < 1 || sc > DC_EDIT_MAX_STEPS) return DC_FORMAT;
    size_t expected = (size_t)DC_EDIT_EDT_HEADER_BYTES + (size_t)sc * (size_t)DC_EDIT_EDT_STEP_BYTES;
    if (buf_len < expected) return DC_FORMAT;

    dc_edit_init(state);
    state->combo_idx = combo;
    state->map_idx = map_i;
    for (int h = 0; h < 3; ++h) {
        const uint8_t *fl = buf + 0x19 + h * 14;
        if (fl[0] > 2u || fl[1] > 5u) return DC_FORMAT;
        state->personality[h] = (int32_t)fl[0];
        state->pregnancy[h] = (int32_t)fl[1];
        state->non_virgin[h] = fl[2] ? 1u : 0u;
        state->pubic_hair[h] = fl[3] ? 1u : 0u;
        for (int b = 0; b < 9; ++b) state->badges[h][b] = fl[5 + b] ? 1u : 0u;
        for (int c = 0; c < 6; ++c) {
            int32_t cv = rd_i32_le(buf + 0x4a + (h * 6 + c) * 4);
            if (cv < -1 || cv > 4) cv = k_default_cloth[c];
            state->init_cloth[h][c] = cv;
        }
    }

    sync_mode_and_constraints(state);
    uint8_t cat_max = k_catalog_count[state->edit_mode];
    state->step_count = sc;
    for (int32_t i = 0; i < sc; ++i) {
        const uint8_t *sp = buf + 0x96 + (size_t)i * 12u;
        int32_t cidx = rd_i32_le(sp + 0);
        if (cidx < 0 || cidx >= (int32_t)cat_max) return DC_FORMAT;
        state->steps[i].cat_idx = cidx;
        state->steps[i].motion_id = k_mode_catalog[state->edit_mode][cidx];
        state->steps[i].param1 = rd_i32_le(sp + 4);
        state->steps[i].param2 = rd_i32_le(sp + 8);
    }
    state->selected_step = sc - 1;
    state->list_scroll = (sc > DC_EDIT_LIST_VISIBLE) ? (sc - DC_EDIT_LIST_VISIBLE) : 0;
    state->chara_heroine = combo_primary_heroine(combo);
    if (filename && filename[0]) {
        snprintf(state->current_filename, sizeof(state->current_filename), "%s", filename);
    } else {
        state->current_filename[0] = '\0';
    }
    dc_edit_replay_state(state);
    return DC_OK;
}

dc_status dc_edit_build_chara_ui(const dc_edit_state *state, dc_edit_chara_ui *out) {
    if (!state || !out) return DC_ARGUMENT;
    memset(out, 0, sizeof(*out));
    out->active_mask = state->active_mask;
    out->edit_mode = state->edit_mode;
    uint8_t h = state->chara_heroine < 3u ? state->chara_heroine : combo_primary_heroine(state->combo_idx);
    out->chara_heroine = h;

    /* Map enablement: resistance locks single map; multi-actor disables toilet (2). */
    if (state->edit_mode == DC_EDIT_MODE_1P_RESIST) {
        out->map_enabled_mask = (uint8_t)(1u << state->map_idx);
    } else if (state->combo_idx > 2) {
        out->map_enabled_mask = (uint8_t)(0xffu & ~(1u << 2));
    } else {
        out->map_enabled_mask = 0xffu;
    }

    /* Personality: 0 (resistance) enabled only in combos 0..2; 1 & 2 always enabled. */
    out->pers_enabled_mask = (state->combo_idx <= 2) ? 0x7u : 0x6u;

    /* Virginity: Yuko (h=1) permanently non-virgin (only bit 1 enabled). */
    if (state->personality[h] == 0) {
        out->virgin_enabled_mask = (uint8_t)(1u << (state->non_virgin[h] ? 1u : 0u));
    } else if (h == DC_EDIT_HEROINE_YUKO) {
        out->virgin_enabled_mask = 0x2u;
    } else {
        out->virgin_enabled_mask = 0x3u;
    }

    /* Pregnancy: resistance allows only 0; virgin allows 0..2; 3P forbids bote (5). */
    if (state->personality[h] == 0) {
        out->preg_enabled_mask = 0x01u;
    } else if (!state->non_virgin[h]) {
        out->preg_enabled_mask = 0x07u;
    } else if (state->combo_idx >= 6 && state->combo_idx <= 8) {
        out->preg_enabled_mask = 0x1fu;
    } else {
        out->preg_enabled_mask = 0x3fu;
    }

    /* Pubic hair & badges disabled for resistance (0) and slave (2). */
    out->pubic_enabled = (state->personality[h] == 1) ? 1u : 0u;
    if (h == DC_EDIT_HEROINE_AOI) out->badges_locked_mask = (1u << 1);
    else if (h == DC_EDIT_HEROINE_YUKO) out->badges_locked_mask = (1u << 0);

    if (state->combo_idx <= 5 && state->personality[h] == 1) {
        out->badges_enabled_mask = (uint16_t)(0x1ffu & ~out->badges_locked_mask);
    } else {
        out->badges_enabled_mask = 0u;
    }
    return DC_OK;
}

dc_status dc_edit_select_chara_heroine(dc_edit_state *state, uint8_t heroine) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u) return DC_RANGE;
    if ((state->active_mask & (1u << heroine)) == 0u) return DC_RANGE;
    state->chara_heroine = heroine;
    return DC_OK;
}

static dc_status apply_or_caution(dc_edit_state *s, uint8_t kind, int32_t a1, int32_t a2, bool needs_reset) {
    if (needs_reset && s->step_count > 1) {
        s->caution_pending = 1u;
        s->caution_kind = kind;
        s->caution_arg1 = a1;
        s->caution_arg2 = a2;
        return DC_OK;
    }
    s->caution_pending = 1u;
    s->caution_kind = kind;
    s->caution_arg1 = a1;
    s->caution_arg2 = a2;
    return dc_edit_resolve_caution(s, 1u);
}

dc_status dc_edit_set_combo(dc_edit_state *state, int32_t combo_idx) {
    if (!state) return DC_ARGUMENT;
    if (combo_idx < 0 || combo_idx >= 10) return DC_RANGE;
    if (state->combo_idx == combo_idx) return DC_OK;
    return apply_or_caution(state, DC_EDIT_CAUTION_COMBO, combo_idx, 0, true);
}

dc_status dc_edit_set_map(dc_edit_state *state, int32_t map_idx) {
    if (!state) return DC_ARGUMENT;
    if (map_idx < 0 || map_idx >= 8) return DC_RANGE;
    dc_edit_chara_ui ui;
    dc_edit_build_chara_ui(state, &ui);
    if ((ui.map_enabled_mask & (1u << map_idx)) == 0u) return DC_RANGE;
    if (state->map_idx == map_idx) return DC_OK;
    bool old_bed = (state->map_idx == 3 || state->map_idx == 7);
    bool new_bed = (map_idx == 3 || map_idx == 7);
    return apply_or_caution(state, DC_EDIT_CAUTION_MAP, map_idx, 0, old_bed != new_bed);
}

dc_status dc_edit_set_personality(dc_edit_state *state, uint8_t heroine, int32_t pers) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u || pers < 0 || pers > 2) return DC_RANGE;
    if (pers == 0 && state->combo_idx > 2) return DC_RANGE;
    if (state->personality[heroine] == pers) return DC_OK;
    return apply_or_caution(state, DC_EDIT_CAUTION_PERSONALITY, (int32_t)heroine, pers, true);
}

dc_status dc_edit_set_pregnancy(dc_edit_state *state, uint8_t heroine, int32_t preg) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u || preg < 0 || preg > 5) return DC_RANGE;
    if (state->personality[heroine] == 0 && preg != 0) return DC_RANGE;
    if (!state->non_virgin[heroine] && preg >= 3) return DC_RANGE;
    if (state->combo_idx >= 6 && state->combo_idx <= 8 && preg == 5) return DC_RANGE;
    if (state->pregnancy[heroine] == preg) return DC_OK;
    bool old_big = state->pregnancy[heroine] >= 4;
    bool new_big = preg >= 4;
    return apply_or_caution(state, DC_EDIT_CAUTION_PREGNANCY, (int32_t)heroine, preg, old_big != new_big);
}

dc_status dc_edit_set_virgin(dc_edit_state *state, uint8_t heroine, uint8_t non_virgin) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u) return DC_RANGE;
    uint8_t nv = non_virgin ? 1u : 0u;
    if (heroine == DC_EDIT_HEROINE_YUKO && nv == 0u) return DC_RANGE;
    if (state->personality[heroine] == 0) return DC_RANGE;
    if (state->non_virgin[heroine] == nv) return DC_OK;
    return apply_or_caution(state, DC_EDIT_CAUTION_VIRGIN, (int32_t)heroine, (int32_t)nv, true);
}

dc_status dc_edit_set_pubic_hair(dc_edit_state *state, uint8_t heroine, uint8_t pubic_hair) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u) return DC_RANGE;
    if (state->personality[heroine] != 1) return DC_RANGE;
    state->pubic_hair[heroine] = pubic_hair ? 1u : 0u;
    return DC_OK;
}

dc_status dc_edit_toggle_badge(dc_edit_state *state, uint8_t heroine, uint8_t badge_idx) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u || badge_idx >= 9u) return DC_RANGE;
    if (state->combo_idx > 5 || state->personality[heroine] != 1) return DC_RANGE;
    if (heroine == DC_EDIT_HEROINE_AOI && badge_idx == 1u) return DC_RANGE;
    if (heroine == DC_EDIT_HEROINE_YUKO && badge_idx == 0u) return DC_RANGE;
    state->badges[heroine][badge_idx] ^= 1u;
    return DC_OK;
}

dc_status dc_edit_resolve_caution(dc_edit_state *state, uint8_t confirm_yes) {
    if (!state) return DC_ARGUMENT;
    if (!state->caution_pending) return DC_OK;
    uint8_t kind = state->caution_kind;
    int32_t a1 = state->caution_arg1;
    int32_t a2 = state->caution_arg2;
    state->caution_pending = 0u;
    state->caution_kind = DC_EDIT_CAUTION_NONE;

    if (!confirm_yes) return DC_OK;

    bool do_reset = (state->step_count > 1);
    switch (kind) {
        case DC_EDIT_CAUTION_COMBO:
            state->combo_idx = a1;
            state->chara_heroine = combo_primary_heroine(a1);
            do_reset = true;
            break;
        case DC_EDIT_CAUTION_MAP: {
            bool old_bed = (state->map_idx == 3 || state->map_idx == 7);
            bool new_bed = (a1 == 3 || a1 == 7);
            state->map_idx = a1;
            do_reset = (old_bed != new_bed);
            break;
        }
        case DC_EDIT_CAUTION_PERSONALITY:
            state->personality[a1] = a2;
            do_reset = true;
            break;
        case DC_EDIT_CAUTION_PREGNANCY: {
            bool old_big = state->pregnancy[a1] >= 4;
            bool new_big = a2 >= 4;
            state->pregnancy[a1] = a2;
            do_reset = (old_big != new_big);
            break;
        }
        case DC_EDIT_CAUTION_VIRGIN:
            state->non_virgin[a1] = a2 ? 1u : 0u;
            if (!state->non_virgin[a1] && state->pregnancy[a1] >= 3) state->pregnancy[a1] = 0;
            do_reset = true;
            break;
        default:
            break;
    }

    state->current_filename[0] = '\0';
    if (do_reset) {
        reset_playlist_to_base(state);
    } else {
        dc_edit_replay_state(state);
    }
    return DC_OK;
}

dc_status dc_edit_replay_state(dc_edit_state *state) {
    if (!state) return DC_ARGUMENT;
    replay_up_to(state, state->step_count);
    return DC_OK;
}

dc_status dc_edit_build_motion_ui(const dc_edit_state *state, dc_edit_motion_ui *out) {
    if (!state || !out) return DC_ARGUMENT;
    memset(out, 0, sizeof(*out));
    out->p1_kind = DC_EDIT_PARAM_NONE;
    out->p2_kind = DC_EDIT_PARAM_NONE;

    if (state->step_count < 1 || state->edit_mode >= 5u) return DC_RANGE;

    const dc_edit_step *last = &state->steps[state->step_count - 1];
    out->can_play_or_save = (last->motion_id == 75) ? 1u : 0u;

    /* Candidate generation from tail step via k_trans_mask and 0x5ffe30 guards. */
    if (state->step_count < DC_EDIT_MAX_STEPS && last->cat_idx >= 0 &&
        last->cat_idx < (int32_t)k_catalog_count[state->edit_mode]) {
        uint64_t mask = k_trans_mask[state->edit_mode][last->cat_idx];
        if ((last->motion_id == 12 || last->motion_id == 13) && last->param1 == 1) {
            /* Anal insert transitions to Anal Penetrated Idle (M08, or M09 in 3P). */
            int32_t anal_idle = (state->edit_mode == DC_EDIT_MODE_3P) ? 9 : 8;
            int32_t ai_cat = dc_edit_catalog_index_of(state->edit_mode, anal_idle);
            int32_t end_cat = dc_edit_catalog_index_of(state->edit_mode, 75);
            if (ai_cat >= 0) {
                mask = (1ULL << ai_cat) | (end_cat >= 0 ? (1ULL << end_cat) : 0ULL);
            }
        }
        uint8_t cat_cnt = k_catalog_count[state->edit_mode];
        for (uint8_t ci = 0; ci < cat_cnt; ++ci) {
            if ((mask & (1ULL << ci)) == 0ULL) continue;
            int32_t mid = k_mode_catalog[state->edit_mode][ci];
            if (!motion_guard_ok(state, last->motion_id, mid)) continue;
            out->cand_cat_idx[out->cand_count] = (int32_t)ci;
            out->cand_motion_id[out->cand_count] = mid;
            out->cand_count++;
        }
    }

    out->cand_page_count = (out->cand_count == 0u)
        ? 1u : (uint8_t)((out->cand_count + DC_EDIT_CAND_PER_PAGE - 1u) / DC_EDIT_CAND_PER_PAGE);
    out->cand_page = (state->cand_page < out->cand_page_count) ? state->cand_page : 0u;

    /* Parameter enablement for currently selected step. */
    if (state->selected_step >= 0 && state->selected_step < state->step_count) {
        dc_edit_state snap = *state;
        replay_up_to(&snap, state->selected_step);

        const dc_edit_step *sel = &state->steps[state->selected_step];
        int32_t m = sel->motion_id;
        out->p1_kind = k_param_kind[m][0];
        out->p2_kind = k_param_kind[m][1];

        bool editable_structural = (state->selected_step == state->step_count - 1);

        if (out->p1_kind == DC_EDIT_PARAM_SPEED) out->speed_enabled_mask = 0x7u;
        if (out->p2_kind == DC_EDIT_PARAM_LOOP) out->keypad_enabled = 1u;

        if (m == 0 && editable_structural) {
            for (uint8_t h = 0; h < 3u; ++h) {
                if (heroine_strippable_mask(&snap, h) != 0u) out->heroine_enabled_mask |= (uint8_t)(1u << h);
            }
            uint8_t th = (sel->param2 >= 0 && sel->param2 < 3) ? (uint8_t)sel->param2 : combo_primary_heroine(state->combo_idx);
            out->strip_enabled_mask = heroine_strippable_mask(&snap, th);
        } else if (m == 1 && editable_structural) {
            for (uint8_t h = 0; h < 3u; ++h) {
                if (heroine_wearable_mask(&snap, h) != 0u) out->heroine_enabled_mask |= (uint8_t)(1u << h);
            }
            uint8_t th = (sel->param2 >= 0 && sel->param2 < 3) ? (uint8_t)sel->param2 : combo_primary_heroine(state->combo_idx);
            out->strip_enabled_mask = heroine_wearable_mask(&snap, th);
        } else if (m == 2 && editable_structural) {
            for (uint8_t h = 0; h < 3u; ++h) {
                if ((snap.active_mask & (1u << h)) == 0u) continue;
                if (snap.hole_occ[h][0] == 0u || snap.hole_occ[h][1] == 0u) {
                    out->heroine_enabled_mask |= (uint8_t)(1u << h);
                }
            }
            uint8_t th = (sel->param2 >= 0 && sel->param2 < 3) ? (uint8_t)sel->param2 : combo_primary_heroine(state->combo_idx);
            if (snap.hole_occ[th][0] == 0u) out->hole_enabled_mask |= 0x1u;
            if (snap.hole_occ[th][1] == 0u) out->hole_enabled_mask |= 0x2u;
        } else if (m == 3 && editable_structural) {
            for (uint8_t h = 0; h < 3u; ++h) {
                if ((snap.active_mask & (1u << h)) == 0u) continue;
                if (snap.hole_occ[h][0] == 2u || snap.hole_occ[h][1] == 2u) {
                    out->heroine_enabled_mask |= (uint8_t)(1u << h);
                }
            }
            uint8_t th = (sel->param2 >= 0 && sel->param2 < 3) ? (uint8_t)sel->param2 : combo_primary_heroine(state->combo_idx);
            if (snap.hole_occ[th][0] == 2u) out->hole_enabled_mask |= 0x1u;
            if (snap.hole_occ[th][1] == 2u) out->hole_enabled_mask |= 0x2u;
        } else if (m == 10 || m == 11) {
            out->hole_enabled_mask = 0x3u;
        } else if (m == 12 && editable_structural) {
            out->heroine_enabled_mask = snap.active_mask;
            uint8_t th = (sel->param2 >= 0 && sel->param2 < 3) ? (uint8_t)sel->param2 : combo_primary_heroine(state->combo_idx);
            if (snap.hole_occ[th][0] == 0u) out->hole_enabled_mask |= 0x1u;
            if (snap.hole_occ[th][1] == 0u) out->hole_enabled_mask |= 0x2u;
            if (out->hole_enabled_mask == 0u) out->hole_enabled_mask = 0x3u;
        } else if (m == 13 && editable_structural) {
            out->hole_enabled_mask = 0x3u;
        }
    }
    return DC_OK;
}

dc_status dc_edit_set_cand_page(dc_edit_state *state, uint8_t page) {
    if (!state) return DC_ARGUMENT;
    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    if (page >= ui.cand_page_count) return DC_RANGE;
    state->cand_page = page;
    return DC_OK;
}

dc_status dc_edit_append_candidate(dc_edit_state *state, int32_t cat_idx) {
    if (!state) return DC_ARGUMENT;
    if (state->step_count >= DC_EDIT_MAX_STEPS) return DC_RANGE;

    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    bool allowed = false;
    for (uint8_t i = 0; i < ui.cand_count; ++i) {
        if (ui.cand_cat_idx[i] == cat_idx) { allowed = true; break; }
    }
    if (!allowed) return DC_RANGE;

    int32_t m = k_mode_catalog[state->edit_mode][cat_idx];
    int8_t k1 = k_param_kind[m][0];
    int8_t k2 = k_param_kind[m][1];
    int32_t p1 = -1;
    int32_t p2 = -1;
    uint8_t prim_h = combo_primary_heroine(state->combo_idx);

    if (k1 == DC_EDIT_PARAM_SPEED) p1 = 1;
    if (k2 == DC_EDIT_PARAM_LOOP) p2 = 5;

    if (m == 0) {
        for (uint8_t off = 0; off < 3u; ++off) {
            uint8_t h = (uint8_t)((prim_h + off) % 3u);
            uint8_t sm = heroine_strippable_mask(state, h);
            if (sm != 0u) { p2 = (int32_t)h; p1 = first_bit8(sm); break; }
        }
    } else if (m == 1) {
        for (uint8_t off = 0; off < 3u; ++off) {
            uint8_t h = (uint8_t)((prim_h + off) % 3u);
            uint8_t wm = heroine_wearable_mask(state, h);
            if (wm != 0u) { p2 = (int32_t)h; p1 = first_bit8(wm); break; }
        }
    } else if (m == 2) {
        for (uint8_t off = 0; off < 3u; ++off) {
            uint8_t h = (uint8_t)((prim_h + off) % 3u);
            if ((state->active_mask & (1u << h)) == 0u) continue;
            if (state->hole_occ[h][0] == 0u) { p2 = (int32_t)h; p1 = 0; break; }
            if (state->hole_occ[h][1] == 0u) { p2 = (int32_t)h; p1 = 1; break; }
        }
    } else if (m == 3) {
        for (uint8_t off = 0; off < 3u; ++off) {
            uint8_t h = (uint8_t)((prim_h + off) % 3u);
            if ((state->active_mask & (1u << h)) == 0u) continue;
            if (state->hole_occ[h][0] == 2u) { p2 = (int32_t)h; p1 = 0; break; }
            if (state->hole_occ[h][1] == 2u) { p2 = (int32_t)h; p1 = 1; break; }
        }
    } else if (m == 10 || m == 11) {
        p1 = 1;
        p2 = 0;
    } else if (m == 12) {
        p2 = (int32_t)prim_h;
        p1 = (state->hole_occ[prim_h][0] == 0u) ? 0 : 1;
    } else if (m == 13) {
        p1 = 0;
    }

    int32_t idx = state->step_count++;
    state->steps[idx].cat_idx = cat_idx;
    state->steps[idx].motion_id = m;
    state->steps[idx].param1 = p1;
    state->steps[idx].param2 = p2;
    state->selected_step = idx;
    if (state->step_count > DC_EDIT_LIST_VISIBLE) {
        state->list_scroll = state->step_count - DC_EDIT_LIST_VISIBLE;
    }
    state->cand_page = 0u;
    state->keypad_overwrite = 1u;
    state->current_filename[0] = '\0';
    dc_edit_replay_state(state);
    return DC_OK;
}

dc_status dc_edit_pop_last_step(dc_edit_state *state) {
    if (!state) return DC_ARGUMENT;
    if (state->step_count <= 1) return DC_RANGE;
    state->step_count--;
    memset(&state->steps[state->step_count], 0, sizeof(dc_edit_step));
    state->selected_step = state->step_count - 1;
    int32_t max_scroll = (state->step_count > DC_EDIT_LIST_VISIBLE)
        ? (state->step_count - DC_EDIT_LIST_VISIBLE) : 0;
    if (state->list_scroll > max_scroll) state->list_scroll = max_scroll;
    state->cand_page = 0u;
    state->keypad_overwrite = 1u;
    state->current_filename[0] = '\0';
    dc_edit_replay_state(state);
    return DC_OK;
}

dc_status dc_edit_select_step(dc_edit_state *state, int32_t step_index) {
    if (!state) return DC_ARGUMENT;
    if (step_index < 0 || step_index >= state->step_count) return DC_RANGE;
    state->selected_step = step_index;
    if (step_index < state->list_scroll) state->list_scroll = step_index;
    if (step_index >= state->list_scroll + DC_EDIT_LIST_VISIBLE) {
        state->list_scroll = step_index - DC_EDIT_LIST_VISIBLE + 1;
    }
    state->keypad_overwrite = 1u;
    return DC_OK;
}

dc_status dc_edit_scroll_list(dc_edit_state *state, int32_t delta) {
    if (!state) return DC_ARGUMENT;
    int32_t max_scroll = (state->step_count > DC_EDIT_LIST_VISIBLE)
        ? (state->step_count - DC_EDIT_LIST_VISIBLE) : 0;
    int32_t next = state->list_scroll + delta;
    if (next < 0) next = 0;
    if (next > max_scroll) next = max_scroll;
    state->list_scroll = next;
    return DC_OK;
}

dc_status dc_edit_set_speed_param(dc_edit_state *state, int32_t speed_val) {
    if (!state) return DC_ARGUMENT;
    if (speed_val < 0 || speed_val > 2) return DC_RANGE;
    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    if ((ui.speed_enabled_mask & (1u << speed_val)) == 0u) return DC_RANGE;
    state->steps[state->selected_step].param1 = speed_val;
    state->current_filename[0] = '\0';
    return DC_OK;
}

dc_status dc_edit_keypad_press(dc_edit_state *state, int32_t key) {
    if (!state) return DC_ARGUMENT;
    if (key < 0 || key > 10) return DC_RANGE;
    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    if (!ui.keypad_enabled) return DC_RANGE;

    int32_t *val = &state->steps[state->selected_step].param2;
    if (key == 10) {
        /* 'C' clear resets loop count to 1 and primes overwrite. */
        *val = 1;
        state->keypad_overwrite = 1u;
    } else if (state->keypad_overwrite) {
        *val = (key == 0) ? 1 : key;
        state->keypad_overwrite = (key == 0) ? 1u : 0u;
    } else {
        int32_t next = (*val % 10) * 10 + key;
        if (next < 1) next = 1;
        if (next > 99) next = 99;
        *val = next;
        state->keypad_overwrite = 1u;
    }
    state->current_filename[0] = '\0';
    return DC_OK;
}

dc_status dc_edit_set_heroine_param(dc_edit_state *state, uint8_t heroine) {
    if (!state) return DC_ARGUMENT;
    if (heroine >= 3u) return DC_RANGE;
    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    if ((ui.heroine_enabled_mask & (1u << heroine)) == 0u) return DC_RANGE;

    dc_edit_step *sel = &state->steps[state->selected_step];
    sel->param2 = (int32_t)heroine;

    dc_edit_state snap = *state;
    replay_up_to(&snap, state->selected_step);
    if (sel->motion_id == 0) {
        uint8_t sm = heroine_strippable_mask(&snap, heroine);
        if (sel->param1 < 0 || (sm & (1u << sel->param1)) == 0u) sel->param1 = first_bit8(sm);
    } else if (sel->motion_id == 1) {
        uint8_t wm = heroine_wearable_mask(&snap, heroine);
        if (sel->param1 < 0 || (wm & (1u << sel->param1)) == 0u) sel->param1 = first_bit8(wm);
    } else if (sel->motion_id == 2) {
        if (snap.hole_occ[heroine][sel->param1 & 1] != 0u) {
            sel->param1 = (snap.hole_occ[heroine][0] == 0u) ? 0 : 1;
        }
    } else if (sel->motion_id == 3) {
        if (snap.hole_occ[heroine][sel->param1 & 1] != 2u) {
            sel->param1 = (snap.hole_occ[heroine][0] == 2u) ? 0 : 1;
        }
    }
    state->current_filename[0] = '\0';
    dc_edit_replay_state(state);
    return DC_OK;
}

dc_status dc_edit_set_hole_param(dc_edit_state *state, uint8_t hole) {
    if (!state) return DC_ARGUMENT;
    if (hole >= 2u) return DC_RANGE;
    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    if ((ui.hole_enabled_mask & (1u << hole)) == 0u) return DC_RANGE;

    dc_edit_step *sel = &state->steps[state->selected_step];
    if (ui.p1_kind == DC_EDIT_PARAM_HOLE) sel->param1 = (int32_t)hole;
    else if (ui.p2_kind == DC_EDIT_PARAM_HOLE) sel->param2 = (int32_t)hole;
    state->current_filename[0] = '\0';
    dc_edit_replay_state(state);
    return DC_OK;
}

dc_status dc_edit_set_strip_param(dc_edit_state *state, uint8_t strip_slot) {
    if (!state) return DC_ARGUMENT;
    if (strip_slot >= 8u) return DC_RANGE;
    dc_edit_motion_ui ui;
    dc_edit_build_motion_ui(state, &ui);
    if ((ui.strip_enabled_mask & (1u << strip_slot)) == 0u) return DC_RANGE;

    state->steps[state->selected_step].param1 = (int32_t)strip_slot;
    state->current_filename[0] = '\0';
    dc_edit_replay_state(state);
    return DC_OK;
}

dc_status dc_edit_resolve_assets(const dc_edit_state *state, dc_edit_assets *out) {
    if (!state || !out) return DC_ARGUMENT;
    memset(out, 0, sizeof(*out));

    uint8_t map_id = dc_edit_map_id_from_index(state->map_idx);
    out->map_id = map_id;
    out->edit_mode = state->edit_mode;
    snprintf(out->map_archive, sizeof(out->map_archive), "RPP_10.pp");
    snprintf(out->map_xx, sizeof(out->map_xx), "mm00_%02u.xx", (unsigned)map_id);
    snprintf(out->map_xl, sizeof(out->map_xl), "mp00_%02u.xl", (unsigned)map_id);
    if (map_id == 1u) {
        snprintf(out->map_xa, sizeof(out->map_xa), "mn00_01.xa");
    }
    if (map_id == 7u) {
        snprintf(out->map_glare, sizeof(out->map_glare), "mm00_07.glare");
    }

    /* Exact 0x005201e0 map BGM table across map_id 0..8 in RPP_01.pp. */
    switch (map_id) {
        case 0u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm100.wav"); break;
        case 1u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm102.wav"); break;
        case 3u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm107.wav"); break;
        case 4u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm108.wav"); break;
        case 5u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm103.wav"); break;
        case 6u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm104.wav"); break;
        case 7u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm105.wav"); break;
        case 8u: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm106.wav"); break;
        default: snprintf(out->bgm_name, sizeof(out->bgm_name), "bgm100.wav"); break;
    }

    const char *cam_pfx = map_cam_prefix(map_id);
    bool indoor = (map_id == 4u || map_id == 8u);
    uint8_t prim_h = combo_primary_heroine(state->combo_idx);
    char c0 = dc_edit_heroine_prefix(prim_h);

    switch (state->edit_mode) {
        case DC_EDIT_MODE_1P_RESIST: {
            /* Exact 0x0059b430 Mode 0 1P Resistance: RPP_05.pp %cm00_02.xx + %cn00_04.xa. */
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_05.pp");
            out->body_count = 1u;
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "%cm00_02.xx", c0);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "%cm00_02.plst", c0);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "%cn00_04.xa", c0);
            out->head_count = 1u;
            out->head_heroine[0] = prim_h;
            out->head_body_index[0] = 0u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_02.xl", (unsigned)map_id);
            snprintf(out->cam_file, sizeof(out->cam_file), "%s_t%c.cam", cam_pfx, c0);
            snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_%c", c0);
            snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_2b_%c", c0);
            break;
        }
        case DC_EDIT_MODE_2P_KIRYU: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_05.pp");
            out->body_count = 1u;
            unsigned mesh_no = indoor ? 3u : 2u;
            unsigned xa_no = indoor ? 5u : 6u;
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "%cm00_%02u.xx", c0, mesh_no);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "%cm00_%02u.plst", c0, mesh_no);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "%cn00_%02u.xa", c0, xa_no);
            snprintf(out->body_oral_xa, sizeof(out->body_oral_xa), "%cn00_07.xa", c0);
            snprintf(out->body_oral_xa_multi[0], sizeof(out->body_oral_xa_multi[0]), "%cn00_07.xa", c0);
            out->head_count = 1u;
            out->head_heroine[0] = prim_h;
            out->head_body_index[0] = 0u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_02.xl", (unsigned)map_id);
            snprintf(out->cam_file, sizeof(out->cam_file), "%s_%s.cam", cam_pfx, indoor ? "2t" : "2b");
            snprintf(out->oral_cam_file, sizeof(out->oral_cam_file), "%s_2f.cam", cam_pfx);
            snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_%s_%c", indoor ? "2f" : "2b", c0);
            snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_%s_a", indoor ? "2f" : "2b");
            snprintf(out->oral_anchor_primary, sizeof(out->oral_anchor_primary), "m_Nn_isu_%c", c0);
            snprintf(out->oral_anchor_fallback, sizeof(out->oral_anchor_fallback), "m_Nn_isu_a");
            break;
        }
        case DC_EDIT_MODE_2P_SUB: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_06.pp");
            out->body_count = 1u;
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "%cm00_04.xx", c0);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "%cm00_04.plst", c0);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "%cn00_08.xa", c0);
            out->head_count = 1u;
            out->head_heroine[0] = prim_h;
            out->head_body_index[0] = 0u;
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_05.xl", (unsigned)map_id);
            snprintf(out->cam_file, sizeof(out->cam_file), "%s_5p.cam", cam_pfx);
            snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_5_%c", c0);
            snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_5_a");
            break;
        }
        case DC_EDIT_MODE_3P: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_06.pp");
            out->body_count = 1u;
            uint8_t s0 = 0u, s1 = 1u;
            combo_3p_slots(state->combo_idx, &s0, &s1);
            unsigned pair_base = 5u;
            if (s0 == 1u && s1 == 2u) pair_base = 1u;
            else if (s0 == 2u && s1 == 0u) pair_base = 3u;
            unsigned dm_no = pair_base + (indoor ? 1u : 0u);
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "dm00_%02u.xx", dm_no);
            snprintf(out->body_plst[0], sizeof(out->body_plst[0]), "dm00_%02u.plst", dm_no);
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "dn00_%02u.xa", pair_base);
            snprintf(out->body_oral_xa, sizeof(out->body_oral_xa), "dn00_%02u.xa", pair_base + 1u);
            snprintf(out->body_oral_xa_multi[0], sizeof(out->body_oral_xa_multi[0]), "dn00_%02u.xa", pair_base + 1u);
            out->head_count = 2u;
            out->head_heroine[0] = s0;
            out->head_heroine[1] = s1;
            out->head_body_index[0] = 0u;
            out->head_body_index[1] = 0u;
            char cs0 = dc_edit_heroine_prefix(s0);
            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_03.xl", (unsigned)map_id);
            snprintf(out->cam_file, sizeof(out->cam_file), "%s_3p.cam", cam_pfx);
            snprintf(out->oral_cam_file, sizeof(out->oral_cam_file), "%s_3f.cam", cam_pfx);
            snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_3_%c", cs0);
            snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_3_a");
            snprintf(out->oral_anchor_primary, sizeof(out->oral_anchor_primary), "m_Nn_yuka_w_%c", cs0);
            snprintf(out->oral_anchor_fallback, sizeof(out->oral_anchor_fallback), "m_Nn_yuka_w_a");
            break;
        }
        case DC_EDIT_MODE_4P:
        default: {
            snprintf(out->body_archive, sizeof(out->body_archive), "RPP_06.pp");
            out->body_count = 4u;
            snprintf(out->body_xx[0], sizeof(out->body_xx[0]), "em00_01.xx");
            out->body_plst[0][0] = '\0';
            snprintf(out->body_xa[0], sizeof(out->body_xa[0]), "en00_04.xa");
            snprintf(out->body_oral_xa, sizeof(out->body_oral_xa), "en00_08.xa");
            snprintf(out->body_oral_xa_multi[0], sizeof(out->body_oral_xa_multi[0]), "en00_08.xa");

            snprintf(out->body_xx[1], sizeof(out->body_xx[1]), "am00_05.xx");
            snprintf(out->body_plst[1], sizeof(out->body_plst[1]), "am00_05.plst");
            snprintf(out->body_xa[1], sizeof(out->body_xa[1]), "en00_01.xa");
            snprintf(out->body_oral_xa_multi[1], sizeof(out->body_oral_xa_multi[1]), "en00_05.xa");

            snprintf(out->body_xx[2], sizeof(out->body_xx[2]), "bm00_05.xx");
            snprintf(out->body_plst[2], sizeof(out->body_plst[2]), "bm00_05.plst");
            snprintf(out->body_xa[2], sizeof(out->body_xa[2]), "en00_03.xa");
            snprintf(out->body_oral_xa_multi[2], sizeof(out->body_oral_xa_multi[2]), "en00_07.xa");

            snprintf(out->body_xx[3], sizeof(out->body_xx[3]), "cm00_05.xx");
            snprintf(out->body_plst[3], sizeof(out->body_plst[3]), "cm00_05.plst");
            snprintf(out->body_xa[3], sizeof(out->body_xa[3]), "en00_02.xa");
            snprintf(out->body_oral_xa_multi[3], sizeof(out->body_oral_xa_multi[3]), "en00_06.xa");

            out->head_count = 3u;
            out->head_heroine[0] = DC_EDIT_HEROINE_MANAKA; out->head_body_index[0] = 1u;
            out->head_heroine[1] = DC_EDIT_HEROINE_AOI;    out->head_body_index[1] = 2u;
            out->head_heroine[2] = DC_EDIT_HEROINE_YUKO;   out->head_body_index[2] = 3u;

            snprintf(out->char_light_xl, sizeof(out->char_light_xl), "pp%02u_04.xl", (unsigned)map_id);
            snprintf(out->cam_file, sizeof(out->cam_file), "%s_4p.cam", cam_pfx);
            snprintf(out->oral_cam_file, sizeof(out->oral_cam_file), "%s_4f.cam", cam_pfx);
            snprintf(out->anchor_primary, sizeof(out->anchor_primary), "m_Nn_yuka_4_b");
            snprintf(out->anchor_fallback, sizeof(out->anchor_fallback), "m_Nn_yuka_4_a");
            snprintf(out->oral_anchor_primary, sizeof(out->oral_anchor_primary), "m_Nn_yuka_t_b");
            snprintf(out->oral_anchor_fallback, sizeof(out->oral_anchor_fallback), "m_Nn_yuka_t_a");
            break;
        }
    }

    for (uint8_t i = 0; i < out->head_count; ++i) {
        uint8_t h = out->head_heroine[i];
        char hc = dc_edit_heroine_prefix(h);
        snprintf(out->head_xx[i], sizeof(out->head_xx[i]), "%ck00_00.xx", hc);
        snprintf(out->head_xa[i], sizeof(out->head_xa[i]), "%cn00_01.xa", hc);
        snprintf(out->head_eyes[i], sizeof(out->head_eyes[i]), "%ck00_00.eyes", hc);
        snprintf(out->head_neck[i], sizeof(out->head_neck[i]), "%cm00_01.neck", hc);
        if (state->personality[h] == 1 && state->pregnancy[h] >= 4) {
            out->head_preg_belly[i] = (state->pregnancy[h] == 5) ? 2u : 1u;
        } else {
            out->head_preg_belly[i] = 0u;
        }
        out->head_pubic_tex[i] = state->pubic_hair[h] ? 2u : 1u;
    }
    return DC_OK;
}

float dc_edit_ff_multiplier(uint8_t ff_mode) {
    static const float mults[4] = {1.0f, 2.0f, 4.0f, 8.0f};
    return ff_mode < 4u ? mults[ff_mode] : 1.0f;
}

static float speed_param_to_factor(int32_t sp) {
    if (sp == 0) return 0.75f;
    if (sp == 2) return 1.35f;
    return 1.0f;
}

static uint8_t heroine_to_4p_slot(uint8_t h) {
    /* 4P canonical slots in dc_type7: slot 0=Manaka(2), slot 1=Aoi(0), slot 2=Yuko(1). */
    if (h == DC_EDIT_HEROINE_MANAKA) return 0u;
    if (h == DC_EDIT_HEROINE_AOI) return 1u;
    return 2u;
}

static void fill_4p_edit_clips(const dc_edit_player *pl, int32_t active_idx,
    int32_t next_idx, dc_edit_step_plan *plan) {
    uint8_t sl = (pl->active_slot >= 0 && pl->active_slot < 3) ? (uint8_t)pl->active_slot : 1u;
    int32_t mc = dc_type7_clip_4p_sex(sl, (uint32_t)active_idx);
    if (mc < 0) mc = 58;
    plan->body_clip[0] = mc;
    plan->body_next_clip[0] = (next_idx > 0) ? dc_type7_clip_4p_sex(sl, (uint32_t)next_idx) : -1;

    for (uint8_t s = 0; s < 3u; ++s) {
        if (s == sl && active_idx > 1) {
            plan->body_clip[1u + s] = active_idx;
            plan->body_next_clip[1u + s] = (next_idx > 0) ? next_idx : -1;
        } else if (pl->vibe_mask & (1u << s)) {
            plan->body_clip[1u + s] = pl->vibe_fast ? 62 : 60;
            plan->body_next_clip[1u + s] = -1;
        } else {
            plan->body_clip[1u + s] = 58;
            plan->body_next_clip[1u + s] = -1;
        }
    }
}

static void choose_edit_voice_and_se(dc_edit_player *pl, const dc_edit_state *st,
    int32_t m, dc_edit_step_plan *plan) {
    uint8_t h = pl->active_heroine < 3u ? pl->active_heroine : combo_primary_heroine(st->combo_idx);
    char hc = dc_edit_heroine_prefix(h);
    bool conquered = (st->personality[h] >= 1);
    plan->voice_heroine = h;
    uint32_t v3 = (pl->voice_serial++ % 3u) + 1u;

    if (m == 10 || m == 11 || (m >= 63 && m <= 74)) {
        if (m == 70 || m == 71 || m == 72) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%cfx809_0%u.wav", hc, (unsigned)v3);
            snprintf(plan->se_name, sizeof(plan->se_name), "se015.wav");
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%cfx808_0%u.wav", hc, (unsigned)v3);
            snprintf(plan->se_name, sizeof(plan->se_name), "se012.wav");
        }
    } else if (m == 30 || m == 31 || m == 32 || m == 33 || m == 60 || m == 61 || m == 62) {
        if (conquered) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chd206_0%u.wav", hc, (unsigned)v3);
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%ckx00%u_01.wav", hc, (v3 == 1u) ? 8u : 9u);
        }
        snprintf(plan->se_name, sizeof(plan->se_name), "se015.wav");
    } else if (m >= 14 && m <= 29) {
        if (conquered) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chd204_0%u.wav", hc, (unsigned)v3);
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chg106_0%u.wav", hc, (unsigned)v3);
        }
        snprintf(plan->se_name, sizeof(plan->se_name), "se010.wav");
    } else if (m >= 35 && m <= 59) {
        if (conquered) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chd205_0%u.wav", hc, (unsigned)v3);
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chg108_0%u.wav", hc, (unsigned)v3);
        }
        snprintf(plan->se_name, sizeof(plan->se_name), "se011.wav");
    } else if (m == 12 || m == 13 || m == 34) {
        if (conquered) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chd205_0%u.wav", hc, (unsigned)v3);
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chg108_0%u.wav", hc, (unsigned)v3);
        }
        snprintf(plan->se_name, sizeof(plan->se_name), "se011.wav");
    } else if (m >= 2 && m <= 4) {
        if (conquered) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chd204_0%u.wav", hc, (unsigned)v3);
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chg106_0%u.wav", hc, (unsigned)v3);
        }
        snprintf(plan->se_name, sizeof(plan->se_name), "se010.wav");
    } else {
        if (conquered) {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chd001_0%u.wav", hc, (unsigned)v3);
        } else {
            snprintf(plan->voice_stem, sizeof(plan->voice_stem), "%chg001_0%u.wav", hc, (unsigned)v3);
        }
        plan->se_name[0] = '\0';
    }
}

static void edit_plan_add_chain(dc_edit_step_plan *p, uint8_t body, int32_t from_clip, int32_t to_clip) {
    if (!p || from_clip <= 0 || p->chain_count >= DC_EDIT_MAX_CHAINS) return;
    uint8_t idx = p->chain_count++;
    p->chain_body[idx] = body;
    p->chain_from[idx] = (uint16_t)from_clip;
    p->chain_to[idx] = (int16_t)to_clip;
}

static void edit_plan_add_loop(dc_edit_step_plan *p, uint8_t body, int32_t clip, int16_t limit) {
    if (!p || clip <= 0 || p->loop_count >= DC_EDIT_MAX_LOOPS) return;
    uint8_t idx = p->loop_count++;
    p->loop_body[idx] = body;
    p->loop_clip[idx] = (uint16_t)clip;
    p->loop_limit[idx] = limit;
}

static uint32_t edit_2p_row(bool indoor, uint8_t pose_state) {
    if (indoor) {
        if (pose_state == 1u || pose_state == 5u) return 0u;
        if (pose_state == 2u || pose_state == 3u || pose_state == 6u || pose_state == 7u) return 1u;
        return 2u;
    }
    if (pose_state == 1u || pose_state == 5u) return 5u;
    if (pose_state == 2u || pose_state == 3u || pose_state == 6u || pose_state == 7u) return 4u;
    return 3u;
}

static void build_step_plan(dc_edit_player *pl, const dc_edit_state *st, dc_edit_step_plan *plan) {
    memset(plan, 0, sizeof(*plan));
    plan->body_count = (st->edit_mode == DC_EDIT_MODE_4P) ? 4u : 1u;
    for (int i = 0; i < DC_EDIT_MAX_BODIES; ++i) {
        plan->body_clip[i] = -1;
        plan->body_next_clip[i] = -1;
    }

    /* Consume immediate M00/M01 clothing/accessory steps until a 3D motion or M75 is reached. */
    while (pl->cur_step < st->step_count) {
        const dc_edit_step *step = &st->steps[pl->cur_step];
        int32_t m = step->motion_id;
        if (m != 0 && m != 1) break;
        uint8_t h = (step->param2 >= 0 && step->param2 < 3)
            ? (uint8_t)step->param2 : combo_primary_heroine(st->combo_idx);
        int32_t sl = step->param1;
        if (m == 0) {
            if (sl >= 0 && sl < 6) {
                if (pl->cur_cloth[h][sl] > 0) pl->cur_cloth[h][sl] = 0;
            } else if (sl == 6) pl->cur_acc[h][0] = 0u;
            else if (sl == 7) pl->cur_acc[h][1] = 0u;
        } else {
            if (sl >= 0 && sl < 6) {
                if (pl->cur_cloth[h][sl] == 0) pl->cur_cloth[h][sl] = k_default_cloth[sl];
            } else if (sl == 6) {
                pl->cur_acc[h][0] = 1u;
            } else if (sl == 7) {
                pl->cur_acc[h][1] = 1u;
            }
        }
        plan->cloth_changed = 1u;
        pl->cur_step++;
    }

    memcpy(plan->cur_cloth, pl->cur_cloth, sizeof(plan->cur_cloth));
    memcpy(plan->cur_acc, pl->cur_acc, sizeof(plan->cur_acc));

    if (pl->cur_step >= st->step_count || st->steps[pl->cur_step].motion_id == 75) {
        pl->finished = 1u;
        plan->finished = 1u;
        return;
    }

    const dc_edit_step *step = &st->steps[pl->cur_step];
    int32_t m = step->motion_id;
    int8_t k1 = k_param_kind[m][0];
    int8_t k2 = k_param_kind[m][1];

    pl->base_speed = (k1 == DC_EDIT_PARAM_SPEED) ? speed_param_to_factor(step->param1) : 1.0f;
    pl->is_looping = (k2 == DC_EDIT_PARAM_LOOP) ? 1u : 0u;
    pl->loop_target = (k2 == DC_EDIT_PARAM_LOOP && step->param2 > 0) ? (uint32_t)step->param2 : 1u;
    pl->loops_done = 0u;
    pl->in_loop_clip = 0u;
    pl->use_oral_rig = 0u;

    plan->is_looping = pl->is_looping;
    plan->loop_target = pl->loop_target;
    plan->base_speed = pl->base_speed;
    plan->effective_speed = pl->base_speed * dc_edit_ff_multiplier(pl->ff_mode);

    bool indoor = (pl->map_id == 4u || pl->map_id == 8u);

    if (st->edit_mode == DC_EDIT_MODE_2P_KIRYU) {
        if (m >= 38 && m <= 74) {
            /* 0x005d1140: 2P Oral Rig (%cn00_07.xa). */
            pl->use_oral_rig = 1u;
            plan->use_oral_rig = 1u;
            int32_t c0 = 1, nc = -1;
            switch (m) {
                case 38: pl->oral_pos = 0u; c0 = dc_type7_clip_2p_oral(0u, 0u); break;
                case 39: pl->oral_pos = 0u; c0 = dc_type7_clip_2p_oral(0u, 1u); nc = dc_type7_clip_2p_oral(0u, 2u); break;
                case 42: pl->oral_pos = 1u; c0 = dc_type7_clip_2p_oral(1u, 0u); break;
                case 43: pl->oral_pos = 1u; c0 = dc_type7_clip_2p_oral(1u, 1u); nc = dc_type7_clip_2p_oral(1u, 2u); break;
                case 44: pl->oral_pos = 2u; c0 = dc_type7_clip_2p_oral(2u, 0u); break;
                case 45: pl->oral_pos = 2u; c0 = dc_type7_clip_2p_oral(2u, 1u); nc = dc_type7_clip_2p_oral(2u, 2u); break;
                case 46: pl->oral_pos = 3u; c0 = dc_type7_clip_2p_oral(3u, 0u); break;
                case 47: pl->oral_pos = 3u; c0 = dc_type7_clip_2p_oral(3u, 1u); nc = dc_type7_clip_2p_oral(3u, 2u); break;
                case 52: pl->oral_pos = 4u; c0 = dc_type7_clip_2p_oral(4u, 0u); break;
                case 53: pl->oral_pos = 4u; c0 = dc_type7_clip_2p_oral(4u, 1u); nc = dc_type7_clip_2p_oral(4u, 2u); break;
                case 54: pl->oral_pos = 5u; c0 = dc_type7_clip_2p_oral(5u, 0u); break;
                case 55: pl->oral_pos = 5u; c0 = dc_type7_clip_2p_oral(5u, 1u); nc = dc_type7_clip_2p_oral(5u, 2u); break;
                case 56: pl->oral_pos = 6u; c0 = dc_type7_clip_2p_oral(6u, 0u); break;
                case 57: pl->oral_pos = 6u; c0 = dc_type7_clip_2p_oral(6u, 1u); nc = dc_type7_clip_2p_oral(6u, 2u); break;
                case 60: c0 = (pl->oral_pos == 7u) ? 98 : 107; nc = (pl->oral_pos == 7u) ? 100 : -1; break;
                case 61: c0 = (pl->oral_pos == 7u) ? 101 : 108; nc = (pl->oral_pos == 7u) ? 103 : 110; break;
                case 62: c0 = 104; nc = 106; break;
                case 64: pl->oral_pos = 0u; c0 = 137; break;
                case 65: pl->oral_pos = 7u; c0 = 138; nc = 139; break;
                case 68: pl->oral_pos = 7u; c0 = 80; pl->is_looping = 1u; pl->loop_target = 2u; break;
                case 69:
                    pl->oral_pos = 7u; c0 = 82; nc = 85;
                    edit_plan_add_chain(plan, 0u, 82, 83);
                    edit_plan_add_chain(plan, 0u, 83, 84);
                    edit_plan_add_chain(plan, 0u, 84, 85);
                    edit_plan_add_chain(plan, 0u, 85, 82);
                    break;
                case 70:
                    pl->oral_pos = 7u; c0 = 82; nc = 86;
                    edit_plan_add_chain(plan, 0u, 82, 83);
                    edit_plan_add_chain(plan, 0u, 83, 86);
                    edit_plan_add_chain(plan, 0u, 86, 83);
                    break;
                case 71:
                    pl->oral_pos = 7u; c0 = 87; nc = 91;
                    edit_plan_add_loop(plan, 0u, 88, -1);
                    edit_plan_add_chain(plan, 0u, 87, 88);
                    edit_plan_add_chain(plan, 0u, 88, 89);
                    edit_plan_add_chain(plan, 0u, 89, 90);
                    edit_plan_add_chain(plan, 0u, 90, 91);
                    edit_plan_add_chain(plan, 0u, 91, 90);
                    break;
                case 72:
                    pl->oral_pos = 7u; c0 = 94; nc = 96;
                    edit_plan_add_loop(plan, 0u, 96, 0);
                    break;
                case 73: c0 = 112; nc = 113; break;
                case 74: c0 = 114; nc = 115; break;
                default: c0 = 1; break;
            }
            if (c0 == 1 || c0 == 11 || c0 == 21 || c0 == 32 || c0 == 45 || c0 == 56 || c0 == 66) {
                edit_plan_add_loop(plan, 0u, c0, 0);
            }
            if (nc == 3 || nc == 13 || nc == 23 || nc == 34 || nc == 47 || nc == 58 || nc == 68 || nc == 100 || nc == 107) {
                edit_plan_add_loop(plan, 0u, nc, 0);
            }
            if (c0 == 107) edit_plan_add_loop(plan, 0u, 107, 0);
            plan->is_looping = pl->is_looping;
            plan->loop_target = pl->loop_target;
            plan->body_clip[0] = c0;
            plan->body_next_clip[0] = nc;
        } else {
            /* 0x0059f180: 2P Sex Rig (%cn00_05.xa indoor / %cn00_06.xa outdoor). */
            uint32_t r = edit_2p_row(indoor, pl->pose_state);
            uint32_t base_r = indoor ? 2u : 3u;
            int32_t c0 = -1, nc = -1;
            if (r == 1u || r == 4u) {
                edit_plan_add_loop(plan, 0u, dc_type7_clip_2p_sex(r, 10u), 0);
            }
            switch (m) {
                case 6:
                    pl->afterglow = 0u;
                    c0 = dc_type7_clip_2p_sex(base_r, 1u);
                    pl->is_looping = 1u; pl->loop_target = 2u;
                    break;
                case 7:
                    c0 = dc_type7_clip_2p_sex(r, 10u);
                    pl->is_looping = 1u; pl->loop_target = 2u;
                    break;
                case 8:
                    pl->afterglow = 1u;
                    c0 = dc_type7_clip_2p_sex(r, 39u);
                    if (c0 < 0) c0 = dc_type7_clip_2p_sex(base_r, 39u);
                    pl->is_looping = 1u; pl->loop_target = 2u;
                    break;
                case 9:
                    c0 = dc_type7_clip_2p_sex(base_r, 55u);
                    pl->is_looping = 1u; pl->loop_target = 2u;
                    break;
                case 10:
                case 11: {
                    /* Sex-rig foreplay caress (k_2p_sex[base_r][105..112]). */
                    uint32_t fc = (step->param2 == 1) ? 109u : 105u;
                    c0 = dc_type7_clip_2p_sex(base_r, fc + (m == 11 ? 1u : 0u));
                    nc = dc_type7_clip_2p_sex(base_r, fc + 2u);
                    edit_plan_add_loop(plan, 0u, nc, 0);
                    pl->is_looping = 1u; pl->loop_target = 3u;
                    break;
                }
                case 12:
                    pl->hole = (step->param1 == 1) ? 1u : 0u;
                    c0 = dc_type7_clip_2p_sex(base_r, pl->hole ? 6u : 2u);
                    nc = dc_type7_clip_2p_sex(base_r, pl->hole ? 9u : 5u);
                    break;
                case 13:
                    pl->hole = (step->param1 == 1) ? 1u : 0u;
                    c0 = dc_type7_clip_2p_sex(base_r, pl->hole ? 101u : 94u);
                    nc = dc_type7_clip_2p_sex(base_r, pl->hole ? 104u : 97u);
                    break;
                case 18:
                    c0 = dc_type7_clip_2p_sex(base_r, 58u);
                    if (c0 < 0) c0 = dc_type7_clip_2p_sex(r, 57u);
                    break;
                case 19:
                case 25:
                case 29:
                case 35: {
                    if (m == 25 || m == 29) {
                        pl->pose_state = k_pose_dest[m - 22];
                        r = edit_2p_row(indoor, pl->pose_state);
                    }
                    uint32_t bcol = (m == 35 && dc_type7_clip_2p_sex(r, 40u) > 0) ? 40u : 11u;
                    int32_t p0 = dc_type7_clip_2p_sex(r, bcol + 0u);
                    int32_t p1 = dc_type7_clip_2p_sex(r, bcol + 1u);
                    int32_t p2 = dc_type7_clip_2p_sex(r, bcol + 2u);
                    int32_t p3 = dc_type7_clip_2p_sex(r, bcol + 3u);
                    c0 = p0; nc = p3;
                    edit_plan_add_chain(plan, 0u, p0, p1);
                    edit_plan_add_chain(plan, 0u, p1, p2);
                    edit_plan_add_chain(plan, 0u, p2, p3);
                    edit_plan_add_chain(plan, 0u, p3, p0);
                    break;
                }
                case 20:
                case 36: {
                    uint32_t bcol = (m == 36 && dc_type7_clip_2p_sex(r, 40u) > 0) ? 40u : 11u;
                    uint32_t scol = (bcol == 40u) ? 45u : 16u;
                    int32_t p0 = dc_type7_clip_2p_sex(r, bcol + 0u);
                    int32_t p1 = dc_type7_clip_2p_sex(r, bcol + 1u);
                    int32_t sh = dc_type7_clip_2p_sex(r, scol);
                    c0 = p0; nc = sh;
                    edit_plan_add_chain(plan, 0u, p0, p1);
                    edit_plan_add_chain(plan, 0u, p1, sh);
                    edit_plan_add_chain(plan, 0u, sh, p1);
                    break;
                }
                case 21:
                case 37: {
                    uint32_t gb = (m == 37 && dc_type7_clip_2p_sex(r, 46u) > 0) ? 46u : 17u;
                    int32_t g0 = dc_type7_clip_2p_sex(r, gb + 0u);
                    int32_t g1 = dc_type7_clip_2p_sex(r, gb + 1u);
                    int32_t g2 = dc_type7_clip_2p_sex(r, gb + 2u);
                    int32_t g3 = dc_type7_clip_2p_sex(r, gb + 3u);
                    int32_t g4 = dc_type7_clip_2p_sex(r, gb + 4u);
                    c0 = g0; nc = g4;
                    edit_plan_add_loop(plan, 0u, g1, -1);
                    edit_plan_add_chain(plan, 0u, g0, g1);
                    edit_plan_add_chain(plan, 0u, g1, g2);
                    edit_plan_add_chain(plan, 0u, g2, g3);
                    edit_plan_add_chain(plan, 0u, g3, g4);
                    edit_plan_add_chain(plan, 0u, g4, g3);
                    break;
                }
                case 22: case 23: case 24: case 26: case 27: case 28: {
                    uint8_t prev_ps = pl->pose_state;
                    uint32_t prev_r = edit_2p_row(indoor, prev_ps);
                    pl->pose_state = k_pose_dest[m - 22];
                    uint32_t tr_col = (m == 22 || m == 26 || ((m == 23 || m == 27) && (prev_ps == 2u || prev_ps == 3u || prev_ps == 6u || prev_ps == 7u))) ? 59u : 60u;
                    c0 = dc_type7_clip_2p_sex(prev_r, tr_col);
                    if (c0 < 0) c0 = dc_type7_clip_2p_sex(base_r, 60u);
                    break;
                }
                case 30:
                    c0 = dc_type7_clip_2p_sex(r, 24u);
                    nc = dc_type7_clip_2p_sex(r, 26u);
                    if (nc > 0) edit_plan_add_loop(plan, 0u, nc, 0);
                    break;
                case 31: {
                    uint32_t cr = (dc_type7_clip_2p_sex(r, 27u) > 0) ? r : base_r;
                    c0 = dc_type7_clip_2p_sex(cr, 27u);
                    nc = dc_type7_clip_2p_sex(cr, 29u);
                    edit_plan_add_chain(plan, 0u, dc_type7_clip_2p_sex(cr, 28u), nc);
                    pl->afterglow = 1u;
                    break;
                }
                case 32: {
                    uint32_t cr = (dc_type7_clip_2p_sex(r, 33u) > 0) ? r : base_r;
                    c0 = dc_type7_clip_2p_sex(cr, 33u);
                    nc = dc_type7_clip_2p_sex(cr, 35u);
                    edit_plan_add_chain(plan, 0u, dc_type7_clip_2p_sex(cr, 34u), nc);
                    pl->afterglow = 1u;
                    break;
                }
                case 33: {
                    uint32_t cr = (dc_type7_clip_2p_sex(r, 36u) > 0) ? r : base_r;
                    c0 = dc_type7_clip_2p_sex(cr, 36u);
                    nc = dc_type7_clip_2p_sex(cr, 38u);
                    pl->afterglow = 1u;
                    break;
                }
                case 34: {
                    uint32_t cr = (dc_type7_clip_2p_sex(r, 30u) > 0) ? r : base_r;
                    c0 = dc_type7_clip_2p_sex(cr, 30u);
                    nc = dc_type7_clip_2p_sex(cr, 32u);
                    break;
                }
                default:
                    c0 = dc_type7_clip_2p_sex(base_r, 1u);
                    break;
            }
            if (c0 < 0) c0 = dc_type7_clip_2p_sex(base_r, 1u);
            plan->is_looping = pl->is_looping;
            plan->loop_target = pl->loop_target;
            plan->body_clip[0] = c0;
            plan->body_next_clip[0] = nc;
        }
    } else if (st->edit_mode == DC_EDIT_MODE_3P) {
        uint8_t s0 = 0u, s1 = 1u;
        combo_3p_slots(st->combo_idx, &s0, &s1);
        if (m >= 38 && m <= 66) {
            /* 0x005d5c10: 3P Oral Rig (dn00_02/04/06.xa). */
            pl->use_oral_rig = 1u;
            plan->use_oral_rig = 1u;
            int32_t c0 = 1, nc = -1;
            switch (m) {
                case 38: pl->oral_pos = 0u; c0 = dc_type7_clip_3p_oral(0u, 0u); break;
                case 39: pl->oral_pos = 0u; c0 = dc_type7_clip_3p_oral(0u, 1u); nc = dc_type7_clip_3p_oral(0u, 2u); break;
                case 42: pl->oral_pos = 1u; c0 = dc_type7_clip_3p_oral(1u, 0u); break;
                case 43: pl->oral_pos = 1u; c0 = dc_type7_clip_3p_oral(1u, 1u); nc = dc_type7_clip_3p_oral(1u, 2u); break;
                case 44: pl->oral_pos = 2u; c0 = dc_type7_clip_3p_oral(2u, 0u); break;
                case 45: pl->oral_pos = 2u; c0 = dc_type7_clip_3p_oral(2u, 1u); nc = dc_type7_clip_3p_oral(2u, 2u); break;
                case 48: pl->oral_pos = 3u; c0 = dc_type7_clip_3p_oral(3u, 0u); break;
                case 49: pl->oral_pos = 3u; c0 = dc_type7_clip_3p_oral(3u, 1u); nc = dc_type7_clip_3p_oral(3u, 2u); break;
                case 58: pl->oral_pos = 4u; c0 = dc_type7_clip_3p_oral(4u, 0u); break;
                case 59: pl->oral_pos = 4u; c0 = dc_type7_clip_3p_oral(4u, 1u); nc = dc_type7_clip_3p_oral(4u, 2u); break;
                case 60: c0 = 67; break;
                case 61: c0 = 68; nc = 70; break;
                case 62: c0 = 71; nc = 73; edit_plan_add_loop(plan, 0u, 71, -1); break;
                case 66: c0 = 79; break;
                default: c0 = 1; break;
            }
            if (c0 == 1 || c0 == 13 || c0 == 25 || c0 == 37 || c0 == 51 || c0 == 67) {
                edit_plan_add_loop(plan, 0u, c0, 0);
            }
            if (nc == 3 || nc == 15 || nc == 27 || nc == 39 || nc == 53) {
                edit_plan_add_loop(plan, 0u, nc, 0);
            }
            plan->is_looping = pl->is_looping;
            plan->loop_target = pl->loop_target;
            plan->body_clip[0] = c0;
            plan->body_next_clip[0] = nc;
        } else {
            if (m == 2 || m == 3 || m == 12) {
                uint8_t th = (step->param2 >= 0 && step->param2 < 3) ? (uint8_t)step->param2 : s0;
                uint8_t sl = (th == s1) ? 1u : 0u;
                if (m == 12) {
                    pl->active_slot = (int8_t)sl;
                    pl->active_heroine = th;
                    pl->hole = (step->param1 == 1) ? 1u : 0u;
                    plan->update_cam_pivot = 1u;
                    plan->cam_target_heroine = th;
                } else if (m == 2) {
                    pl->vibe_mask |= (uint8_t)(1u << sl);
                } else {
                    pl->vibe_mask &= (uint8_t)~(1u << sl);
                }
            } else if (m == 4) {
                pl->vibe_fast = 1u;
            } else if (m == 5) {
                pl->vibe_fast = 0u;
            }

            uint8_t sl = (pl->active_slot >= 0 && pl->active_slot < 2) ? (uint8_t)pl->active_slot : 0u;
            if (m >= 2 && m <= 5) {
                plan->body_clip[0] = dc_type7_clip_3p_vibe(sl, (uint32_t)(m - 1));
            } else if (m >= 14 && m <= 17) {
                plan->body_clip[0] = dc_type7_clip_3p_vibe(sl, (uint32_t)(m - 13));
            } else {
                uint32_t idx = 1u;
                int32_t nc = -1;
                if (m == 6) { idx = 1u; pl->is_looping = 1u; pl->loop_target = 2u; }
                else if (m == 7) { idx = 10u; pl->is_looping = 1u; pl->loop_target = 2u; }
                else if (m == 9) { idx = 35u; pl->is_looping = 1u; pl->loop_target = 2u; }
                else if (m == 12) {
                    idx = pl->hole ? 6u : 2u;
                    nc = dc_type7_clip_3p_sex(sl, pl->hole ? 9u : 5u);
                } else if (m == 18) idx = 36u;
                else if (m == 19 || m == 35) {
                    idx = 11u;
                    int32_t p0 = dc_type7_clip_3p_sex(sl, 11u);
                    int32_t p1 = dc_type7_clip_3p_sex(sl, 12u);
                    int32_t p2 = dc_type7_clip_3p_sex(sl, 13u);
                    int32_t p3 = dc_type7_clip_3p_sex(sl, 14u);
                    nc = p3;
                    edit_plan_add_chain(plan, 0u, p0, p1);
                    edit_plan_add_chain(plan, 0u, p1, p2);
                    edit_plan_add_chain(plan, 0u, p2, p3);
                    edit_plan_add_chain(plan, 0u, p3, p0);
                } else if (m == 20 || m == 36) {
                    idx = 11u;
                    int32_t p0 = dc_type7_clip_3p_sex(sl, 11u);
                    int32_t p1 = dc_type7_clip_3p_sex(sl, 12u);
                    int32_t sh = dc_type7_clip_3p_sex(sl, 16u);
                    nc = sh;
                    edit_plan_add_chain(plan, 0u, p0, p1);
                    edit_plan_add_chain(plan, 0u, p1, sh);
                    edit_plan_add_chain(plan, 0u, sh, p1);
                } else if (m == 21 || m == 37) {
                    idx = 17u;
                    int32_t g0 = dc_type7_clip_3p_sex(sl, 17u);
                    int32_t g1 = dc_type7_clip_3p_sex(sl, 18u);
                    int32_t g2 = dc_type7_clip_3p_sex(sl, 19u);
                    int32_t g3 = dc_type7_clip_3p_sex(sl, 20u);
                    int32_t g4 = dc_type7_clip_3p_sex(sl, 21u);
                    nc = g4;
                    edit_plan_add_loop(plan, 0u, g1, -1);
                    edit_plan_add_chain(plan, 0u, g0, g1);
                    edit_plan_add_chain(plan, 0u, g1, g2);
                    edit_plan_add_chain(plan, 0u, g2, g3);
                    edit_plan_add_chain(plan, 0u, g3, g4);
                    edit_plan_add_chain(plan, 0u, g4, g3);
                } else if (m == 30) {
                    idx = 24u;
                    nc = dc_type7_clip_3p_sex(sl, 25u);
                    edit_plan_add_chain(plan, 0u, dc_type7_clip_3p_sex(sl, 24u), nc);
                    edit_plan_add_loop(plan, 0u, nc, 0);
                } else if (m == 31 || m == 32 || m == 33) {
                    idx = 29u;
                    nc = dc_type7_clip_3p_sex(sl, 31u);
                } else if (m == 34) {
                    idx = 32u;
                    nc = dc_type7_clip_3p_sex(sl, 34u);
                }
                plan->is_looping = pl->is_looping;
                plan->loop_target = pl->loop_target;
                plan->body_clip[0] = dc_type7_clip_3p_sex(sl, idx);
                if (plan->body_clip[0] < 0) plan->body_clip[0] = 1;
                plan->body_next_clip[0] = nc;
            }
        }
    } else if (st->edit_mode == DC_EDIT_MODE_4P) {
        if (m >= 40 && m <= 67) {
            /* 0x005da420: 4P Oral Rig (en00_08.xa + en00_05..07.xa). */
            pl->use_oral_rig = 1u;
            plan->use_oral_rig = 1u;
            int32_t c0 = 1, nc = -1;
            switch (m) {
                case 40: pl->oral_pos = 0u; c0 = dc_type7_clip_4p_oral(0u, 0u); break;
                case 41: pl->oral_pos = 0u; c0 = dc_type7_clip_4p_oral(0u, 1u); nc = dc_type7_clip_4p_oral(0u, 2u); break;
                case 50: pl->oral_pos = 1u; c0 = dc_type7_clip_4p_oral(1u, 0u); break;
                case 51: pl->oral_pos = 1u; c0 = dc_type7_clip_4p_oral(1u, 1u); nc = dc_type7_clip_4p_oral(1u, 2u); break;
                case 60: c0 = 18; break;
                case 61: c0 = 19; nc = 21; break;
                case 62: c0 = 25; nc = 27; break;
                case 63:
                    c0 = 22; nc = 24;
                    for (uint8_t b = 0u; b < 4u; ++b) edit_plan_add_loop(plan, b, 22, -1);
                    break;
                case 67:
                    c0 = 29; nc = 31;
                    for (uint8_t b = 0u; b < 4u; ++b) edit_plan_add_loop(plan, b, 30, -1);
                    break;
                default: c0 = 1; break;
            }
            if (c0 == 1 || c0 == 9 || c0 == 18) {
                for (uint8_t b = 0u; b < 4u; ++b) edit_plan_add_loop(plan, b, c0, 0);
            }
            if (nc == 3 || nc == 11) {
                for (uint8_t b = 0u; b < 4u; ++b) edit_plan_add_loop(plan, b, nc, 0);
            }
            plan->is_looping = pl->is_looping;
            plan->loop_target = pl->loop_target;
            for (uint8_t b = 0u; b < 4u; ++b) {
                plan->body_clip[b] = c0;
                plan->body_next_clip[b] = nc;
            }
        } else {
            if (m == 2 || m == 3 || m == 12) {
                uint8_t th = (step->param2 >= 0 && step->param2 < 3) ? (uint8_t)step->param2 : DC_EDIT_HEROINE_AOI;
                uint8_t sl = heroine_to_4p_slot(th);
                if (m == 12) {
                    pl->active_slot = (int8_t)sl;
                    pl->active_heroine = th;
                    pl->vibe_mask &= (uint8_t)~(1u << sl);
                    pl->hole = (step->param1 == 1) ? 1u : 0u;
                    plan->update_cam_pivot = 1u;
                    plan->cam_target_heroine = th;
                } else if (m == 2) {
                    pl->vibe_mask |= (uint8_t)(1u << sl);
                } else {
                    pl->vibe_mask &= (uint8_t)~(1u << sl);
                }
            } else if (m == 4) {
                pl->vibe_fast = 1u;
            } else if (m == 5) {
                pl->vibe_fast = 0u;
            }

            uint8_t sl = (pl->active_slot >= 0 && pl->active_slot < 3) ? (uint8_t)pl->active_slot : 1u;
            uint8_t hb = (uint8_t)(1u + sl);
            int32_t idx = 1, next_idx = -1;
            if (m == 6) { idx = 1; pl->is_looping = 1u; pl->loop_target = 2u; }
            else if (m == 7) { idx = 10; pl->is_looping = 1u; pl->loop_target = 2u; }
            else if (m == 8) { idx = 39; pl->is_looping = 1u; pl->loop_target = 2u; }
            else if (m == 9) { idx = 50; pl->is_looping = 1u; pl->loop_target = 2u; }
            else if (m == 12) { idx = pl->hole ? 6 : 2; next_idx = pl->hole ? 9 : 5; }
            else if (m == 18) idx = 54;
            else if (m == 19 || m == 35) {
                int32_t b = (m == 35) ? 40 : 11;
                idx = b; next_idx = b + 3;
                for (int k = 0; k < 4; ++k) {
                    int f = b + k, t = b + ((k + 1) & 3);
                    edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)f), dc_type7_clip_4p_sex(sl, (uint32_t)t));
                    edit_plan_add_chain(plan, hb, f, t);
                }
            } else if (m == 20 || m == 36) {
                int32_t b = (m == 36) ? 40 : 11;
                int32_t sh = (m == 36) ? 45 : 16;
                idx = b; next_idx = sh;
                edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)b), dc_type7_clip_4p_sex(sl, (uint32_t)(b + 1)));
                edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)(b + 1)), dc_type7_clip_4p_sex(sl, (uint32_t)sh));
                edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)sh), dc_type7_clip_4p_sex(sl, (uint32_t)(b + 1)));
                edit_plan_add_chain(plan, hb, b, b + 1);
                edit_plan_add_chain(plan, hb, b + 1, sh);
                edit_plan_add_chain(plan, hb, sh, b + 1);
            } else if (m == 21 || m == 37) {
                int32_t gb = (m == 37) ? 46 : 17;
                idx = gb; next_idx = gb + 4;
                edit_plan_add_loop(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)(gb + 1)), -1);
                edit_plan_add_loop(plan, hb, gb + 1, -1);
                for (int k = 0; k < 4; ++k) {
                    edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)(gb + k)), dc_type7_clip_4p_sex(sl, (uint32_t)(gb + k + 1)));
                    edit_plan_add_chain(plan, hb, gb + k, gb + k + 1);
                }
                edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, (uint32_t)(gb + 4)), dc_type7_clip_4p_sex(sl, (uint32_t)(gb + 3)));
                edit_plan_add_chain(plan, hb, gb + 4, gb + 3);
            } else if (m == 30) {
                idx = 24; next_idx = 26;
                edit_plan_add_loop(plan, 0u, dc_type7_clip_4p_sex(sl, 26u), 0);
                edit_plan_add_loop(plan, hb, 26, 0);
            } else if (m == 31) {
                idx = 27; next_idx = 29;
                edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, 28u), dc_type7_clip_4p_sex(sl, 29u));
                edit_plan_add_chain(plan, hb, 28, 29);
            } else if (m == 32) {
                idx = 32; next_idx = 34;
                edit_plan_add_chain(plan, 0u, dc_type7_clip_4p_sex(sl, 33u), dc_type7_clip_4p_sex(sl, 34u));
                edit_plan_add_chain(plan, hb, 33, 34);
            } else if (m == 33) {
                idx = 35; next_idx = 37;
            } else if (m == 34) {
                idx = 30; next_idx = 31;
            }
            plan->is_looping = pl->is_looping;
            plan->loop_target = pl->loop_target;
            fill_4p_edit_clips(pl, idx, next_idx, plan);
        }
    } else {
        /* Mode 0 (1P Resistance, %cn00_04.xa in RPP_05.pp) and Mode 2 (2P Sub-Male, %cn00_08.xa in RPP_06.pp). */
        bool m0 = (st->edit_mode == DC_EDIT_MODE_1P_RESIST);
        int32_t clip = 1, nc = -1;
        switch (m) {
            case 6:  clip = 1; pl->is_looping = 1u; pl->loop_target = 2u; break;
            case 7:  clip = 10; pl->is_looping = 1u; pl->loop_target = 2u; break;
            case 8:  clip = m0 ? 39 : 38; pl->is_looping = 1u; pl->loop_target = 2u; break;
            case 9:  clip = m0 ? 55 : 53; pl->is_looping = 1u; pl->loop_target = 2u; break;
            case 12:
                pl->hole = (step->param1 == 1) ? 1u : 0u;
                clip = pl->hole ? 6 : 2;
                nc = pl->hole ? 9 : 5;
                break;
            case 19:
                clip = 11; nc = 14;
                edit_plan_add_chain(plan, 0u, 11, 12);
                edit_plan_add_chain(plan, 0u, 12, 13);
                edit_plan_add_chain(plan, 0u, 13, 14);
                edit_plan_add_chain(plan, 0u, 14, 11);
                break;
            case 20:
                clip = 11; nc = m0 ? 16 : 15;
                edit_plan_add_chain(plan, 0u, 11, 12);
                edit_plan_add_chain(plan, 0u, 12, nc);
                edit_plan_add_chain(plan, 0u, nc, 12);
                break;
            case 21: {
                int32_t g0 = m0 ? 17 : 16;
                clip = g0; nc = g0 + 4;
                edit_plan_add_loop(plan, 0u, g0 + 1, -1);
                edit_plan_add_chain(plan, 0u, g0 + 0, g0 + 1);
                edit_plan_add_chain(plan, 0u, g0 + 1, g0 + 2);
                edit_plan_add_chain(plan, 0u, g0 + 2, g0 + 3);
                edit_plan_add_chain(plan, 0u, g0 + 3, g0 + 4);
                edit_plan_add_chain(plan, 0u, g0 + 4, g0 + 3);
                break;
            }
            case 30:
                clip = m0 ? 24 : 23;
                nc = m0 ? 26 : 25;
                edit_plan_add_loop(plan, 0u, nc, 0);
                break;
            case 31:
                clip = m0 ? 27 : 26;
                nc = m0 ? 29 : 28;
                break;
            case 32:
                clip = 32; nc = 34;
                break;
            case 33:
                clip = 35; nc = 37;
                break;
            case 34:
                clip = m0 ? 30 : 29;
                nc = m0 ? 32 : 31;
                break;
            case 35: {
                int32_t b = m0 ? 40 : 39;
                clip = b; nc = b + 3;
                edit_plan_add_chain(plan, 0u, b + 0, b + 1);
                edit_plan_add_chain(plan, 0u, b + 1, b + 2);
                edit_plan_add_chain(plan, 0u, b + 2, b + 3);
                edit_plan_add_chain(plan, 0u, b + 3, b + 0);
                break;
            }
            case 36: {
                int32_t b = m0 ? 40 : 39;
                int32_t sh = m0 ? 45 : 43;
                clip = b; nc = sh;
                edit_plan_add_chain(plan, 0u, b + 0, b + 1);
                edit_plan_add_chain(plan, 0u, b + 1, sh);
                edit_plan_add_chain(plan, 0u, sh, b + 1);
                break;
            }
            case 37: {
                int32_t g0 = m0 ? 46 : 44;
                clip = g0; nc = g0 + 4;
                edit_plan_add_loop(plan, 0u, g0 + 1, -1);
                edit_plan_add_chain(plan, 0u, g0 + 0, g0 + 1);
                edit_plan_add_chain(plan, 0u, g0 + 1, g0 + 2);
                edit_plan_add_chain(plan, 0u, g0 + 2, g0 + 3);
                edit_plan_add_chain(plan, 0u, g0 + 3, g0 + 4);
                edit_plan_add_chain(plan, 0u, g0 + 4, g0 + 3);
                break;
            }
            default: clip = 1; break;
        }
        plan->is_looping = pl->is_looping;
        plan->loop_target = pl->loop_target;
        plan->body_clip[0] = clip;
        plan->body_next_clip[0] = nc;
    }

    choose_edit_voice_and_se(pl, st, m, plan);
}

dc_status dc_edit_player_init(dc_edit_player *player, const dc_edit_state *state,
    dc_edit_step_plan *first_plan) {
    if (!player || !state) return DC_ARGUMENT;
    if (state->step_count < 1) return DC_RANGE;

    memset(player, 0, sizeof(*player));
    player->edit_mode = state->edit_mode;
    player->map_id = dc_edit_map_id_from_index(state->map_idx);
    player->pose_state = (state->map_idx == 3 || state->map_idx == 7) ? 0u : 4u;
    player->active_heroine = combo_primary_heroine(state->combo_idx);
    player->active_slot = (state->edit_mode == DC_EDIT_MODE_4P) ? 1 : 0;
    player->base_speed = 1.0f;

    for (uint8_t h = 0; h < 3u; ++h) {
        for (int c = 0; c < 6; ++c) player->cur_cloth[h][c] = state->init_cloth[h][c];
    }

    dc_edit_step_plan local_plan;
    build_step_plan(player, state, first_plan ? first_plan : &local_plan);
    return DC_OK;
}

dc_status dc_edit_player_on_clip_end(dc_edit_player *player, const dc_edit_state *state,
    dc_edit_step_plan *out_plan, uint8_t *out_advanced) {
    if (!player || !state) return DC_ARGUMENT;
    if (out_advanced) *out_advanced = 0u;
    if (player->finished || player->paused) return DC_OK;

    if (player->is_looping) {
        player->loops_done++;
        if (player->loops_done < player->loop_target) return DC_OK;
    }

    player->cur_step++;
    if (out_advanced) *out_advanced = 1u;
    dc_edit_step_plan local_plan;
    build_step_plan(player, state, out_plan ? out_plan : &local_plan);
    return DC_OK;
}

dc_status dc_edit_player_skip_step(dc_edit_player *player, const dc_edit_state *state,
    dc_edit_step_plan *out_plan) {
    if (!player || !state) return DC_ARGUMENT;
    if (player->finished) {
        if (out_plan) {
            memset(out_plan, 0, sizeof(*out_plan));
            out_plan->finished = 1u;
        }
        return DC_OK;
    }
    player->cur_step++;
    dc_edit_step_plan local_plan;
    build_step_plan(player, state, out_plan ? out_plan : &local_plan);
    return DC_OK;
}

dc_status dc_edit_player_toggle_pause(dc_edit_player *player) {
    if (!player) return DC_ARGUMENT;
    player->paused ^= 1u;
    return DC_OK;
}

dc_status dc_edit_player_set_ff(dc_edit_player *player, uint8_t ff_mode) {
    if (!player) return DC_ARGUMENT;
    if (ff_mode > 3u) return DC_RANGE;
    player->ff_mode = ff_mode;
    return DC_OK;
}

dc_status dc_edit_player_cycle_ff(dc_edit_player *player) {
    if (!player) return DC_ARGUMENT;
    player->ff_mode = (uint8_t)((player->ff_mode + 1u) % 4u);
    return DC_OK;
}
