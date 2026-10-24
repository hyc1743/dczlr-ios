import ctypes as C
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,GamePlayer,GameInput

class NativeGameplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def test_touch_step_and_map_bounds(self):
        state=GamePlayer(0,0,-2,2,-3,3,4);out=GamePlayer();next_state=GamePlayer();inp=GameInput(.5,-1,1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),.5,C.byref(out)),0)
        self.assertAlmostEqual(out.x,1);self.assertAlmostEqual(out.z,-2)
        inp=GameInput(1,1,1);self.assertEqual(self.lib.dc_game_player_step(C.byref(out),C.byref(inp),2,C.byref(out)),1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(out),C.byref(inp),2,C.byref(next_state)),0)
        self.assertEqual((next_state.x,next_state.z),(2,3))
    def test_idle_and_invalid_inputs_are_atomic(self):
        state=GamePlayer(1,2,-3,3,-4,4,5);out=GamePlayer();inp=GameInput(0,0,0)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),1,C.byref(out)),0);self.assertEqual(bytes(out),bytes(state))
        before=bytes(out)
        for bad in (GameInput(2,0,1),GameInput(0,float('nan'),1)):
            self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(bad),1,C.byref(out)),4);self.assertEqual(bytes(out),before)
    def test_overlap_null_and_invalid_bounds(self):
        state=GamePlayer(0,0,1,-1,-1,1,1);out=GamePlayer();inp=GameInput()
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),1,C.byref(out)),4)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),-1,C.byref(out)),4)
        self.assertEqual(self.lib.dc_game_player_step(None,C.byref(inp),1,C.byref(out)),1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),None,1,C.byref(out)),1)
        self.assertEqual(self.lib.dc_game_player_step(C.byref(state),C.byref(inp),1,None),1)

    def test_save_load_checksum_and_atomic_failure(self):
        state=GamePlayer(1.25,-2.5,-4,4,-5,5,8,3);record=C.create_string_buffer(32)
        self.assertEqual(self.lib.dc_game_player_save(C.byref(state),record,32),0)
        out=GamePlayer();self.assertEqual(self.lib.dc_game_player_load(record,32,C.byref(out)),0)
        self.assertAlmostEqual(out.x,state.x);self.assertAlmostEqual(out.z,state.z);self.assertEqual(out.interaction_count,3)
        before=bytes(out);record[0]=ord('X');self.assertEqual(self.lib.dc_game_player_load(record,32,C.byref(out)),3);self.assertEqual(bytes(out),before)

if __name__=='__main__':unittest.main()
