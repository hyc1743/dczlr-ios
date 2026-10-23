import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT / "tools"))
from native_core import library, StartupState, StartupInput, StartupPlan
from startup_cases import cases


class NativeStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def step(self,state,input):
        p = StartupPlan()
        self.assertEqual(self.lib.dc_startup_build_plan(C.byref(state),C.byref(input),C.byref(p)),0)
        return p

    def test_all_recorded_original_update_outputs(self):
        fixture = json.loads((ROOT / "tests/fixtures/startup-original-vectors.json").read_text())
        digest = hashlib.sha256()
        count = 0
        for case in cases():
            p = self.step(StartupState(*case["state"]),StartupInput(*case["input"]))
            digest.update((json.dumps({**case,"output":p.record()},sort_keys=True,separators=(",",":"))+"\n").encode())
            count += 1
        self.assertEqual(count,fixture["cases"])
        self.assertEqual(digest.hexdigest(),fixture["output_sha256"])

    def test_complete_startup_sequence_and_next_callback_boundary(self):
        p = StartupPlan()
        self.assertEqual(self.lib.dc_startup_begin_plan(C.byref(p)),0)
        self.assertEqual(p.record(),{"state":[0,1,0,0],"actions":[[1,3],[2,0],[1,4]]})
        p = self.step(p.next,StartupInput(1999,1,1,0))
        self.assertEqual(p.record(),{"state":[0,0,0,1999],"actions":[]})
        p = self.step(p.next,StartupInput(1,0,0,0))
        self.assertEqual(p.record(),{"state":[0,1,0,0],"actions":[[1,2]]})
        p = self.step(p.next,StartupInput(16,3,1,0))
        self.assertEqual(p.record(),{"state":[1,1,0,0],"actions":[[2,1],[1,4]]})
        p = self.step(p.next,StartupInput(29999,1,1,0))
        self.assertEqual(p.record(),{"state":[1,0,0,29999],"actions":[]})
        p = self.step(p.next,StartupInput(1,0,0,0))
        self.assertEqual(p.record(),{"state":[1,1,0,0],"actions":[[1,2]]})
        p = self.step(p.next,StartupInput(16,3,1,0))
        self.assertEqual(p.record(),{"state":[1,1,1,0],"actions":[[3,0],[4,0]]})
        p = self.step(p.next,StartupInput(30000,1,1,3))
        self.assertEqual(p.record(),{"state":[1,1,1,0],"actions":[]})

    def test_unsigned_threshold_and_wrapping_delta(self):
        p = self.step(StartupState(0,0,0,0),StartupInput(-1,0,0,0))
        self.assertEqual(p.record(),{"state":[0,1,0,0],"actions":[[1,2]]})
        p = self.step(StartupState(1,0,0,0xffffffff),StartupInput(1,0,0,0))
        self.assertEqual(p.record(),{"state":[1,0,0,0],"actions":[]})

    def test_invalid_arguments_preserve_output_and_inputs(self):
        p = StartupPlan()
        C.memset(C.byref(p),0xa5,C.sizeof(p))
        before = bytes(p)
        s = StartupState(2,0,0,0)
        i = StartupInput()
        self.assertEqual(self.lib.dc_startup_build_plan(C.byref(s),C.byref(i),C.byref(p)),1)
        self.assertEqual(bytes(p),before)
        self.assertEqual(s.card,2)
        self.assertEqual(self.lib.dc_startup_begin_plan(None),1)
        self.assertEqual(self.lib.dc_startup_build_plan(None,C.byref(i),C.byref(p)),1)


if __name__ == "__main__":
    unittest.main()
