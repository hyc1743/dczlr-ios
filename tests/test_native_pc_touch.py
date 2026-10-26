"""Exercise the same layout and contact owners that UIKit uses, including
relative dragging, lifted-pointer clicks, duplicate owners and physical input.
"""
import ctypes as C
from pathlib import Path
import math
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from native_core import library
from test_native_pc_input import Latch,Frame

class Target(C.Structure):
    _fields_=[('x',C.c_float),('y',C.c_float),('diameter',C.c_float),('code',C.c_uint32)]
class Contact(C.Structure):
    _fields_=[('id',C.c_uint64),('control',C.c_uint32),('x',C.c_float),('y',C.c_float)]
class State(C.Structure):
    _fields_=[('width',C.c_float),('height',C.c_float),('cursor_x',C.c_float),('cursor_y',C.c_float),('targets',Target*28),('contacts',Contact*16)]

class PCTouchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=library();l=cls.lib
        l.dc_pc_input_init.argtypes=[C.POINTER(Latch)]
        l.dc_pc_input_poll.argtypes=[C.POINTER(Latch),C.POINTER(Frame)]
        l.dc_pc_input_key.argtypes=[C.POINTER(Latch),C.c_uint32,C.c_uint32,C.c_uint32]
        l.dc_pc_input_pointer.argtypes=[C.POINTER(Latch),C.c_uint32,C.c_float,C.c_float]
        l.dc_pc_input_source.argtypes=[C.POINTER(Latch),C.c_uint32,C.c_uint32]
        l.dc_pc_touch_layout.argtypes=[C.POINTER(State)]+[C.c_float]*6
        l.dc_pc_touch_hit.argtypes=[C.POINTER(State),C.c_float,C.c_float];l.dc_pc_touch_hit.restype=C.c_uint32
        for fn in ('begin','move'):
            getattr(l,'dc_pc_touch_'+fn).argtypes=[C.POINTER(State),C.POINTER(Latch),C.c_uint64,C.c_float,C.c_float]
        l.dc_pc_touch_end.argtypes=[C.POINTER(State),C.POINTER(Latch),C.c_uint64]
        l.dc_pc_touch_reset.argtypes=[C.POINTER(State),C.POINTER(Latch)]
    def setUp(self):
        self.s=State(cursor_x=.5,cursor_y=.5);self.input=Latch();self.lib.dc_pc_input_init(C.byref(self.input))
        self.assertEqual(self.lib.dc_pc_touch_layout(C.byref(self.s),874,402,62,0,62,21),0)
    def call(self,fn,*args):return getattr(self.lib,'dc_pc_touch_'+fn)(C.byref(self.s),C.byref(self.input),*args)
    def begin(self,id,target):
        r=self.s.targets[target];self.assertEqual(self.call('begin',id,r.x,r.y),0)
    def poll(self):
        f=Frame();self.assertEqual(self.lib.dc_pc_input_poll(C.byref(self.input),C.byref(f)),0);return f
    def test_picture_layout_is_inside_safe_area_and_centers_hit_their_own_keys(self):
        for w,h,l,t,r,b in ((667,375,0,0,0,0),(874,402,62,0,62,21),(956,440,62,0,62,21),(1194,834,0,24,0,20)):
            self.assertEqual(self.lib.dc_pc_touch_layout(C.byref(self.s),w,h,l,t,r,b),0)
            for i,target in enumerate(self.s.targets):
                self.assertEqual(self.lib.dc_pc_touch_hit(C.byref(self.s),target.x,target.y),i)
                self.assertGreaterEqual(target.x-target.diameter/2,l-.001)
                self.assertLessEqual(target.x+target.diameter/2,w-r+.001)
                self.assertGreaterEqual(target.y-target.diameter/2,t-.001)
                self.assertLessEqual(target.y+target.diameter/2,h-b+.001)
                for other in self.s.targets[i+1:]:
                    self.assertGreaterEqual(math.hypot(target.x-other.x,target.y-other.y),(target.diameter+other.diameter)/2-.001)
            self.assertEqual(len(set(x.code for x in self.s.targets)),28)
            wheel=self.s.targets[24:28]
            self.assertTrue(all(wheel[i].y<wheel[i+1].y for i in range(3)))
    def test_slide_does_not_click_and_lifted_cursor_is_used_by_short_mouse_tap(self):
        self.assertEqual(self.call('begin',1,400,190),0)
        self.assertEqual(self.call('move',1,470,220),0)
        self.call('end',1);f=self.poll()
        self.assertTrue(f.pointer_active);self.assertEqual(list(f.mouse),[0,0,0]);self.assertGreater(f.x,.5)
        self.assertGreater(f.dx,0);self.assertGreater(f.dy,0)
        self.assertEqual((self.poll().dx,self.poll().dy),(0,0))
        x,y=f.x,f.y;self.begin(2,26);self.call('end',2);f=self.poll()
        self.assertEqual((f.mouse[0],f.x,f.y),(3,x,y));self.assertEqual(self.poll().mouse[0],2)
    def test_keys_mouse_drag_and_independent_release_work_in_one_frame(self):
        self.begin(1,22);self.begin(2,26);self.begin(3,27)
        self.call('begin',4,400,180);self.call('move',4,420,200);f=self.poll()
        self.assertEqual((f.keys[0x4d],f.mouse[0],f.mouse[1]),(3,3,3))
        self.call('end',2);f=self.poll();self.assertEqual((f.mouse[0],f.mouse[1],f.keys[0x4d]),(2,1,1))
        self.call('reset');f=self.poll();self.assertEqual((f.mouse[1],f.keys[0x4d],f.pointer_active),(2,2,0))
    def test_duplicate_fingers_do_not_release_another_finger_or_physical_key(self):
        self.begin(1,9);self.begin(2,9)
        self.lib.dc_pc_input_key(C.byref(self.input),30,0xcf,1);self.poll()
        self.call('end',1);self.assertEqual(self.poll().keys[0xcf],1)
        self.call('end',2);self.assertEqual(self.poll().keys[0xcf],1)
        self.lib.dc_pc_input_source(C.byref(self.input),30,0);self.assertEqual(self.poll().keys[0xcf],2)
    def test_second_drag_cannot_steal_pointer_and_button_does_not_change_when_sliding_outside(self):
        self.assertEqual(self.call('begin',1,400,190),0);self.assertEqual(self.call('begin',2,500,190),4)
        self.begin(3,27);self.call('move',3,450,150);self.assertEqual(self.poll().mouse[1],3)
        self.call('end',3);self.assertEqual(self.poll().mouse[1],2)
    def test_wheel_directions_and_cancel_do_not_leave_stuck_input(self):
        self.begin(1,24);self.call('end',1);self.assertEqual(self.poll().wheel,120)
        self.assertEqual(self.poll().wheel,0)
        self.begin(2,25);self.call('end',2);self.assertEqual(self.poll().wheel,-120)
        before=bytes(self.s);self.assertEqual(self.call('move',2,float('nan'),0),4);self.assertEqual(bytes(self.s),before)
    def test_resetting_virtual_pointer_does_not_deactivate_physical_pointer(self):
        self.lib.dc_pc_input_pointer(C.byref(self.input),29,.7,.3)
        self.begin(1,26);self.call('reset');self.assertTrue(self.poll().pointer_active)
        self.lib.dc_pc_input_source(C.byref(self.input),29,0);self.assertFalse(self.poll().pointer_active)
    def test_resize_cancels_unseen_taps_without_eating_physical_pending_press(self):
        self.begin(1,22);self.begin(2,26);self.call('reset');f=self.poll()
        self.assertEqual((f.keys[0x4d],f.mouse[0],f.pointer_active),(0,0,0))
        self.begin(3,22);self.lib.dc_pc_input_key(C.byref(self.input),30,0x4d,1)
        self.call('reset');self.assertEqual(self.poll().keys[0x4d],3)

if __name__=='__main__':unittest.main()
