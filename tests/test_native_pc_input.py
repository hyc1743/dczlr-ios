"""Portable input contract; compiles only the independent input module."""
import ctypes as C
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import compiler_command

class Source(C.Structure):
    _fields_=[('keys',C.c_uint8*256),('mouse',C.c_uint8*3),('active',C.c_uint8)]
class Latch(C.Structure):
    _fields_=[('sources',Source*32),('previous_keys',C.c_uint8*256),
              ('previous_mouse',C.c_uint8*3),('pending_keys',C.c_uint8*256),
              ('pending_mouse',C.c_uint8*3),('x',C.c_float),('y',C.c_float),
              ('dx',C.c_int32),('dy',C.c_int32),('wheel',C.c_int32)]
class Frame(C.Structure):
    _fields_=[('keys',C.c_uint8*256),('mouse',C.c_uint8*3),
              ('x',C.c_float),('y',C.c_float),('dx',C.c_int32),
              ('dy',C.c_int32),('wheel',C.c_int32),('active',C.c_uint32)]

class NativePCInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        command=compiler_command()
        source=ROOT/'native/game/dc_pc_input.c'
        digest=hashlib.sha256('\0'.join(command).encode())
        for p in (source,ROOT/'native/include/dc_pc_input.h',ROOT/'native/include/dc_pp.h'):
            digest.update(p.read_bytes())
        ext='.dll' if sys.platform=='win32' else '.dylib' if sys.platform=='darwin' else '.so'
        target=ROOT/'out/native-core'/('pc-input-'+digest.hexdigest()[:16]+ext)
        target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists():
            flags=['-dynamiclib','-fPIC'] if sys.platform=='darwin' else ['-shared']
            if sys.platform not in ('win32','darwin'):flags+=['-fPIC']
            result=subprocess.run(command+['-std=c11','-O2','-Wall','-Wextra','-Werror',
                '-DDC_NATIVE_SHARED',*flags,'-I'+str(ROOT/'native/include'),str(source),
                '-o',str(target)],capture_output=True,text=True,timeout=180,
                env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(ROOT/'.tools/zig-cache')))
            if result.returncode:raise RuntimeError(result.stderr)
        cls.lib=C.CDLL(str(target))
        signatures={
            'init':[C.POINTER(Latch)],'clear':[C.POINTER(Latch)],
            'source':[C.POINTER(Latch),C.c_uint32,C.c_uint32],
            'key':[C.POINTER(Latch),C.c_uint32,C.c_uint32,C.c_uint32],
            'mouse':[C.POINTER(Latch),C.c_uint32,C.c_uint32,C.c_uint32],
            'pointer':[C.POINTER(Latch),C.c_uint32,C.c_float,C.c_float],
            'motion':[C.POINTER(Latch),C.c_uint32,C.c_int32,C.c_int32,C.c_int32],
            'poll':[C.POINTER(Latch),C.POINTER(Frame)],'hid_scancode':[C.c_uint32]}
        for name,args in signatures.items():
            f=getattr(cls.lib,'dc_pc_input_'+name);f.argtypes=args
            f.restype=None if name in ('init','clear') else C.c_uint32
    def setUp(self):
        self.latch=Latch();self.lib.dc_pc_input_init(C.byref(self.latch))
    def call(self,name,*args):
        return getattr(self.lib,'dc_pc_input_'+name)(C.byref(self.latch),*args)
    def poll(self):
        frame=Frame();self.assertEqual(self.call('poll',C.byref(frame)),0);return frame
    def test_complete_press_hold_release_idle_sequence(self):
        self.assertEqual((self.poll().active,self.latch.x,self.latch.y),(0,.5,.5))
        self.call('key',0,0xc8,1);self.assertEqual(self.poll().keys[0xc8],3)
        self.assertEqual(self.poll().keys[0xc8],1)
        self.call('key',0,0xc8,0);self.assertEqual(self.poll().keys[0xc8],2)
        f=self.poll();self.assertEqual((f.keys[0xc8],f.active),(0,1))
    def test_multiple_sources_cannot_release_each_other(self):
        self.call('key',0,0x1d,1);self.call('key',31,0x1d,1)
        self.call('mouse',0,0,1);self.call('mouse',31,0,1)
        f=self.poll();self.assertEqual((f.keys[0x1d],f.mouse[0]),(3,3))
        self.call('source',0,0);f=self.poll()
        self.assertEqual((f.keys[0x1d],f.mouse[0],f.active),(1,1,1))
        self.call('source',31,0);f=self.poll()
        self.assertEqual((f.keys[0x1d],f.mouse[0],f.active),(2,2,0))
    def test_subframe_taps_survive_for_keys_and_all_mouse_buttons(self):
        for key in (1,0x2c,0x9d,255):
            self.call('key',0,key,1);self.call('key',0,key,0)
        for b in range(3):self.call('mouse',1,b,1);self.call('mouse',1,b,0)
        f=self.poll();self.assertTrue(all(f.keys[k]==3 for k in (1,0x2c,0x9d,255)))
        self.assertEqual(list(f.mouse),[3,3,3])
        f=self.poll();self.assertEqual(list(f.mouse),[2,2,2])
        self.assertTrue(all(f.keys[k]==2 for k in (1,0x2c,0x9d,255)))
        self.assertEqual(list(self.poll().mouse),[0,0,0])
    def test_clear_discards_unseen_taps_but_releases_polled_controls(self):
        self.call('key',0,0x2c,1);self.call('mouse',1,2,1);self.poll()
        self.call('key',0,0x3b,1);self.call('key',0,0x3b,0)
        self.call('motion',0,4,5,120);self.call('pointer',0,.2,.8)
        self.call('clear');f=self.poll()
        self.assertEqual((f.keys[0x2c],f.keys[0x3b],list(f.mouse),f.active),(2,0,[2,0,2],0))
        self.assertEqual((f.dx,f.dy,f.wheel),(0,0,0))
        self.assertAlmostEqual(f.x,.2);self.assertAlmostEqual(f.y,.8)
        self.assertEqual(list(self.poll().mouse),[0,0,0])
    def test_original_keyboard_fallback_priority_and_release(self):
        self.call('key',0,0x2c,1);self.call('key',0,0x2d,1)
        self.assertEqual(list(self.poll().mouse),[3,3,0])
        self.assertEqual(list(self.poll().mouse),[1,1,0])
        self.call('key',0,0x2c,0);self.call('key',0,0x2d,0)
        self.assertEqual(list(self.poll().mouse),[2,2,0])
        self.call('mouse',1,0,1);self.poll();self.call('mouse',1,0,0)
        self.call('key',0,0x2c,1)
        self.assertEqual(self.poll().mouse[0],2) # physical release wins over Z press
        self.assertEqual(self.poll().mouse[0],1)
    def test_wheel_fallback_overwrites_motion_with_a_before_s(self):
        self.call('motion',0,0,0,-240);self.call('key',0,0x1e,1);self.call('key',0,0x1f,1)
        self.assertEqual(self.poll().wheel,120);self.assertEqual(self.poll().wheel,0)
        self.call('key',0,0x1f,0);self.poll();self.call('key',0,0x1f,1)
        self.assertEqual(self.poll().wheel,-120)
    def test_motion_accumulates_consumes_and_saturates(self):
        self.call('motion',0,10,-2,120);self.call('motion',1,-3,6,-240)
        self.call('pointer',1,1,0);f=self.poll()
        self.assertEqual((f.dx,f.dy,f.wheel,f.x,f.y),(7,4,-120,1,0))
        self.assertEqual((self.poll().dx,self.poll().dy,self.poll().wheel),(0,0,0))
        self.call('motion',0,2147483647,-2147483648,2147483647)
        self.call('motion',0,10,-10,100);f=self.poll()
        self.assertEqual((f.dx,f.dy,f.wheel),(2147483647,-2147483648,2147483647))
    def test_invalid_setters_are_atomic(self):
        for name,args in [('source',(32,1)),('source',(0,2)),('key',(32,1,1)),
            ('key',(0,256,1)),('key',(0,1,2)),('mouse',(0,3,1)),
            ('pointer',(0,float('nan'),0)),('pointer',(0,-.1,0)),
            ('pointer',(32,0,0)),('motion',(32,0,0,0))]:
            before=bytes(self.latch);self.assertEqual(self.call(name,*args),4)
            self.assertEqual(bytes(self.latch),before)
        self.assertEqual(self.lib.dc_pc_input_poll(None,C.byref(Frame())),1)
        self.assertEqual(self.call('poll',None),1)
    def test_hid_maps_physical_keys_not_text_or_wasd_actions(self):
        expected={4:0x1e,22:0x1f,26:0x11,27:0x2d,29:0x2c,30:2,38:0xa,39:0xb,
            40:0x1c,41:1,44:0x39,58:0x3b,67:0x44,68:0x57,69:0x58,
            79:0xcd,80:0xcb,81:0xd0,82:0xc8,88:0x9c,
            224:0x1d,225:0x2a,226:0x38,227:0xdb,228:0x9d,229:0x36,230:0xb8,231:0xdc}
        for usage,code in expected.items():self.assertEqual(self.lib.dc_pc_input_hid_scancode(usage),code)
        for usage in (0,1,3,102,223,232,0xffffffff):
            self.assertEqual(self.lib.dc_pc_input_hid_scancode(usage),0xffffffff)

if __name__=='__main__':unittest.main()
