import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from native_core import (
    AnimationClip,
    AnimationTiming,
    C,
    PPArchive,
    Type7Assets,
    Type7ExitOutcome,
    Type7Menu,
    Type7Plan,
    Type7State,
    XXModel,
    library,
)
from original_flow_cases import FlowState, Masks, Meta, STRIDE, library as flow_library


def _dec_xx(bs: bytes) -> str:
    return bytes((~b) & 0xFF for b in bs).rstrip(b"\0").decode("ascii", "ignore")


class NativeType7Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()
        cls.flow_lib = flow_library()
        cls.data_dir = ROOT / "Data"
        cls.has_data = (cls.data_dir / "RPP_05.pp").exists()
        cls.pp_entries = {}
        cls.map_nodes = {}
        cls.xa_valid_clips = {}
        if cls.has_data:
            for k in (2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14):
                p = cls.data_dir / f"RPP_{k:02d}.pp"
                with PPArchive(p) as pp:
                    cls.pp_entries[f"RPP_{k:02d}.pp"] = {
                        pp.entry(i).name_bytes.decode("ascii", "ignore")
                        for i in range(pp.count)
                    }
            for arch_name in ("RPP_05.pp", "RPP_06.pp"):
                with PPArchive(cls.data_dir / arch_name) as pp:
                    for i in range(pp.count):
                        nm = pp.entry(i).name_bytes.decode("ascii", "ignore")
                        if nm.endswith(".xa"):
                            raw = pp.read(i)
                            clips = (AnimationClip * 512)()
                            timings = (AnimationTiming * 512)()
                            cls.lib.dc_xa_load_clips(raw, len(raw), clips, timings, 512)
                            cls.xa_valid_clips[(arch_name, nm)] = {
                                c for c in range(512)
                                if clips[c].last_frame > clips[c].first_frame or clips[c].last_frame > 0
                            }
            with PPArchive(cls.data_dir / "RPP_10.pp") as pp:
                for i in range(pp.count):
                    nm = pp.entry(i).name_bytes.decode("ascii", "ignore")
                    if nm.startswith("mm00_") and nm.endswith(".xx"):
                        with XXModel(pp.read(i)) as xx:
                            inf = xx.info()
                            cls.map_nodes[nm] = {
                                _dec_xx(xx.span(xx.at("node", n).name))
                                for n in range(inf.nodes)
                            }

    def test_selector_3p_and_4p_pregnancy_admission(self):
        st = FlowState()
        meta = Meta(chapter=24, scene_type=2, previous_type=0, map=0, stage=0, selector0=255, selector1=255, script_frame=0)
        self.assertEqual(self.flow_lib.dc_flow_state_init(C.byref(st), C.byref(meta)), 0)
        for h in range(3):
            st.raw[h * STRIDE + 0x23] = 2  # all 3 conquered
        masks = Masks()
        self.assertEqual(self.flow_lib.dc_flow_selector_admission(C.byref(st), C.byref(masks)), 0)
        self.assertEqual(masks.disabled_categories & (1 << 5), 0)
        # 0x0051b208: 1 pregnant heroine leaves 4P (Cat 5) enabled; 2 pregnant heroines locks out 3P (Cat 4)!
        st.raw[1 * STRIDE + 0x22] = 5
        self.assertEqual(self.flow_lib.dc_flow_selector_admission(C.byref(st), C.byref(masks)), 0)
        self.assertEqual(masks.disabled_categories & (1 << 5), 0)
        self.assertEqual(masks.disabled_categories & (1 << 4), 0)
        st.raw[0 * STRIDE + 0x22] = 5
        self.assertEqual(self.flow_lib.dc_flow_selector_admission(C.byref(st), C.byref(masks)), 0)
        self.assertNotEqual(masks.disabled_categories & (1 << 4), 0)

    def test_canonical_slot_normalization_and_tables(self):
        for (a, b), expected in (((0, 2), (2, 0)), ((1, 0), (0, 1)), ((2, 1), (1, 2))):
            st = Type7State()
            plan = Type7Plan()
            self.assertEqual(self.lib.dc_type7_init(C.byref(st), 2, 0, a, b, 0, 7, C.byref(plan)), 0)
            self.assertEqual((st.slots[0], st.slots[1]), expected)
            self.assertEqual(st.active_slot, -1)
            self.assertEqual(plan.body_clip[0], 1)

        st4 = Type7State()
        plan4 = Type7Plan()
        self.assertEqual(self.lib.dc_type7_init(C.byref(st4), 4, 4, 0, 1, 2, 7, C.byref(plan4)), 0)
        self.assertEqual(tuple(st4.slots), (2, 0, 1))
        self.assertEqual(st4.active_slot, 1)
        self.assertEqual(plan4.body_count, 4)
        self.assertEqual(tuple(plan4.body_clip), (58, 58, 1, 58))

        # Toilet map (3) allowed only in 2P, rejected in 3P/4P/5P
        self.assertEqual(self.lib.dc_type7_init(C.byref(st4), 0, 3, 0, 0, 0, 0, None), 0)
        self.assertNotEqual(self.lib.dc_type7_init(C.byref(st4), 2, 3, 0, 1, 0, 7, None), 0)
        self.assertNotEqual(self.lib.dc_type7_init(C.byref(st4), 4, 3, 0, 1, 2, 7, None), 0)
        self.assertNotEqual(self.lib.dc_type7_init(C.byref(st4), 6, 3, 0, 0, 0, 0, None), 0)

    def test_all_assets_icons_and_voices_exist_in_pp_archives(self):
        if not self.has_data:
            self.skipTest("Data/*.pp not present")

        configs = []
        for m in (0, 1, 3, 4, 5, 7, 8):
            for h in range(3):
                configs.append((0, m, h, h, h))
        for m in (0, 1, 4, 5, 7, 8):
            for h in range(3):
                configs.append((6, m, h, h, h))
            for a, b in ((0, 1), (1, 2), (2, 0)):
                configs.append((2, m, a, b, 0))
            configs.append((4, m, 2, 0, 1))

        for init_sub, map_id, s0, s1, s2 in configs:
            for conq_mask in (0, 7):
                st = Type7State()
                plan = Type7Plan()
                self.assertEqual(
                    self.lib.dc_type7_init(C.byref(st), init_sub, map_id, s0, s1, s2, conq_mask, C.byref(plan)),
                    0,
                )
                sub_modes = [init_sub]
                if init_sub in (0, 2, 4):
                    sub_modes.append(init_sub + 1)

                for sm in sub_modes:
                    st.sub_mode = sm
                    if sm == 1:
                        st.rig_mode = 6
                    assets = Type7Assets()
                    self.assertEqual(self.lib.dc_type7_resolve_assets(C.byref(st), C.byref(assets)), 0)
                    arch = assets.body_archive.decode()
                    for b in range(assets.body_count):
                        bxx = assets.body_xx[b].value.decode()
                        bpl = assets.body_plst[b].value.decode()
                        bxa = assets.body_xa[b].value.decode()
                        self.assertIn(bxx, self.pp_entries[arch], f"missing {bxx} in {arch}")
                        if bpl:
                            self.assertIn(bpl, self.pp_entries[arch], f"missing {bpl} in {arch}")
                        self.assertIn(bxa, self.pp_entries[arch], f"missing {bxa} in {arch}")

                    for hi in range(assets.head_count):
                        self.assertIn(assets.head_xx[hi].value.decode(), self.pp_entries["RPP_09.pp"])
                        self.assertIn(assets.head_xa[hi].value.decode(), self.pp_entries["RPP_09.pp"])
                        self.assertIn(assets.head_eyes[hi].value.decode(), self.pp_entries["RPP_04.pp"])
                        self.assertIn(assets.head_neck[hi].value.decode(), self.pp_entries["RPP_04.pp"])

                    self.assertIn(assets.char_light_xl.decode(), self.pp_entries["RPP_07.pp"])
                    self.assertIn(assets.cam_file.decode(), self.pp_entries["RPP_03.pp"])
                    map_xx = f"mm00_{map_id:02d}.xx"
                    ap = assets.anchor_primary.decode()
                    af = assets.anchor_fallback.decode()
                    # Toilet oral falls back to yuka_2b if isu absent; check primary/fallback or yuka_2b_a
                    nodes = self.map_nodes[map_xx]
                    self.assertTrue(
                        ap in nodes or af in nodes or "m_Nn_yuka_2b_a" in nodes or "m_Nn_yuka_2f_a" in nodes,
                        f"no anchor ({ap}/{af}) in {map_xx}",
                    )

                    # Verify all 4 radial menus' icons exist in RPP_02.pp
                    for hub in (1, 2, 3, 4):
                        menu = Type7Menu()
                        self.assertEqual(self.lib.dc_type7_build_menu(C.byref(st), hub, C.byref(menu)), 0)
                        for idx in range(menu.count):
                            stem = menu.items[idx].stem.decode()
                            self.assertIn(f"{stem}S.ema", self.pp_entries["RPP_02.pp"])
                            self.assertIn(f"{stem}N.ema", self.pp_entries["RPP_02.pp"])

                    # Verify voice stem exists in heroine's voice archive (RPP_11/12/13)
                    vh = C.c_uint8()
                    vbuf = C.create_string_buffer(32)
                    self.assertEqual(self.lib.dc_type7_voice_stem(C.byref(st), C.byref(vh), vbuf), 0)
                    voice_pp = {0: "RPP_12.pp", 1: "RPP_13.pp", 2: "RPP_11.pp"}[vh.value]
                    self.assertIn(vbuf.value.decode(), self.pp_entries[voice_pp])

    def test_right_click_paging_oral_swallow_and_exit_badges(self):
        st = Type7State()
        plan = Type7Plan()
        # 2P unconquered Aoi on Hotel (map 4 -> rig_mode 2)
        self.assertEqual(self.lib.dc_type7_init(C.byref(st), 0, 4, 2, 2, 2, 0, C.byref(plan)), 0)
        self.assertEqual(st.rig_mode, 2)
        self.assertEqual(plan.body_clip[0], 102)

        # Right-click in P_chara cycles chara_page 0 -> 1 -> 2 -> 0
        consumed = C.c_uint8()
        self.lib.dc_type7_right_click_menu(C.byref(st), 1, C.byref(consumed))
        self.assertEqual((consumed.value, st.chara_page), (1, 1))
        self.lib.dc_type7_right_click_menu(C.byref(st), 1, C.byref(consumed))
        self.assertEqual((consumed.value, st.chara_page), (1, 2))

        # Switch to 2P Oral (item 4 = M_h017) via fade, then complete fade -> Oral -> Edge -> Mouth-Hold -> Swallow!
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 4, C.byref(plan)), 0)
        self.assertEqual((plan.start_fade, plan.fade_kind), (1, 1))
        self.assertEqual(self.lib.dc_type7_complete_fade(C.byref(st), C.byref(plan)), 0)
        self.assertEqual((st.sub_mode, plan.body_clip[0]), (1, 1))

        # Trigger Edge (item 3 = M_f008) -> In-mouth finish (item 0 = M_f008 -> 101..111) -> Swallow (item 0 = M_f010 -> 112)
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 3, C.byref(plan)), 0)
        self.assertEqual(plan.body_clip[0], 107)
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 0, C.byref(plan)), 0)
        self.assertEqual((plan.body_clip[0], plan.body_next_clip[0]), (101, 111))
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 0, C.byref(plan)), 0)
        self.assertEqual((plan.body_clip[0], st.metrics[2].swallowed), (112, 2))

        # Strip clothing in P_fuku (5 slots for Aoi) so stripped_flags >= 6 -> earns naked badge (badge 6)!
        for slot_idx in range(4):
            self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 2, slot_idx, C.byref(plan)), 0)
        self.assertGreaterEqual(st.metrics[2].stripped_flags, 6)

        # Commit exit on unconquered Aoi (raw+0x23 == 1)
        flow = FlowState()
        meta = Meta(chapter=24, scene_type=7, previous_type=2, map=4, stage=2, selector0=255, selector1=255, script_frame=0)
        self.flow_lib.dc_flow_state_init(C.byref(flow), C.byref(meta))
        flow.raw[2 * STRIDE + 0x23] = 1
        outcome = Type7ExitOutcome()
        self.assertEqual(self.lib.dc_type7_commit_exit(C.byref(st), C.byref(flow), C.byref(outcome)), 0)
        self.assertEqual(flow.raw[2 * STRIDE + 0x00], 1)  # oral swallow flag!
        self.assertEqual(flow.raw[2 * STRIDE + 0x34], 1)  # 2P menstrual init!
        self.assertEqual(outcome.badge_awarded, 1)
        self.assertEqual(outcome.badge_heroine, 2)
        self.assertEqual(outcome.badge_index, 6)
        self.assertEqual(outcome.exit_voice.decode(), "aeg014_01.wav")
        if self.has_data:
            self.assertIn("aeg014_01.wav", self.pp_entries["RPP_11.pp"])

        # 3P right-click on P_fuku and P_cam + 3P exit does NOT initialize menstrual cycle
        st3 = Type7State()
        self.lib.dc_type7_init(C.byref(st3), 2, 0, 0, 1, 0, 7, C.byref(plan))
        self.lib.dc_type7_right_click_menu(C.byref(st3), 2, C.byref(consumed))
        self.assertEqual((consumed.value, st3.fuku_slot_cursor), (1, 1))
        self.lib.dc_type7_right_click_menu(C.byref(st3), 3, C.byref(consumed))
        self.assertEqual((consumed.value, st3.cam_slot_cursor), (1, 1))
        cam_menu = Type7Menu()
        self.lib.dc_type7_build_menu(C.byref(st3), 3, C.byref(cam_menu))
        self.assertEqual(cam_menu.items[0].stem.decode(), "M_c021")  # Manaka portrait!

        flow3 = FlowState()
        self.flow_lib.dc_flow_state_init(C.byref(flow3), C.byref(meta))
        flow3.raw[0 * STRIDE + 0x23] = 2
        flow3.raw[1 * STRIDE + 0x23] = 2
        flow3.raw[2 * STRIDE + 0x23] = 2
        self.assertEqual(self.lib.dc_type7_commit_exit(C.byref(st3), C.byref(flow3), C.byref(outcome)), 0)
        self.assertEqual(flow3.raw[0 * STRIDE + 0x34], 0)  # 3P skips menstrual init!

    def test_tick_arousal_10s_mouth_hold_and_post_9_badge_conquest(self):
        st = Type7State()
        plan = Type7Plan()
        self.assertEqual(self.lib.dc_type7_init(C.byref(st), 1, 4, 2, 2, 2, 0, C.byref(plan)), 0)
        # Start piston in 2P Oral -> tick advances arousal + stroke SE, then Edge -> In-Mouth -> 111 mouth-hold auto-spits (114) at 10s
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 1, C.byref(plan)), 0)
        ev = Type7Plan()
        self.assertEqual(self.lib.dc_type7_tick(C.byref(st), 200, plan.body_clip[0], 0.55, C.byref(ev)), 0)
        self.assertGreater(st.arousal[2], 0.0)
        self.assertTrue(ev.se_name.startswith(b"se3"))
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 3, C.byref(plan)), 0)  # Edge
        self.assertEqual(self.lib.dc_type7_select_menu_item(C.byref(st), 1, 0, C.byref(plan)), 0)  # Finish in mouth -> 101..111
        self.assertEqual(st.metrics[2].oral_in_ejac, 1)
        for _ in range(40):
            self.assertEqual(self.lib.dc_type7_tick(C.byref(st), 250, 111, 0.5, C.byref(ev)), 0)
        self.assertEqual(ev.body_clip[0], 114)  # Unconquered heroine spits after 10s mouth hold
        self.assertEqual(st.metrics[2].swallowed, 1)

        # Pre-populate 8 of 9 badges; session satisfies remaining badge -> awards 9th badge WITHOUT immediate progress=2
        flow = FlowState()
        meta = Meta(chapter=24, scene_type=7, previous_type=2, map=4, stage=2, selector0=255, selector1=255, script_frame=0)
        self.flow_lib.dc_flow_state_init(C.byref(flow), C.byref(meta))
        r2 = 2 * STRIDE
        flow.raw[r2 + 0x23] = 1
        for b in range(9):
            flow.raw[r2 + 0x03 + b] = 0 if b == 6 else 1
        flow.raw[r2 + 0x02] = 8
        for slot_idx in range(4):
            self.lib.dc_type7_select_menu_item(C.byref(st), 2, slot_idx, C.byref(plan))
        outcome = Type7ExitOutcome()
        self.assertEqual(self.lib.dc_type7_commit_exit(C.byref(st), C.byref(flow), C.byref(outcome)), 0)
        self.assertEqual((outcome.badge_awarded, outcome.badge_index), (1, 6))
        self.assertEqual(flow.raw[r2 + 0x02], 9)
        self.assertEqual(flow.raw[r2 + 0x23], 1)  # Still 1 on the session that earns the 9th badge!

        # Next climaxed 2P session when all 9 badges were ALREADY owned promotes progress -> 2 + aeg002_01.wav!
        outcome2 = Type7ExitOutcome()
        self.assertEqual(self.lib.dc_type7_commit_exit(C.byref(st), C.byref(flow), C.byref(outcome2)), 0)
        self.assertEqual(flow.raw[r2 + 0x23], 2)
        self.assertEqual(outcome2.promoted_conquest_mask, 1 << 2)
        self.assertEqual(outcome2.exit_voice, b"aeg002_01.wav")


if __name__ == "__main__":
    unittest.main()
