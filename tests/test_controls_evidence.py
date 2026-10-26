"""Window evidence must stay bound to its timestamped presentation event."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from check_ios_sprite import controls_visible,black_gutter_evidence,simulator_screenshot,camera_action_evidence
import copy
from unittest.mock import patch
import tempfile
import subprocess


class ControlsEvidenceTests(unittest.TestCase):
    def test_camera_actions_require_rendered_target_change_and_original_reset_pose(self):
        retarget={'camera_pose':[0,-20,.3,.5,1,2,3],'camera_target':[1,2,3],'camera_retargets':1,'actor_visible_pixels':100}
        retarget['camera_target_matrix']=[1,0,0,0,0,1,0,0,0,0,1,0,1,2,3,1]
        reset={'camera_pose':[8,-30,.2,0,0,0,0],'camera_resets':1,'actor_visible_pixels':100}
        expected=list(reset['camera_pose'])
        self.assertIn('original CAM',camera_action_evidence(retarget,reset,expected)['default_reset'])
        for bad in ('target','zero_matrix','unchanged','wrong_reset','invisible','nan_expected'):
            a=copy.deepcopy(retarget);b=copy.deepcopy(reset);e=list(expected)
            if bad=='target':a['camera_target'][0]=7
            if bad=='zero_matrix':a['camera_target_matrix']=[0]*16
            if bad=='unchanged':b['camera_pose']=list(a['camera_pose']);e=list(b['camera_pose'])
            if bad=='wrong_reset':b['camera_pose'][0]+=1
            if bad=='invisible':a['actor_visible_pixels']=0
            if bad=='nan_expected':e[0]=float('nan')
            with self.assertRaises(ValueError):camera_action_evidence(a,b,e)
    def test_black_gutters_require_matching_render_and_control_rectangles(self):
        log=('2026-10-27T00:00:00Z PORTLAB_GAMEPAD_PRESENTATION bounds=874x402 attached=1 hidden=0 layout=black-gutters-v4 game=185,1,504,378 key_overlap=0\n'
             '2026-10-27T00:00:00Z PORTLAB_RENDER_VIEWPORT input=874x402 game=185,1,504,378\n')
        self.assertEqual(black_gutter_evidence(log)['virtual_key_overlap'],0)
        for bad in (log.replace('key_overlap=0','key_overlap=1'),log.replace('input=874x402 game=185','input=874x402 game=180'),log.replace('hidden=0','hidden=1')):
            with self.assertRaises(ValueError):black_gutter_evidence(bad)
    def test_simulator_capture_retries_one_timeout_and_retains_the_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'frame.png'
            with patch('check_ios_sprite.run',side_effect=[subprocess.TimeoutExpired('simctl',30),'saved']) as run:
                simulator_screenshot('device',path)
                self.assertEqual(run.call_count,2)
            self.assertIn('failed',Path(str(path)+'.capture.json').read_text())
            with patch('check_ios_sprite.run',side_effect=subprocess.TimeoutExpired('simctl',30)):
                with self.assertRaises(RuntimeError):simulator_screenshot('device',path)
    def test_multiline_device_description_preserves_pc_visibility(self):
        log=('2026-10-26T04:39:45Z PORTLAB_GAMEPAD_PRESENTATION bounds=874x402 '
             'attached=1 hidden=1 physical=0 paths=1 test_virtual=1 detected=(\n'
             '    "Gamepad/MFi/fixture=0"\n) pc_visible=1\n'
             '2026-10-26T04:39:46Z PORTLAB_SCENE_PRESENTED=startup\n')
        self.assertTrue(controls_visible(log,True))
        self.assertFalse(controls_visible(log,False))

    def test_later_event_cannot_certify_an_invisible_or_unattached_layer(self):
        log=('2026-10-26T04:39:45Z PORTLAB_GAMEPAD_PRESENTATION bounds=874x402 '
             'attached=1 hidden=1 physical=0 paths=1 pc_visible=0\n'
             '2026-10-26T04:39:46Z PORTLAB_GAMEPAD_PRESENTATION bounds=874x402 '
             'attached=0 hidden=1 physical=0 paths=1 pc_visible=1\n')
        self.assertFalse(controls_visible(log,True))
        self.assertFalse(controls_visible(log,False))
        self.assertFalse(controls_visible(log.replace('bounds=874x402','bounds=0x402'),True))

    def test_legacy_gamepad_prefix_still_requires_visible_geometry(self):
        log='2026-10-26T04:39:45Z PORTLAB_GAMEPAD_PRESENTATION bounds=874x402 attached=1 hidden=0 physical=0 paths=1 detected=() pc_visible=0\n'
        self.assertTrue(controls_visible(log))
        self.assertFalse(controls_visible(log,True))
        self.assertFalse(controls_visible(log.replace('paths=1','paths=0')))


if __name__=='__main__':unittest.main()
