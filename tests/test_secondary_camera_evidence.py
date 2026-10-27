import copy
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from secondary_camera_evidence import validate
from camera_evidence_math import orbit_world

def translation(x=0,y=0,z=0):return [1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1]

class SecondaryEvidenceTests(unittest.TestCase):
    def fixture(self):
        pose=[0,-20,0,0,0,0,0];world=translation(z=20)
        base={'width':1024,'height':768,'primary_actor_visible_pixels':100,'secondary_actor_visible_pixels':50,
              'secondary_changed_outside':0,'secondary_visible':True,'secondary_visible_pixels':1000,
              'secondary_viewport':[0,504,352,264,0,1],'secondary_scene_draws':8,'secondary_map_draws':3,
              'camera_world':world,'camera_modes':[0,0],'secondary_world':world,'secondary_pose':pose,
              'secondary_controller_pose':pose,'camera_animation_clip':0}
        names=('face','body','auto-first','auto-later','auto-off','hidden','visible','pointer','right','pan','wheel','both','reset')
        f={name:copy.deepcopy(base) for name in names}
        for name,binding,center,distance in (('face',0,0,-20),('body',1,10,-10)):
            f[name].update(secondary_target_binding=binding,secondary_target_matrix=translation(z=center),
                           camera_modes=[0,binding],secondary_pose=[0,distance,0,0,0,0,center])
        s=math.sqrt(26);moving=[5/s,0,-1/s,0,0,1,0,0,1/s,0,5/s,0,10,0,50,1]
        for name,eye,view,index,clock in (('auto-first',translation(z=50),translation(z=50),1,10),
                                          ('auto-later',translation(10,0,50),moving,8,11),
                                          ('both',translation(10,0,50),moving,12,12)):
            f[name].update(camera_modes=[0,2] if name!='both' else [2,2],automatic_eye_world=eye,
                           automatic_target=[0,0,0],secondary_world=view,secondary_auto_frames=index,camera_animation_frame=clock)
            if name=='both':f[name]['camera_world']=view
        f['hidden'].update(secondary_visible=False,secondary_scene_draws=0,secondary_actor_visible_pixels=0,secondary_visible_pixels=0)
        for name,operation,motion,after in (
            ('pointer',0,[-10,0,0,1,0,0,0],[0,-20,0,.1,0,0,0]),
            ('right',1,[10,-10,0,0,1,0,0],[1,-21,0,0,0,0,0]),
            ('pan',2,[10,-20,0,1,1,0,1],[0,-20,0,0,2,0,-4]),
            ('wheel',3,[0,0,120,0,0,0,0],[0,-20,0,0,0,0,-4])):
            f[name].update(secondary_pointer_before_base=translation(),secondary_pointer_before_pose=[0,-20,0,0],
                           secondary_pointer_limits=[100,5,20,-30,4],secondary_pointer_input=motion,
                           secondary_pointer_operation=operation,secondary_controller_pose=after,secondary_world=orbit_world(after),
                           pointer_logical=[360,636],secondary_pointer_owner=2)
        return f,pose
    def test_independent_secondary_paths_have_bounded_scope(self):
        report=validate(*self.fixture());self.assertEqual(report['complete_story'],'not tested')
        self.assertEqual(report['system_screens'],'not tested')
    def test_missing_gpu_evidence_or_wrong_camera_is_rejected(self):
        for change in ('outside','missing','primary','viewport','actor','geometry','frozen','both','ownership','fast','pointer','hidden'):
            frames,pose=self.fixture()
            if change=='outside':frames['face']['secondary_changed_outside']=1
            elif change=='missing':del frames['face']['secondary_changed_outside']
            elif change=='primary':frames['pointer']['camera_world'][12]+=1
            elif change=='viewport':frames['body']['secondary_viewport'][1]-=1
            elif change=='actor':frames['body']['secondary_actor_visible_pixels']=0
            elif change=='geometry':frames['body']['secondary_scene_draws']=3
            elif change=='frozen':frames['auto-later']['secondary_auto_frames']=1
            elif change=='both':frames['both']['camera_modes']=[2,0]
            elif change=='ownership':frames['pointer']['secondary_pointer_owner']=1
            elif change=='fast':frames['pan']['secondary_pointer_input'][-1]=0
            elif change=='pointer':frames['wheel']['secondary_pointer_input'][2]=0
            elif change=='hidden':frames['hidden']['secondary_visible_pixels']=1
            with self.subTest(change=change),self.assertRaises(ValueError):validate(frames,pose)

if __name__=='__main__':unittest.main()
