import ctypes as C
import json
import math
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,Matrix,XXModel,PPArchive,AnimationState
from scene_cases import matrix
from camera_look_at_cases import cases

class CameraModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def test_look_at_matches_original_instruction_vectors(self):
        inputs=list(cases());fixture=json.loads((ROOT/'tests/fixtures/camera-look-at-original-vectors.json').read_text(encoding='utf-8'))
        self.assertEqual(fixture['scene_target_height']['value'],2.)
        for row in fixture['vectors']:
            source,target=inputs[row['case']];out=Matrix()
            self.assertEqual(self.lib.dc_camera_look_at(C.byref(source),C.byref(target),C.byref(out)),0)
            for a,b in zip(out.values,row['result']):self.assertLess(abs(a-b),2e-6)
    def test_look_at_aliases_both_inputs_and_preserves_eye(self):
        for alias in ('source','target'):
            source=matrix(.7,1.3,(3,4,5));target=matrix(translation=(-8,2,1));expected=Matrix()
            self.lib.dc_camera_look_at(C.byref(source),C.byref(target),C.byref(expected))
            self.assertEqual(self.lib.dc_camera_look_at(C.byref(source),C.byref(target),C.byref(source if alias=='source' else target)),0)
            self.assertEqual(bytes(source if alias=='source' else target),bytes(expected))
            self.assertEqual(list(expected.values)[12:],[3,4,5,1])
    def test_invalid_or_degenerate_camera_does_not_corrupt_output(self):
        for target in (matrix(),matrix(translation=(0,5,0)),matrix(translation=(float('nan'),1,3))):
            source=matrix();out=matrix(translation=(10,20,30));before=bytes(out)
            self.assertEqual(self.lib.dc_camera_look_at(C.byref(source),C.byref(target),C.byref(out)),4)
            self.assertEqual(bytes(out),before)
        source=matrix();source.values[3]=1;target=matrix(translation=(1,2,3));out=matrix();before=bytes(out)
        self.assertEqual(self.lib.dc_camera_look_at(C.byref(source),C.byref(target),C.byref(out)),3)
        self.assertEqual(bytes(out),before)
    def binding(self,stage,kind):
        name=C.create_string_buffer(32)
        self.assertEqual(self.lib.dc_camera_scene_node(stage,kind,name,len(name)),0)
        return name.value.decode()
    def test_original_binding_names_and_rejected_selectors(self):
        for stage,prefix in enumerate('bca'):
            self.assertEqual([self.binding(stage,i) for i in range(4)],
                             [prefix+'_On_namida',prefix+'_Kn_kosi','z_Nz_light','z_Nz_cam'])
        for stage,kind,capacity in ((3,0,32),(0,4,32),(0,0,2)):
            name=C.create_string_buffer(b'unchanged',32);before=name.raw
            self.assertEqual(self.lib.dc_camera_scene_node(stage,kind,name,capacity),4)
            self.assertEqual(name.raw,before)
    def read(self,archive,name):
        with PPArchive(ROOT/'Data'/archive) as pp:
            return pp.read(next(i for i in range(pp.count) if pp.entry(i).name_bytes.decode()==name))
    def open(self,archive,xxname,xaname=None):
        xx=self.read(archive,xxname);xa=self.read(archive,xaname) if xaname else None;model=C.c_void_p()
        if xa:self.assertEqual(self.lib.dc_model_open(xx,len(xx),xa,len(xa),C.byref(model)),0)
        else:self.assertEqual(self.lib.dc_model_open_static(xx,len(xx),C.byref(model)),0)
        self.addCleanup(self.lib.dc_model_close,model)
        return model,xx,xa
    def node(self,model,xx,name):
        with XXModel(xx) as parsed:
            index=C.c_uint32();encoded=bytes(b^255 for b in (name+'\0').encode())
            self.assertEqual(self.lib.dc_xx_find_node_encoded(parsed.handle,encoded,len(encoded),C.byref(index)),0)
        result=Matrix();self.assertEqual(self.lib.dc_model_global(model,index.value,C.byref(result)),0)
        return result
    def test_real_camera_bindings_resolve_for_all_three_stages(self):
        if not (ROOT/'Data/RPP_08.pp').exists():self.skipTest('private resource gate')
        world=matrix(translation=(22,0,0))
        for stage,prefix in enumerate('bca'):
            for archive,xxname,xaname,kinds in (('RPP_08.pp',prefix+'m00_01.xx',prefix+'n00_02.xa',(1,2)),
                                               ('RPP_09.pp',prefix+'k00_00.xx',None,(0,))):
                model,xx,xa=self.open(archive,xxname,xaname)
                self.assertEqual(self.lib.dc_model_tick(model,0,0,C.byref(world)),0)
                for kind in kinds:
                    target=self.node(model,xx,self.binding(stage,kind))
                    self.assertEqual(target.values[15],1)
                    self.assertTrue(all(math.isfinite(x) for x in target.values))
    def test_original_auto_camera_clip_zero_moves_and_loops(self):
        if not (ROOT/'Data/RPP_17.pp').exists():self.skipTest('private resource gate')
        model,xx,xa=self.open('RPP_17.pp','auto_cam.xx','auto_cam.xa')
        self.assertEqual(self.lib.dc_model_request(model,0,0),0)
        world=matrix(translation=(22,4,-1));positions=[]
        previous=0
        for tick in (0,1000,2000,40001):
            self.assertEqual(self.lib.dc_model_tick(model,tick-previous,tick,C.byref(world)),0);previous=tick
            eye=self.node(model,xx,self.binding(2,3));positions.append(list(eye.values)[12:15])
            target=matrix(translation=(22,6,-1));camera=Matrix()
            self.assertEqual(self.lib.dc_camera_look_at(C.byref(eye),C.byref(target),C.byref(camera)),0)
        self.assertEqual(positions[0],[22,4,49])
        self.assertGreater(abs(positions[1][0]-positions[0][0]),1)
        self.assertLess(max(abs(a-b) for a,b in zip(positions[0],positions[-1])),.01)
        state=AnimationState();self.lib.dc_model_get_animation(model,C.byref(state))
        self.assertEqual(state.current,0)
        self.assertAlmostEqual(state.frame,.001,places=3)

if __name__=='__main__':unittest.main()
