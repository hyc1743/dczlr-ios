import copy
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from render_probe_evidence import validate,CHAPTER_MAPS,SAMPLES
from test_startup_pixels import png

class RenderProbeEvidenceTests(unittest.TestCase):
    def fixture(self,root):
        rows=[]
        for chapter,map_selector in CHAPTER_MAPS.items():
            for i,sample in enumerate(SAMPLES):
                name=f'render-c{chapter:02d}-{sample}.png'
                (root/name).write_bytes(png((40+i*20,100,180),64,48))
                rows.append({'file':name,'chapter':chapter,'map':map_selector,'sample':sample,
                    'anchor':'generated-anchor','camera':'generated-camera','depth_policy':'material_auto',
                    'width':64,'height':48,'viewport_pixels':3072,'actor_visible_pixels':500,
                    'actor_bbox':[10,8,45,45],'pose_frame':i*8,
                    'interaction_active':sample=='interaction','interaction_completed':sample=='restored'})
        return {'kind':'deterministic_render_checkpoints','playability_certification':False,'captures':rows}
    def test_each_scene_needs_idle_interaction_and_restoration(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);data=self.fixture(root)
            self.assertEqual(validate(data,root)['gpu_checkpoints'],15)
            for index in range(15):
                bad=copy.deepcopy(data);del bad['captures'][index]
                with self.assertRaises(ValueError):validate(bad,root)
    def test_background_color_does_not_replace_actor_depth_contribution(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);data=self.fixture(root)
            for pixels,bbox in ((0,[]),(5,[20,30,21,32]),(500,[20,30,50,32])):
                bad=copy.deepcopy(data);bad['captures'][4]['actor_visible_pixels']=pixels;bad['captures'][4]['actor_bbox']=bbox
                with self.assertRaises(ValueError):validate(bad,root)
    def test_state_and_binding_errors_cannot_certify_interaction(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);data=self.fixture(root)
            for field,value in (('interaction_active',False),('map',99),('anchor',''),('depth_policy','write_all'),('width',65)):
                bad=copy.deepcopy(data);bad['captures'][1][field]=value
                with self.assertRaises(ValueError):validate(bad,root)
            bad=copy.deepcopy(data);bad['captures'][2]['interaction_completed']=False
            with self.assertRaises(ValueError):validate(bad,root)
    def test_stale_frame_and_duplicate_checkpoint_are_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);data=self.fixture(root)
            bad=copy.deepcopy(data);bad['captures'][1]=copy.deepcopy(bad['captures'][0])
            with self.assertRaises(ValueError):validate(bad,root)
            idle=root/data['captures'][0]['file'];active=root/data['captures'][1]['file']
            active.write_bytes(idle.read_bytes())
            with self.assertRaises(ValueError):validate(data,root)

if __name__=='__main__':unittest.main()
