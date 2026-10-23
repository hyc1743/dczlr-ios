import ctypes as C
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library, Matrix, SceneNode
from scene_cases import cases,matrix


class NativeSceneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_recursive_transform_and_modifiers(self):
        reference=json.loads((ROOT/'tests/fixtures/scene-original-vectors.json').read_text())
        source=list(cases())
        for row in reference['vectors']:
            nodes,world=source[row['case']]
            out=(Matrix*len(nodes))(*(matrix(translation=(99,98,97)) for _ in nodes))
            self.assertEqual(self.lib.dc_scene_update(nodes,len(nodes),C.byref(world),out,len(out)),0)
            for actual,expected in zip(out,row['global_hex']):
                for a,b in zip(actual.values,struct.unpack('<16f',bytes.fromhex(expected))):
                    self.assertLessEqual(abs(a-b),5e-5*(1+abs(b)))

    def test_late_failure_does_not_partially_update_globals(self):
        nodes=(SceneNode*2)()
        nodes[0].parent=0xffffffff;nodes[1].parent=0
        nodes[0].local=nodes[1].local=matrix()
        out=(Matrix*2)(matrix(translation=(99,98,97)),matrix(translation=(96,95,94)))
        world=matrix();before=bytes(out)
        for invalid in ('parent','billboard','modifier','nonfinite'):
            nodes[1].parent=1 if invalid=='parent' else 0
            nodes[1].billboard=int(invalid=='billboard')
            nodes[1].modifier=9 if invalid=='modifier' else 0
            nodes[1].local=matrix()
            if invalid=='nonfinite':nodes[1].local.values[0]=float('nan')
            self.assertIn(self.lib.dc_scene_update(nodes,2,C.byref(world),out,2),(3,4))
            self.assertEqual(bytes(out),before)

    def test_hidden_subtree_preserves_globals_and_ignores_unsupported_transforms(self):
        nodes=(SceneNode*3)();world=matrix()
        for i in range(3):nodes[i].parent=0xffffffff if not i else i-1;nodes[i].local=matrix()
        nodes[0].hidden=1;nodes[2].billboard=99;nodes[1].local.values[0]=float('nan')
        out=(Matrix*3)();C.memset(out,0xa5,C.sizeof(out));before=bytes(out)
        self.assertEqual(self.lib.dc_scene_update(nodes,3,C.byref(world),out,3),0)
        self.assertEqual(bytes(out),before)

    def test_capacity_null_count_and_overlap_rejected(self):
        nodes=(SceneNode*1)();nodes[0].parent=0xffffffff;nodes[0].local=matrix()
        world=matrix();out=(Matrix*1)()
        self.assertEqual(self.lib.dc_scene_update(nodes,1,C.byref(world),out,0),4)
        self.assertEqual(self.lib.dc_scene_update(nodes,4097,C.byref(world),out,4097),1)
        self.assertEqual(self.lib.dc_scene_update(None,1,C.byref(world),out,1),1)
        self.assertEqual(self.lib.dc_scene_update(nodes,1,C.byref(world),C.cast(nodes,C.POINTER(Matrix)),1),1)
        self.assertEqual(self.lib.dc_scene_update(nodes,1,C.byref(world),C.byref(world),1),1)


if __name__=='__main__':unittest.main()
