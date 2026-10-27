import copy
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from check_ios_sprite import primary_modes_evidence,orbit_world

class PrimaryCameraEvidenceTests(unittest.TestCase):
    def fixture(self):
        pose=[-3,-72,.2,1,22,3,-1]
        body={'camera_modes':[1,0],'camera_target_binding':1,'camera_body_retargets':1,
              'camera_pose':[0,-70,.1,.5,22,0,0],'actor_visible_pixels':100,'camera_retargets':2,
              'camera_target':[22,0,0],'camera_target_matrix':[1,0,0,0,0,1,0,0,0,0,1,0,22,0,0,1]}
        off={'camera_modes':[0,0],'camera_pose':pose,'camera_resets':3,'actor_visible_pixels':100}
        for frame in (body,off):frame['camera_world']=orbit_world(frame['camera_pose'])
        first={'camera_modes':[2,0],'camera_animation_clip':0,'actor_visible_pixels':100,'camera_controller_pose':pose,
               'automatic_eye_world':[1,0,0,0,0,1,0,0,0,0,1,0,0,0,50,1],
               'automatic_target':[0,0,0],'automatic_center':[0,-2,0],
               'camera_world':[1,0,0,0,0,1,0,0,0,0,1,0,0,0,50,1],
               'camera_animation_frame':1,'camera_auto_frames':1}
        later=copy.deepcopy(first);s=math.sqrt(.5)
        later['automatic_eye_world'][-4:-1]=[50,0,50]
        later['camera_world']=[s,0,-s,0,0,1,0,0,s,0,s,0,50,0,50,1]
        later['camera_animation_frame']=2;later['camera_auto_frames']=8
        return body,first,later,off,pose
    def test_world_pose_animation_and_original_height_are_checked(self):
        report=primary_modes_evidence(*self.fixture())
        self.assertEqual(report['animation_frames'],[1,2])
        self.assertIn('secondary view',report['remaining'])
    def test_frozen_animation_and_wrong_view_or_binding_are_rejected(self):
        for change in ('binding','mode','clock','eye','view','height','manual','restore','empty'):
            body,first,later,off,pose=copy.deepcopy(self.fixture())
            if change=='binding':body['camera_target_binding']=0
            elif change=='mode':later['camera_modes']=[0,0]
            elif change=='clock':later['camera_animation_frame']=first['camera_animation_frame']
            elif change=='eye':later.update(first)
            elif change=='view':later['camera_world'][0]=9
            elif change=='height':later['automatic_target'][1]=2
            elif change=='manual':later['camera_controller_pose']=pose[:];later['camera_controller_pose'][3]+=.1
            elif change=='restore':off['camera_world'][12]+=1
            elif change=='empty':later['actor_visible_pixels']=0
            with self.subTest(change=change),self.assertRaises(ValueError):primary_modes_evidence(body,first,later,off,pose)

if __name__=='__main__':unittest.main()
