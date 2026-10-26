"""The exact ownership/layout core used by the UIKit touch controls."""
import ctypes as C
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from native_core import library
from test_native_gamepad import Raw,Touch,Latch,Frame

MOVE,LOOK,PRIMARY,BACK,SAVE,RESET,NEXT,ZOOM_IN,ZOOM_OUT,MENU,COUNT=range(1,12)
POINTER=COUNT
class Rect(C.Structure):
    _fields_=[(n,C.c_float) for n in ('x','y','width','height')]
    def center(self):return self.x+self.width/2,self.y+self.height/2
class Layout(C.Structure):
    _fields_=[('width',C.c_float),('height',C.c_float),('gameplay',C.c_uint32),('controls',Rect*COUNT)]
class Contact(C.Structure):
    _fields_=[('id',C.c_uint64),('control',C.c_uint32)]+[(n,C.c_float) for n in ('x','y','origin_x','origin_y')]
class Controls(C.Structure):
    _fields_=[('layout',Layout),('fingers',Contact*16),('look_dx',C.c_float),('look_dy',C.c_float)]
class Snapshot(C.Structure):
    _fields_=[('pad',Raw),('touches',Touch*16),('touch_count',C.c_uint32),('held_ui',C.c_uint32)]

class TouchControlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=library();l=cls.lib
        l.dc_touch_make_layout.argtypes=[C.c_float]*6+[C.c_uint32,C.POINTER(Layout)]
        l.dc_touch_hit.argtypes=[C.POINTER(Layout),C.c_float,C.c_float];l.dc_touch_hit.restype=C.c_uint32
        for name in ('begin','move'):
            getattr(l,'dc_touch_'+name).argtypes=[C.POINTER(Controls),C.c_uint64,C.c_float,C.c_float]
        l.dc_touch_end.argtypes=[C.POINTER(Controls),C.c_uint64,C.c_uint32];l.dc_touch_end.restype=C.c_uint32
        l.dc_touch_reset.argtypes=[C.POINTER(Controls)]
        l.dc_touch_clear_motion.argtypes=[C.POINTER(Controls)]
        l.dc_touch_read.argtypes=[C.POINTER(Controls)];l.dc_touch_read.restype=Snapshot
        l.dc_pad_publish.argtypes=[C.POINTER(Latch),Raw];l.dc_pad_poll.argtypes=[C.POINTER(Latch)];l.dc_pad_poll.restype=Frame
    def state(self,game=3):
        s=Controls();self.assertEqual(self.lib.dc_touch_make_layout(956,440,62,0,62,21,game,C.byref(s.layout)),0);return s
    def begin(self,s,id,kind):
        x,y=s.layout.controls[kind].center()
        self.assertEqual(self.lib.dc_touch_begin(C.byref(s),id,x,y),0);return x,y
    def read(self,s):return self.lib.dc_touch_read(C.byref(s))
    def test_safe_area_layout_and_button_targets_at_phone_and_tablet_sizes(self):
        for w,h,l,t,r,b in ((956,440,62,0,62,21),(874,402,62,0,62,21),(667,375,0,0,0,0),(1194,834,0,24,0,20)):
            s=Controls();self.assertEqual(self.lib.dc_touch_make_layout(w,h,l,t,r,b,3,C.byref(s.layout)),0)
            for kind in range(1,COUNT):
                rect=s.layout.controls[kind];x,y=rect.center()
                self.assertGreaterEqual(rect.width,44);self.assertGreaterEqual(rect.height,44)
                self.assertGreaterEqual(rect.x,l);self.assertLessEqual(rect.x+rect.width,w-r)
                self.assertGreaterEqual(rect.y,t);self.assertLessEqual(rect.y+rect.height,h-b)
                self.assertEqual(self.lib.dc_touch_hit(C.byref(s.layout),x,y),kind)
    def test_move_look_and_action_share_three_fingers_without_game_click(self):
        s=self.state();mx,my=self.begin(s,1,MOVE);lx,ly=self.begin(s,2,LOOK);self.begin(s,3,PRIMARY)
        self.lib.dc_touch_move(C.byref(s),1,mx+50,my-20);self.lib.dc_touch_move(C.byref(s),2,lx+35,ly-10)
        f=self.read(s);self.assertGreater(f.pad.lx,0);self.assertGreater(f.pad.ly,0)
        self.assertGreater(f.pad.rx,0);self.assertEqual(f.pad.buttons&1,1);self.assertEqual(f.touch_count,0)
        self.lib.dc_touch_end(C.byref(s),3,0);f=self.read(s)
        self.assertEqual(f.pad.buttons,0);self.assertGreater(f.pad.lx,0);self.assertGreater(f.pad.rx,0)
        self.lib.dc_touch_reset(C.byref(s));self.assertEqual(bytes(self.read(s)),bytes(Snapshot()))
    def test_normal_scene_has_no_move_pad_and_camera_stops_without_new_drag(self):
        s=self.state(1);self.assertEqual(s.layout.controls[MOVE].width,0)
        x,y=self.begin(s,1,LOOK)
        self.lib.dc_touch_move(C.byref(s),1,x+8,y-4)
        self.assertGreater(self.read(s).pad.rx,0)
        self.lib.dc_touch_clear_motion(C.byref(s))
        self.assertEqual((self.read(s).pad.rx,self.read(s).pad.ry),(0,0))
        self.assertEqual(s.fingers[0].control,LOOK)
    def test_second_finger_cannot_steal_stick_and_buttons_hold_outside(self):
        s=self.state();x,y=self.begin(s,1,MOVE)
        self.assertEqual(self.lib.dc_touch_begin(C.byref(s),2,x,y),4)
        self.begin(s,3,PRIMARY);self.begin(s,4,PRIMARY)
        self.lib.dc_touch_move(C.byref(s),3,450,120);self.lib.dc_touch_end(C.byref(s),4,0)
        self.assertEqual(self.read(s).pad.buttons&1,1)
        self.lib.dc_touch_end(C.byref(s),3,1);self.assertEqual(self.read(s).pad.buttons,0)
    def test_short_save_tap_survives_the_real_gamepad_bridge(self):
        s=self.state();latch=Latch();self.begin(s,1,SAVE)
        self.lib.dc_pad_publish(C.byref(latch),self.read(s).pad)
        self.lib.dc_touch_end(C.byref(s),1,0);self.lib.dc_pad_publish(C.byref(latch),self.read(s).pad)
        self.assertEqual(self.lib.dc_pad_poll(C.byref(latch)).pressed&4,4)
        self.assertEqual(self.lib.dc_pad_poll(C.byref(latch)).released&4,4)
    def test_pointer_and_menu_are_independent_of_sticks_and_cancel_has_no_action(self):
        s=self.state();self.assertEqual(self.lib.dc_touch_begin(C.byref(s),1,450,120),0)
        f=self.read(s);self.assertEqual(f.touch_count,1);self.assertAlmostEqual(f.touches[0].x,450/956,places=5)
        self.begin(s,2,MENU);self.assertEqual(self.lib.dc_touch_end(C.byref(s),2,1),0)
        self.begin(s,2,MENU);self.assertEqual(self.lib.dc_touch_end(C.byref(s),2,0),MENU)
        self.assertEqual(self.read(s).touch_count,1)
    def test_title_has_no_hidden_movement_hits_and_invalid_input_is_atomic(self):
        s=self.state(0);self.assertEqual(self.lib.dc_touch_hit(C.byref(s.layout),140,320),POINTER)
        original=bytes(s.layout)
        self.assertEqual(self.lib.dc_touch_make_layout(float('nan'),440,0,0,0,0,1,C.byref(s.layout)),4)
        self.assertEqual(bytes(s.layout),original)
        self.assertEqual(self.lib.dc_touch_begin(C.byref(s),0,450,120),1)
        self.assertEqual(self.lib.dc_touch_begin(C.byref(s),1,-5,120),4)

if __name__=='__main__':unittest.main()
