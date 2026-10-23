import ctypes as C
from pathlib import Path
import sys
import tempfile
import unittest
import io
import wave

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from startup_fixture import resources,install
from native_core import library,PPArchive,XXModel,Viewport,SpriteVertex,Matrix,StartupPlan,StartupState,StartupInput,MaterialValue
from scene_cases import matrix
from check_ios_sprite import startup_evidence
from script_decode_cases import native_result


class StartupFixtureTests(unittest.TestCase):
    def test_new_game_fixture_resolves_pending_media_and_three_records(self):
        files=resources();lib=library()
        with PPArchive(files['RPP_16.pp']) as archive:data=archive.read(0)
        cursor=0
        for frame in range(3):
            result=native_result(lib,{'hex':data.hex(),'cursor':cursor,'frame':frame,'controls':[['#C',2],['#P',5]]})
            self.assertGreater(result['cursor'],cursor);cursor=result['cursor']
            if frame==0:
                for key,filename,extension in (('background','RPP_02.pp',b'.ema'),('music','RPP_01.pp',b'.wav'),('sound','RPP_14.pp',b'.wav')):
                    name=bytes.fromhex(result[key]).split(b'\0')[0]+extension
                    with PPArchive(files[filename]) as archive:
                        self.assertIn(name.lower(),[archive.entry(i).name_bytes.lower() for i in range(archive.count)])
                voice=bytes.fromhex(result['controls'])[37:74].split(b'\0')[0]+b'.wav'
                with PPArchive(files['RPP_00.pp']) as archive:self.assertEqual(archive.entry(0).name_bytes,voice)

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
            self.assertEqual(set(report['files']),{'RPP_00.pp','RPP_01.pp','RPP_02.pp','RPP_14.pp','RPP_16.pp','RPP_17.pp'})
            with self.assertRaises(ValueError):install(destination)
            with PPArchive(destination/'RPP_02.pp') as cards:
                self.assertEqual(cards.count,12)
            with PPArchive(destination/'RPP_01.pp') as audio:
                with wave.open(io.BytesIO(audio.read(0)),'rb') as source:
                    self.assertEqual((source.getnchannels(),source.getsampwidth(),source.getframerate()),(1,2,22050))
                    self.assertEqual(source.getnframes(),44100)

    def test_startup_evidence_requires_order_waits_and_completion(self):
        lines=['2026-10-24T00:00:00Z PORTLAB_STARTUP_TRANSITION_PRESENTED submitted',
               '2026-10-24T00:00:01Z PORTLAB_SCENE_PRESENTED=startup submitted',
               '2026-10-24T00:00:04Z PORTLAB_SCENE_PRESENTED=warning submitted',
               '2026-10-24T00:00:35Z PORTLAB_STARTUP_COMPLETED submitted',
               '2026-10-24T00:00:35Z PORTLAB_SCENE_PRESENTED=title submitted']
        self.assertEqual(startup_evidence('\n'.join(lines))['second_to_title_seconds'],31)
        with self.assertRaises(ValueError):startup_evidence('\n'.join(lines),require_audio=True)
        audio='2026-10-24T00:00:36Z PORTLAB_TITLE_AUDIO_ADVANCED submitted'
        self.assertEqual(startup_evidence('\n'.join(lines+[audio]),require_audio=True)['title_audio'],
                         'playback clock advanced; audible output unverified')
        for changed in (lines[:3]+lines[4:],lines[1:],lines[:2]+lines[3:],
                        lines[:4]+[lines[4].replace('00:00:35','00:00:05')]):
            with self.assertRaises(ValueError):startup_evidence('\n'.join(changed))


if __name__=='__main__':unittest.main()
