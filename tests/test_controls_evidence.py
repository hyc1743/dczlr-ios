"""Window evidence must stay bound to its timestamped presentation event."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from check_ios_sprite import controls_visible


class ControlsEvidenceTests(unittest.TestCase):
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
