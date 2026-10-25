"""Input behavior at the same C boundary used by the UIKit frontend."""
import ctypes as C
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from native_core import library


class Raw(C.Structure):
    _fields_ = [('buttons', C.c_uint64)] + [(n, C.c_int32) for n in ('lx','ly','rx','ry')]


class Touch(C.Structure):
    _fields_ = [('id', C.c_uint32), ('x', C.c_float), ('y', C.c_float)]


class Frame(C.Structure):
    _fields_ = [(n, C.c_uint64) for n in ('buttons','pressed','released')] + [
        (n, C.c_int32) for n in ('lx','ly','rx','ry')] + [
        ('connected', C.c_uint32), ('touch_count', C.c_uint32),
        ('touch_x', C.c_float), ('touch_y', C.c_float), ('touches', Touch*16)]


class Latch(C.Structure):
    _fields_ = [('current', Raw), ('pending', C.c_uint64), ('previous', C.c_uint64),
                ('connected', C.c_uint32), ('touch_count', C.c_uint32),
                ('pending_touch', C.c_uint32), ('touches', Touch*16), ('tap', Touch)]


class GamepadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()
        cls.lib.dc_pad_stick.argtypes = [C.c_float]*3 + [C.POINTER(C.c_int32)]*2
        cls.lib.dc_pad_merge.argtypes = [Raw, Raw]
        cls.lib.dc_pad_merge.restype = Raw
        cls.lib.dc_pad_publish.argtypes = [C.POINTER(Latch), Raw]
        cls.lib.dc_pad_poll.argtypes = [C.POINTER(Latch)]
        cls.lib.dc_pad_poll.restype = Frame
        cls.lib.dc_pad_touches.argtypes = [C.POINTER(Latch), C.POINTER(Touch), C.c_uint32]
        cls.lib.dc_pad_clear.argtypes = [C.POINTER(Latch)]

    def test_radial_dead_zone_full_tilt_and_diagonals(self):
        for dx, dy in ((0,0),(7,0),(4,4),(7.7,0),(38.5,0),(61.6,0),(77,77),(-77,-77)):
            x,y = C.c_int32(), C.c_int32()
            self.lib.dc_pad_stick(dx,dy,77,C.byref(x),C.byref(y))
            d=math.hypot(dx,dy)
            m=min(max((d-7.7)/53.9,0),1)
            want=(round(dx/d*m*32767), round(-dy/d*m*32767)) if d else (0,0)
            self.assertLessEqual(abs(x.value-want[0]),1)
            self.assertLessEqual(abs(y.value-want[1]),1)
        for bad in (float('nan'), float('inf')):
            self.lib.dc_pad_stick(bad,0,77,C.byref(x),C.byref(y))
            self.assertEqual((x.value,y.value),(0,0))

    def test_merge_selects_whole_stick_and_ors_independent_keys(self):
        v=Raw(1,20000,17000,-10000,9000)
        p=Raw(2,0,5000,3999,0)
        merged=self.lib.dc_pad_merge(v,p)
        self.assertEqual((merged.buttons,merged.lx,merged.ly,merged.rx,merged.ry),
                         (3,0,5000,-10000,9000))
        p.lx=2800;p.ly=2900  # radial threshold, not per-axis
        merged=self.lib.dc_pad_merge(v,p)
        self.assertEqual((merged.lx,merged.ly),(2800,2900))

    def test_all_short_button_presses_survive_poll_then_release_once(self):
        for bit in range(16):
            state=Latch();button=1<<bit
            self.lib.dc_pad_publish(C.byref(state),Raw(button,0,0,0,0))
            self.lib.dc_pad_publish(C.byref(state),Raw())
            first=self.lib.dc_pad_poll(C.byref(state))
            self.assertEqual((first.buttons,first.pressed,first.released),(button,button,0))
            second=self.lib.dc_pad_poll(C.byref(state))
            self.assertEqual((second.buttons,second.pressed,second.released),(0,0,button))
            self.assertEqual(self.lib.dc_pad_poll(C.byref(state)).released,0)

    def test_hold_axes_flags_and_unrelated_updates_preserve_pending_press(self):
        state=Latch()
        for i in range(60):
            self.lib.dc_pad_publish(C.byref(state),Raw(1,32767,0,0,-32767))
        f=self.lib.dc_pad_poll(C.byref(state))
        self.assertEqual(f.buttons,1|(1<<18)|(1<<23))
        self.assertEqual(f.pressed,f.buttons)
        f=self.lib.dc_pad_poll(C.byref(state))
        self.assertEqual(f.pressed,0)

    def test_lifecycle_clears_unsampled_taps_and_reports_sampled_releases(self):
        state=Latch();state.connected=1
        self.lib.dc_pad_publish(C.byref(state),Raw(3,32767,0,0,0))
        self.lib.dc_pad_poll(C.byref(state))
        self.lib.dc_pad_clear(C.byref(state))
        f=self.lib.dc_pad_poll(C.byref(state))
        self.assertEqual((f.buttons,f.released,f.lx,f.connected),(0,3|(1<<18),0,1))
        self.lib.dc_pad_publish(C.byref(state),Raw(4,0,0,0,0))
        self.lib.dc_pad_clear(C.byref(state))
        self.assertEqual(self.lib.dc_pad_poll(C.byref(state)).buttons,0)

    def test_multitouch_slots_short_tap_and_release(self):
        state=Latch();touches=(Touch*2)(Touch(3,.2,.7),Touch(8,.8,.9))
        self.lib.dc_pad_touches(C.byref(state),touches,2)
        f=self.lib.dc_pad_poll(C.byref(state))
        self.assertEqual((f.touch_count,f.touches[0].id,f.touches[1].id),(2,3,8))
        # Lifting finger zero preserves the remaining finger.
        remaining=(Touch*1)(touches[1]);self.lib.dc_pad_touches(C.byref(state),remaining,1)
        f=self.lib.dc_pad_poll(C.byref(state))
        self.assertEqual((f.touch_count,f.touches[0].id),(1,8))
        self.lib.dc_pad_touches(C.byref(state),None,0)
        self.assertEqual(self.lib.dc_pad_poll(C.byref(state)).touch_count,0)
        self.lib.dc_pad_touches(C.byref(state),touches,1)
        self.lib.dc_pad_touches(C.byref(state),None,0)
        self.assertEqual(self.lib.dc_pad_poll(C.byref(state)).touch_count,1)
        self.assertEqual(self.lib.dc_pad_poll(C.byref(state)).touch_count,0)


if __name__ == '__main__':
    unittest.main()
