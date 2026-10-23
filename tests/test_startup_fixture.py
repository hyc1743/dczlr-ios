import ctypes as C
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from startup_fixture import resources,install
from native_core import library,PPArchive,XXModel,Viewport,SpriteVertex,Matrix,StartupPlan,StartupState,StartupInput,MaterialValue
from scene_cases import matrix
from check_ios_sprite import startup_evidence


class StartupFixtureTests(unittest.TestCase):
    def test_generated_archives_drive_both_cards_and_transition_geometry(self):
        files=resources();lib=library()
        with PPArchive(files['RPP_17.pp']) as archive:xx,xa=archive.read(0),archive.read(1)
        handle=C.c_void_p();self.assertEqual(lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(handle)),0)
        self.addCleanup(lib.dc_model_close,handle)
        state,plan=StartupState(),StartupPlan();trace=[];now=0
        def apply():
            nonlocal state
            for action in plan.actions[:plan.count]:
                trace.append((action.kind,action.value))
                if action.kind==1:self.assertEqual(lib.dc_model_request(handle,action.value,now),0)
            state=StartupState.from_buffer_copy(plan.next)
        self.assertEqual(lib.dc_startup_begin_plan(C.byref(plan)),0);apply()
        view=Viewport(0,0,1024,768,0,1);world=matrix();vp=matrix(translation=(0,0,.5));out=(SpriteVertex*6)()
        stable=set();alphas=set()
        for i in range(1100):
            current,ready=C.c_uint32(),C.c_uint32()
            self.assertEqual(lib.dc_model_query(handle,C.byref(current),C.byref(ready)),0)
            input=StartupInput(33,current.value,ready.value,0)
            self.assertEqual(lib.dc_startup_build_plan(C.byref(state),C.byref(input),C.byref(plan)),0);apply()
            self.assertEqual(lib.dc_model_tick(handle,33,now,C.byref(world)),0)
            material=MaterialValue();self.assertEqual(lib.dc_model_material(handle,0,C.byref(material)),0)
            alphas.add(round(material.components[3],2))
            self.assertEqual(lib.dc_model_project(handle,0,C.byref(vp),C.byref(view),0xffffffff,out,6),0)
            if not state.waiting:stable.add(state.card)
            if state.advanced:break
            now+=33
        self.assertTrue(state.advanced);self.assertEqual(stable,{0,1});self.assertGreater(len(alphas),4)
        self.assertGreaterEqual(now,32000)
        self.assertEqual([v for k,v in trace if k==2],[0,1])
        self.assertEqual(trace[-2:],[(3,0),(4,0)])

    def test_fixture_install_is_explicit_and_never_overwrites_existing_data(self):
        with tempfile.TemporaryDirectory() as root:
            destination=Path(root)/'Data';report=install(destination)
            self.assertEqual(set(report['files']),{'RPP_02.pp','RPP_17.pp'})
            with self.assertRaises(ValueError):install(destination)
            with PPArchive(destination/'RPP_02.pp') as cards:
                self.assertEqual(cards.count,11)

    def test_startup_evidence_requires_order_waits_and_completion(self):
        lines=['2026-10-24T00:00:00Z PORTLAB_STARTUP_TRANSITION_PRESENTED submitted',
               '2026-10-24T00:00:01Z PORTLAB_SCENE_PRESENTED=startup submitted',
               '2026-10-24T00:00:04Z PORTLAB_SCENE_PRESENTED=warning submitted',
               '2026-10-24T00:00:35Z PORTLAB_STARTUP_COMPLETED submitted',
               '2026-10-24T00:00:35Z PORTLAB_SCENE_PRESENTED=title submitted']
        self.assertEqual(startup_evidence('\n'.join(lines))['second_to_title_seconds'],31)
        for changed in (lines[:3]+lines[4:],lines[1:],lines[:2]+lines[3:],
                        lines[:4]+[lines[4].replace('00:00:35','00:00:05')]):
            with self.assertRaises(ValueError):startup_evidence('\n'.join(changed))


if __name__=='__main__':unittest.main()
