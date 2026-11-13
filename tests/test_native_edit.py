import ctypes as C
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import native_core as nc  # noqa: E402


class NativeEditTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = nc.library()
        cls.data_dir = ROOT / "Data"
        cls.archive_entries = {}
        if cls.data_dir.is_dir():
            for pp in ("RPP_01.pp", "RPP_02.pp", "RPP_03.pp", "RPP_04.pp", "RPP_05.pp",
                       "RPP_06.pp", "RPP_07.pp", "RPP_08.pp", "RPP_09.pp", "RPP_10.pp",
                       "RPP_11.pp", "RPP_12.pp", "RPP_13.pp", "RPP_14.pp"):
                p = cls.data_dir / pp
                if p.is_file():
                    with nc.PPArchive(p) as ar:
                        cls.archive_entries[pp] = {
                            ar.entry(i).name_bytes.decode("ascii", "ignore")
                            for i in range(ar.count)
                        }

    def test_fresh_init_and_default_heroine_constraints(self):
        st = nc.EditState()
        self.assertEqual(self.lib.dc_edit_init(C.byref(st)), 0)
        self.assertEqual(st.combo_idx, 0)
        self.assertEqual(st.map_idx, 0)
        self.assertEqual(st.edit_mode, 1)
        self.assertEqual(st.active_mask, 0x4)
        self.assertEqual(st.chara_heroine, 2)
        self.assertEqual(st.step_count, 1)
        self.assertEqual(st.steps[0].cat_idx, 2)
        self.assertEqual(st.steps[0].motion_id, 6)
        self.assertEqual(st.steps[0].param1, 0)
        self.assertEqual(st.steps[0].param2, -1)

        # Aoi: virgin, pubic=1, koukan(1)=1 locked; Yuko: non_virgin=1 locked, pubic=0, tijoku(0)=1 locked
        self.assertEqual((st.non_virgin[0], st.pubic_hair[0], st.badges[0][1]), (0, 1, 1))
        self.assertEqual((st.non_virgin[1], st.pubic_hair[1], st.badges[1][0]), (1, 0, 1))
        self.assertEqual((st.non_virgin[2], st.pubic_hair[2]), (0, 1))

        # Yuko virgin=0 rejected, locked badges rejected
        self.assertNotEqual(self.lib.dc_edit_set_virgin(C.byref(st), 1, 0), 0)
        self.assertNotEqual(self.lib.dc_edit_toggle_badge(C.byref(st), 0, 1), 0)
        self.assertNotEqual(self.lib.dc_edit_toggle_badge(C.byref(st), 1, 0), 0)
        self.assertEqual(self.lib.dc_edit_toggle_badge(C.byref(st), 2, 3), 0)
        self.assertEqual(st.badges[2][3], 1)

    def test_autoname_and_edt_binary_layout_roundtrip(self):
        buf_name = C.create_string_buffer(64)
        self.assertEqual(self.lib.dc_edit_format_autoname(0, 0, 0, buf_name), 0)
        self.assertEqual(buf_name.value, b"2manastation_000.edt")
        self.assertEqual(self.lib.dc_edit_format_autoname(6, 6, 7, buf_name), 0)
        self.assertEqual(buf_name.value, b"3m&ypark2_007.edt")
        self.assertEqual(self.lib.dc_edit_format_autoname(9, 3, 42, buf_name), 0)
        self.assertEqual(buf_name.value, b"4photel_042.edt")

        st = nc.EditState()
        self.lib.dc_edit_init(C.byref(st))
        self.lib.dc_edit_set_virgin(C.byref(st), 2, 1)
        self.lib.dc_edit_set_pregnancy(C.byref(st), 2, 4)
        # Append M12 (insert) -> M07 (penetrated idle) -> M19 (slow) -> M75 (end)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 12)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 7)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 19)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 75)), 0)
        self.assertEqual(st.step_count, 5)

        expected_size = 150 + 12 * 5
        self.assertEqual(self.lib.dc_edit_serialized_size(C.byref(st)), expected_size)
        raw = C.create_string_buffer(expected_size)
        written = C.c_size_t()
        self.assertEqual(self.lib.dc_edit_serialize(C.byref(st), raw, expected_size, C.byref(written)), 0)
        self.assertEqual(written.value, expected_size)

        data = raw.raw
        self.assertEqual(struct.unpack_from("<iii", data, 0), (0, 0, 1))
        self.assertEqual(data[0x19 + 2 * 14 + 1], 4)  # Manaka pregnancy at 0x19 + 2*14 + 1
        self.assertEqual(data[0x43], 0x4)             # active_mask at 0x43
        self.assertEqual(struct.unpack_from("<i", data, 0x92)[0], 5)

        loaded = nc.EditState()
        self.assertEqual(self.lib.dc_edit_deserialize(C.byref(loaded), raw, expected_size, b"2manastation_000.edt"), 0)
        self.assertEqual(loaded.step_count, 5)
        self.assertEqual(loaded.pregnancy[2], 4)
        self.assertEqual(loaded.steps[4].motion_id, 75)
        self.assertEqual(loaded.current_filename, b"2manastation_000.edt")

        # Truncated buffer must fail
        self.assertNotEqual(self.lib.dc_edit_deserialize(C.byref(loaded), raw, expected_size - 1, None), 0)

    def test_chara_lockouts_resistance_and_caution_modal(self):
        st = nc.EditState()
        self.lib.dc_edit_init(C.byref(st))

        # Virgin heroine cannot pick pregnancy >= 3
        self.assertNotEqual(self.lib.dc_edit_set_pregnancy(C.byref(st), 2, 3), 0)

        # Resistance locks map: Aoi->3(hotel), Yuko->5(park_hiru), Manaka->2(toilet)
        self.assertEqual(self.lib.dc_edit_set_personality(C.byref(st), 2, 0), 0)
        self.assertEqual(st.edit_mode, 0)
        self.assertEqual(st.map_idx, 2)
        cui = nc.EditCharaUI()
        self.lib.dc_edit_build_chara_ui(C.byref(st), C.byref(cui))
        self.assertEqual(cui.map_enabled_mask, 1 << 2)
        self.assertEqual(cui.pubic_enabled, 0)
        self.assertEqual(cui.badges_enabled_mask, 0)

        # Switch to 3P combo -> resistance auto-cleared to 1, toilet disabled, bote(5) disabled
        self.assertEqual(self.lib.dc_edit_set_combo(C.byref(st), 6), 0)
        self.assertEqual(st.edit_mode, 3)
        self.assertEqual(st.personality[2], 1)
        self.assertEqual(st.map_idx, 0)
        self.assertNotEqual(self.lib.dc_edit_set_map(C.byref(st), 2), 0)
        self.lib.dc_edit_set_virgin(C.byref(st), 2, 1)
        self.assertNotEqual(self.lib.dc_edit_set_pregnancy(C.byref(st), 2, 5), 0)

        # Caution modal when step_count > 1
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(3, 12)), 0)
        self.assertEqual(st.step_count, 2)
        self.assertEqual(self.lib.dc_edit_set_combo(C.byref(st), 9), 0)
        self.assertEqual(st.caution_pending, 1)
        self.assertEqual(st.combo_idx, 6)  # Not yet mutated

        # Cancel caution -> keeps 3P playlist intact
        self.assertEqual(self.lib.dc_edit_resolve_caution(C.byref(st), 0), 0)
        self.assertEqual(st.caution_pending, 0)
        self.assertEqual(st.combo_idx, 6)
        self.assertEqual(st.step_count, 2)

        # Confirm caution -> switches to 4P and resets playlist to M06
        self.assertEqual(self.lib.dc_edit_set_combo(C.byref(st), 9), 0)
        self.assertEqual(self.lib.dc_edit_resolve_caution(C.byref(st), 1), 0)
        self.assertEqual(st.combo_idx, 9)
        self.assertEqual(st.edit_mode, 4)
        self.assertEqual(st.step_count, 1)
        self.assertEqual(st.steps[0].motion_id, 6)

    def test_motion_strip_bra_lockout_pop_and_keypad(self):
        st = nc.EditState()
        self.lib.dc_edit_init(C.byref(st))
        mui = nc.EditMotionUI()
        self.lib.dc_edit_build_motion_ui(C.byref(st), C.byref(mui))
        self.assertEqual(mui.can_play_or_save, 0)
        # 0x005ff900: Manaka (combo 0, h=2) has no bra mesh (init_cloth[2][1] == -1), while Yuko (combo 1, h=1) wears bra (2) under top
        self.assertEqual(st.init_cloth[2][1], -1)
        self.assertEqual(self.lib.dc_edit_set_combo(C.byref(st), 1), 0)
        self.assertEqual(st.init_cloth[1][1], 2)

        # Append M00 (strip): bra (bit 1) must be blocked while top (slot 0) == 2
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), 0), 0)
        self.assertEqual(st.steps[1].motion_id, 0)
        self.lib.dc_edit_build_motion_ui(C.byref(st), C.byref(mui))
        self.assertEqual(mui.strip_enabled_mask & (1 << 1), 0)
        self.assertNotEqual(mui.strip_enabled_mask & (1 << 0), 0)

        # Strip top (slot 0), then append another M00 -> bra (bit 1) is now strippable!
        self.assertEqual(self.lib.dc_edit_set_strip_param(C.byref(st), 0), 0)
        self.assertEqual(st.cur_cloth[1][0], 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), 0), 0)
        self.lib.dc_edit_build_motion_ui(C.byref(st), C.byref(mui))
        self.assertNotEqual(mui.strip_enabled_mask & (1 << 1), 0)

        # Right-click pop restores step_count and clothing state
        self.assertEqual(self.lib.dc_edit_pop_last_step(C.byref(st)), 0)
        self.assertEqual(self.lib.dc_edit_pop_last_step(C.byref(st)), 0)
        self.assertEqual(st.step_count, 1)
        self.assertEqual(st.cur_cloth[1][0], 2)

        # Append M12 -> M07 -> M19 (looping) and test keypad 2-digit entry + 'C' clear + speed
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 12)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 7)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 19)), 0)
        self.assertEqual(st.steps[3].param2, 5)
        self.assertEqual(self.lib.dc_edit_keypad_press(C.byref(st), 2), 0)
        self.assertEqual(st.steps[3].param2, 2)
        self.assertEqual(self.lib.dc_edit_keypad_press(C.byref(st), 7), 0)
        self.assertEqual(st.steps[3].param2, 27)
        self.assertEqual(self.lib.dc_edit_keypad_press(C.byref(st), 10), 0)  # 'C'
        self.assertEqual(st.steps[3].param2, 1)
        self.assertEqual(self.lib.dc_edit_set_speed_param(C.byref(st), 2), 0)
        self.assertEqual(st.steps[3].param1, 2)

        # Append M75 -> enables Play/Save and produces 0 further candidates
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 75)), 0)
        self.lib.dc_edit_build_motion_ui(C.byref(st), C.byref(mui))
        self.assertEqual(mui.can_play_or_save, 1)
        self.assertEqual(mui.cand_count, 0)

    def test_all_motion_sprites_and_resolved_assets_exist_in_archives(self):
        if not self.archive_entries:
            self.skipTest("Data/*.pp archives not present")

        rpp02 = self.archive_entries["RPP_02.pp"]
        name_buf = C.create_string_buffer(32)
        for mid in range(76):
            for sel in (0, 1):
                self.assertEqual(self.lib.dc_edit_motion_sprite_name(mid, sel, name_buf), 0)
                self.assertIn(name_buf.value.decode("ascii"), rpp02)

        # Test asset resolution across all 5 Edit modes + daytime park (map_idx=5 -> map_id=6)
        configs = [
            (2, 3, 0),  # Mode 0: Aoi resistance in hotel
            (1, 5, 0),  # Mode 0: Yuko resistance in daytime park
            (0, 5, 1),  # Mode 1: Manaka 2P Kiryu in daytime park (map_id=6)
            (4, 6, 1),  # Mode 2: Yuko 2P Sub-Male in nighttime park (map_id=7)
            (6, 3, 1),  # Mode 3: 3P Manaka+Yuko in hotel
            (9, 7, 1),  # Mode 4: 4P all three in Manaka's room
        ]
        for combo, map_i, pers in configs:
            st = nc.EditState()
            self.lib.dc_edit_init(C.byref(st))
            self.lib.dc_edit_set_combo(C.byref(st), combo)
            prim_h = st.chara_heroine
            self.lib.dc_edit_set_personality(C.byref(st), prim_h, pers)
            if pers != 0:
                self.lib.dc_edit_set_map(C.byref(st), map_i)
            assets = nc.EditAssets()
            self.assertEqual(self.lib.dc_edit_resolve_assets(C.byref(st), C.byref(assets)), 0)
            self.assertIn(assets.map_xx.decode(), self.archive_entries["RPP_10.pp"])
            self.assertIn(assets.map_xl.decode(), self.archive_entries["RPP_10.pp"])
            self.assertIn(assets.bgm_name.decode(), self.archive_entries["RPP_01.pp"])
            self.assertIn(assets.cam_file.decode(), self.archive_entries["RPP_03.pp"])
            self.assertIn(assets.char_light_xl.decode(), self.archive_entries["RPP_07.pp"])
            body_ar = self.archive_entries[assets.body_archive.decode()]
            for bi in range(assets.body_count):
                self.assertIn(assets.body_xx[bi].value.decode(), body_ar)
                self.assertIn(assets.body_xa[bi].value.decode(), body_ar)
            for hi in range(assets.head_count):
                self.assertIn(assets.head_xx[hi].value.decode(), self.archive_entries["RPP_09.pp"])
                self.assertIn(assets.head_eyes[hi].value.decode(), self.archive_entries["RPP_04.pp"])

    def test_type12_player_timeline_loops_oral_skip_pause_and_ff(self):
        st = nc.EditState()
        self.lib.dc_edit_init(C.byref(st))
        # M06 (step 0) -> M00 strip top -> M01 equip glasses(6) -> M06 -> M10 oral -> M12 -> M07 -> M19(3) -> M75
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 0)), 0)
        self.assertEqual(self.lib.dc_edit_set_strip_param(C.byref(st), 0), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 1)), 0)
        self.assertEqual(self.lib.dc_edit_set_strip_param(C.byref(st), 6), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 6)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 10)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 12)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 7)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 19)), 0)
        self.assertEqual(self.lib.dc_edit_keypad_press(C.byref(st), 3), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st), self.lib.dc_edit_catalog_index_of(1, 75)), 0)

        pl = nc.EditPlayer()
        plan = nc.EditStepPlan()
        adv = C.c_uint8()
        self.assertEqual(self.lib.dc_edit_player_init(C.byref(pl), C.byref(st), C.byref(plan)), 0)
        self.assertEqual(pl.cur_step, 0)
        self.assertEqual(plan.finished, 0)

        # Skip step 0 -> consumes M00 & M01 immediately and lands on M06 (step 3)!
        self.assertEqual(self.lib.dc_edit_player_skip_step(C.byref(pl), C.byref(st), C.byref(plan)), 0)
        self.assertEqual(pl.cur_step, 3)
        self.assertEqual(plan.cloth_changed, 1)
        self.assertEqual(plan.cur_cloth[2][0], 0)
        self.assertEqual(plan.cur_acc[2][0], 1)

        # Skip to M10 foreplay caress -> stays on sex rig (use_oral_rig=0) with valid 4-part caress clip!
        self.assertEqual(self.lib.dc_edit_player_skip_step(C.byref(pl), C.byref(st), C.byref(plan)), 0)
        self.assertEqual(plan.use_oral_rig, 0)
        self.assertGreater(plan.body_clip[0], 0)
        if self.archive_entries:
            self.assertIn(plan.voice_stem.decode("ascii"), self.archive_entries["RPP_11.pp"])
            self.assertIn(plan.se_name.decode("ascii"), self.archive_entries["RPP_14.pp"])

        # Skip M10 -> M12 -> M07 -> M19 (loop=3)
        self.lib.dc_edit_player_skip_step(C.byref(pl), C.byref(st), C.byref(plan))
        if self.archive_entries:
            self.assertIn(plan.voice_stem.decode("ascii"), self.archive_entries["RPP_11.pp"])
            self.assertIn(plan.se_name.decode("ascii"), self.archive_entries["RPP_14.pp"])
        self.lib.dc_edit_player_skip_step(C.byref(pl), C.byref(st), C.byref(plan))
        self.lib.dc_edit_player_skip_step(C.byref(pl), C.byref(st), C.byref(plan))
        if self.archive_entries:
            self.assertIn(plan.voice_stem.decode("ascii"), self.archive_entries["RPP_11.pp"])
            self.assertIn(plan.se_name.decode("ascii"), self.archive_entries["RPP_14.pp"])
        self.assertEqual(st.steps[pl.cur_step].motion_id, 19)
        self.assertEqual(plan.loop_target, 3)

        # Pause blocks clip_end advancement; FF cycles 1x -> 2x -> 4x -> 8x -> 1x
        self.lib.dc_edit_player_toggle_pause(C.byref(pl))
        self.lib.dc_edit_player_on_clip_end(C.byref(pl), C.byref(st), C.byref(plan), C.byref(adv))
        self.assertEqual(pl.loops_done, 0)
        self.lib.dc_edit_player_toggle_pause(C.byref(pl))

        for expected_mult in (2.0, 4.0, 8.0, 1.0):
            self.lib.dc_edit_player_cycle_ff(C.byref(pl))
            self.assertAlmostEqual(self.lib.dc_edit_ff_multiplier(pl.ff_mode), expected_mult)

        # 3 loop completions -> 3rd advances to M75 and sets finished=1
        self.lib.dc_edit_player_on_clip_end(C.byref(pl), C.byref(st), C.byref(plan), C.byref(adv))
        self.assertEqual(adv.value, 0)
        self.lib.dc_edit_player_on_clip_end(C.byref(pl), C.byref(st), C.byref(plan), C.byref(adv))
        self.assertEqual(adv.value, 0)
        self.lib.dc_edit_player_on_clip_end(C.byref(pl), C.byref(st), C.byref(plan), C.byref(adv))
        self.assertEqual(adv.value, 1)
        self.assertEqual(plan.finished, 1)
        self.assertEqual(pl.finished, 1)

    def test_3p_vibe_and_4p_multi_body_playback(self):
        # 3P: M06 -> M12(Yuko) -> M07 -> M02(vibe attach) -> M04(vibe fast) -> M75
        st3 = nc.EditState()
        self.lib.dc_edit_init(C.byref(st3))
        self.lib.dc_edit_set_combo(C.byref(st3), 6)  # Manaka + Yuko
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st3), self.lib.dc_edit_catalog_index_of(3, 12)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st3), self.lib.dc_edit_catalog_index_of(3, 7)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st3), self.lib.dc_edit_catalog_index_of(3, 2)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st3), self.lib.dc_edit_catalog_index_of(3, 4)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st3), self.lib.dc_edit_catalog_index_of(3, 75)), 0)

        # 4P: M06 -> M12(Manaka) -> M07 -> M19 -> M75
        st4 = nc.EditState()
        self.lib.dc_edit_init(C.byref(st4))
        self.lib.dc_edit_set_combo(C.byref(st4), 9)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st4), self.lib.dc_edit_catalog_index_of(4, 12)), 0)
        self.assertEqual(self.lib.dc_edit_set_heroine_param(C.byref(st4), 2), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st4), self.lib.dc_edit_catalog_index_of(4, 7)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st4), self.lib.dc_edit_catalog_index_of(4, 19)), 0)
        self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(st4), self.lib.dc_edit_catalog_index_of(4, 75)), 0)

        pl4 = nc.EditPlayer()
        plan4 = nc.EditStepPlan()
        self.lib.dc_edit_player_init(C.byref(pl4), C.byref(st4), C.byref(plan4))
        self.assertEqual(plan4.body_count, 4)
        self.lib.dc_edit_player_skip_step(C.byref(pl4), C.byref(st4), C.byref(plan4))
        self.assertEqual(plan4.update_cam_pivot, 1)
        self.assertEqual(plan4.cam_target_heroine, 2)
        for bi in range(4):
            self.assertGreater(plan4.body_clip[bi], 0)

        # Verify 2P, 3P, and 4P oral rig transition (M18 -> M38 / M40) sets use_oral_rig=1 and resolves valid archives
        for combo, oral_mid in ((0, 38), (6, 38), (9, 40)):
            sto = nc.EditState()
            self.lib.dc_edit_init(C.byref(sto))
            self.lib.dc_edit_set_combo(C.byref(sto), combo)
            em = sto.edit_mode
            self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(sto), self.lib.dc_edit_catalog_index_of(em, 18)), 0)
            self.assertEqual(self.lib.dc_edit_append_candidate(C.byref(sto), self.lib.dc_edit_catalog_index_of(em, oral_mid)), 0)
            plo = nc.EditPlayer()
            plano = nc.EditStepPlan()
            self.assertEqual(self.lib.dc_edit_player_init(C.byref(plo), C.byref(sto), C.byref(plano)), 0)
            self.assertEqual(self.lib.dc_edit_player_skip_step(C.byref(plo), C.byref(sto), C.byref(plano)), 0)
            self.assertEqual(self.lib.dc_edit_player_skip_step(C.byref(plo), C.byref(sto), C.byref(plano)), 0)
            self.assertEqual(plano.use_oral_rig, 1)
            self.assertGreater(plano.body_clip[0], 0)


if __name__ == "__main__":
    unittest.main()
