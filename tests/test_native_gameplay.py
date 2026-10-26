import ctypes as C
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,GamePlayer,GameInput,GameInteractionState,GameInteractionInput,GameInteractionResult,MenuButton

class NativeGameplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def test_map_placement_profiles_resolve_actual_anchors_and_cameras(self):
        from native_core import XXModel,Matrix,PPArchive
        from audit_playable_loop import entry
        data=ROOT/'Data'
        if not data.is_dir():self.skipTest('Local resources are supplied only in the private render gate')
        class Profile(C.Structure):
            _fields_=[('anchor',C.c_char_p),('camera',C.c_char_p)]
        self.lib.dc_game_map_presentation_profile.argtypes=[C.c_uint32,C.POINTER(Profile)]
        identity=Matrix((C.c_float*16)(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1))
        for selector in (0,1,3,4,5,6,7,8):
            profile=Profile();self.assertEqual(self.lib.dc_game_map_presentation_profile(selector,C.byref(profile)),0)
            raw=entry(data/'RPP_10.pp',f'mm00_{selector:02d}.xx')
            with XXModel(raw) as model:
                query=bytes(c^255 for c in profile.anchor+b'\0');node=C.c_uint32()
                self.assertEqual(self.lib.dc_xx_find_node_encoded(model.handle,query,len(query),C.byref(node)),0)
                world=Matrix();self.assertEqual(self.lib.dc_xx_node_matrix(model.handle,node,C.byref(world)),0)
                self.assertNotEqual(list(world.values)[12:15],[0,0,0])
            self.assertIn(len(entry(data/'RPP_03.pp',profile.camera.decode())),(28,252))
        sentinel=Profile(b'unchanged',b'unchanged')
        self.assertEqual(self.lib.dc_game_map_presentation_profile(2,C.byref(sentinel)),4)
        self.assertEqual(sentinel.anchor,b'unchanged')
    def test_touch_step_and_map_bounds(self):
        state=GamePlayer(0,0,-2,2,-3,3,4,0,0);out=GamePlayer();next_state=GamePlayer();inp=GameInput(.5,-1,1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),.5,C.byref(out)),0)
        self.assertAlmostEqual(out.x,1);self.assertAlmostEqual(out.z,-2)
        inp=GameInput(1,1,1);self.assertEqual(self.lib.dc_game_player_step(C.byref(out),C.byref(inp),2,C.byref(out)),1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(out),C.byref(inp),2,C.byref(next_state)),0)
        self.assertEqual((next_state.x,next_state.z),(2,3))
    def test_idle_and_invalid_inputs_are_atomic(self):
        state=GamePlayer(1,2,-3,3,-4,4,5,0,0);out=GamePlayer();inp=GameInput(0,0,0)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),1,C.byref(out)),0);self.assertEqual(bytes(out),bytes(state))
        before=bytes(out)
        for bad in (GameInput(2,0,1),GameInput(0,float('nan'),1)):
            self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(bad),1,C.byref(out)),4);self.assertEqual(bytes(out),before)
    def test_overlap_null_and_invalid_bounds(self):
        state=GamePlayer(0,0,1,-1,-1,1,1,0,0);out=GamePlayer();inp=GameInput()
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),1,C.byref(out)),4)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),-1,C.byref(out)),4)
        self.assertEqual(self.lib.dc_game_player_step(None,C.byref(inp),1,C.byref(out)),1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),None,1,C.byref(out)),1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),1,None),1)

    def test_save_load_checksum_and_atomic_failure(self):
        state=GamePlayer(1.25,-2.5,-4,4,-5,5,8,3,5);record=C.create_string_buffer(32)
        self.assertEqual(self.lib.dc_game_player_save(C.byref(state),record,32),0)
        out=GamePlayer();self.assertEqual(self.lib.dc_game_player_load(record,32,C.byref(out)),0)
        self.assertAlmostEqual(out.x,state.x);self.assertAlmostEqual(out.z,state.z);self.assertEqual((out.interaction_count,out.map_selector),(3,5))
        before=bytes(out);record[0]=ord('X');self.assertEqual(self.lib.dc_game_player_load(record,32,C.byref(out)),3);self.assertEqual(bytes(out),before)
        bad=GamePlayer(1.25,-2.5,-4,4,-5,5,8,3,2)
        self.assertEqual(self.lib.dc_game_player_save(C.byref(bad),record,32),4)

    def test_real_map_sequence_is_atomic_and_terminal(self):
        sequence=(0,1,3,4,5,6,7,8)
        for index,current in enumerate(sequence):
            next_selector=C.c_uint32(0xa5a5a5a5);finished=C.c_uint32(0xa5a5a5a5)
            self.assertEqual(self.lib.dc_game_next_map_selector(current,C.byref(next_selector),C.byref(finished)),0)
            self.assertEqual(next_selector.value,sequence[index+1] if index+1<len(sequence) else current)
            self.assertEqual(finished.value,index+1==len(sequence))
        next_selector=C.c_uint32(0xa5a5a5a5);finished=C.c_uint32(0xa5a5a5a5)
        self.assertEqual(self.lib.dc_game_next_map_selector(2,C.byref(next_selector),C.byref(finished)),4)
        self.assertEqual((next_selector.value,finished.value),(0xa5a5a5a5,0xa5a5a5a5))

    def test_save_roundtrip_across_complete_playable_sequence(self):
        sequence=(0,1,3,4,5,6,7,8)
        for count,current in enumerate(sequence,1):
            state=GamePlayer(float(count),-float(count),-100,100,-100,100,8,count,current)
            record=C.create_string_buffer(32)
            self.assertEqual(self.lib.dc_game_player_save(C.byref(state),record,32),0)
            restored=GamePlayer()
            self.assertEqual(self.lib.dc_game_player_load(record,32,C.byref(restored)),0)
            self.assertEqual((restored.interaction_count,restored.map_selector),(count,current))
            next_selector=C.c_uint32();finished=C.c_uint32()
            self.assertEqual(self.lib.dc_game_next_map_selector(current,C.byref(next_selector),C.byref(finished)),0)
            self.assertEqual(finished.value,current==8)

    def test_recovered_story_state_map_table_is_bounded_and_atomic(self):
        expected={3:0,5:1,7:3,10:0,12:1,14:6,17:0,19:1,21:4}
        for story,selector in expected.items():
            out=C.c_uint32(0xa5a5a5a5)
            self.assertEqual(self.lib.dc_game_story_map_selector(story,C.byref(out)),0)
            self.assertEqual(out.value,selector)
        for story in (0,1,2,4,6,8,9,11,13,15,16,18,20):
            out=C.c_uint32(0xa5a5a5a5)
            self.assertEqual(self.lib.dc_game_story_map_selector(story,C.byref(out)),6)
            self.assertEqual(out.value,0xa5a5a5a5)
        out=C.c_uint32(0xa5a5a5a5)
        self.assertEqual(self.lib.dc_game_story_map_selector(22,C.byref(out)),4)
        self.assertEqual(out.value,0xa5a5a5a5)

    def test_observed_gameplay_menu_profile_is_stable_and_bounded(self):
        buttons=(MenuButton*6)()
        self.assertEqual(self.lib.dc_game_menu_profile(buttons,6),0)
        self.assertEqual([(b.x,b.y,b.width,b.height,b.disabled) for b in buttons],[
            (-1,0,0,0,1),(920,328,96,96,0),(920,440,96,96,1),
            (920,552,96,96,0),(920,664,96,96,0),(0,504,352,264,0)])
        before=bytes(buttons)
        self.assertEqual(self.lib.dc_game_menu_profile(buttons,5),4)
        self.assertEqual(bytes(buttons),before)
        self.assertEqual(self.lib.dc_game_menu_profile(None,6),1)

    def test_interaction_state_machine_preserves_edges_and_wraps_ticks(self):
        state=GameInteractionState();out=GameInteractionState();event=GameInteractionResult()
        self.assertEqual(self.lib.dc_game_interaction_step(C.byref(state),C.byref(GameInteractionInput(100,1,1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.active,out.start_tick,event.begin,event.restore),(1,100,1,0))
        state=GameInteractionState.from_buffer_copy(out)
        self.assertEqual(self.lib.dc_game_interaction_step(C.byref(state),C.byref(GameInteractionInput(899,0,1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.interaction_count,out.active,event.completed),(0,1,0))
        state=GameInteractionState.from_buffer_copy(out)
        self.assertEqual(self.lib.dc_game_interaction_step(C.byref(state),C.byref(GameInteractionInput(901,0,1)),C.byref(out),C.byref(event)),0)
        self.assertEqual((out.interaction_count,out.active,out.completed,event.restore,event.completed),(1,0,1,1,1))
        state=GameInteractionState(0,0xffffffff,1,0);self.assertEqual(self.lib.dc_game_interaction_step(C.byref(state),C.byref(GameInteractionInput(800,0,1)),C.byref(out),C.byref(event)),0);self.assertEqual((out.active,out.interaction_count,event.restore),(0,1,1))
        before_state=bytes(state);before_event=bytes(event)
        self.assertEqual(self.lib.dc_game_interaction_step(C.byref(state),C.byref(GameInteractionInput(900,0,1)),C.cast(C.byref(state),C.POINTER(GameInteractionState)),C.byref(event)),1)
        self.assertEqual((bytes(state),bytes(event)),(before_state,before_event))
        state=GameInteractionState(0xffffffff,0,1,0);before=bytes(state);self.assertEqual(self.lib.dc_game_interaction_step(C.byref(state),C.byref(GameInteractionInput(801,0,1)),C.byref(out),C.byref(event)),4);self.assertEqual(bytes(state),before)

if __name__=='__main__':unittest.main()
