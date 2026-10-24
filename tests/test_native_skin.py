import ctypes as C
import json
import math
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,Matrix,MeshVertex,XXWeights,SkinBone,SkinPalette
from scene_cases import matrix
from skin_cases import cases,native_result,palette_cases,native_palette


class NativeSkinTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def test_original_palette_and_direct3d_software_vertices(self):
        reference=json.loads((ROOT/'tests/fixtures/skin-original-vectors.json').read_text())
        palettes=list(palette_cases());sources=list(cases())
        self.assertEqual(len(palettes),len(reference['palette_cases']));self.assertEqual(len(sources),len(reference['skin_cases']))
        for row in reference['palette_cases']:
            actual=native_palette(palettes[row['case']]);expected=dict(row['matrices'])
            for index,values in enumerate(actual):
                for a,b in zip(values,expected.get(index,list(matrix().values))):self.assertLessEqual(abs(a-b),5e-5*(1+abs(b)))
        for row in reference['skin_cases']:
            for mode in range(3):
                actual=native_result(sources[row['case']],mode)
                for a,b in zip(actual['screen'],row['screen']):self.assertLessEqual(abs(a-b),5e-5*(1+abs(b)))
                for a,b in zip(actual['normal'],row['normals'][mode]):self.assertLessEqual(abs(a-b),5e-5*(1+abs(b)))

    def palette(self):
        p=SkinPalette();self.assertEqual(self.lib.dc_skin_palette_init(C.byref(p)),0);return p

    def test_slot255_retains_state_and_duplicate_ids_keep_last_matrix(self):
        p=self.palette();p.world[255]=matrix(translation=(7,0,0));globals=(Matrix*2)(matrix(translation=(1,0,0)),matrix(translation=(2,0,0)))
        bad=matrix();bad.values[0]=float('nan')
        bones=(SkinBone*3)(SkinBone(0,0,matrix()),SkinBone(0,1,matrix()),SkinBone(255,0xffffffff,bad))
        self.assertEqual(self.lib.dc_skin_palette_update(C.byref(p),bones,3,globals,2),0)
        self.assertEqual(p.world[0].values[12],2);self.assertEqual(p.world[255].values[12],7)
        vertex=MeshVertex((C.c_float*3)(2,0,0),(C.c_float*3)(0,0,1),(C.c_float*2)(.25,.75))
        weights=XXWeights((C.c_float*3)(0,0,0),(C.c_uint8*4)(255,255,255,255));out=MeshVertex()
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),C.byref(vertex),C.byref(weights),1,0,C.byref(out),1),0)
        self.assertEqual(out.position[0],9);self.assertEqual(list(out.uv),[.25,.75])

    def test_normal_inverse_transpose_and_optional_normalization(self):
        p=self.palette();p.world[0].values[0]=2;p.world[0].values[5]=3;p.world[0].values[10]=4
        vertex=MeshVertex((C.c_float*3)(1,2,3),(C.c_float*3)(2,3,4),(C.c_float*2)())
        weights=XXWeights((C.c_float*3)(1,0,0),(C.c_uint8*4)(0,255,255,255));out=MeshVertex()
        for mode in range(3):
            self.assertEqual(self.lib.dc_skin_apply(C.byref(p),C.byref(vertex),C.byref(weights),1,mode,C.byref(out),1),0)
            self.assertEqual(list(out.position),[2,6,12])
            for a,b in zip(out.normal,([2,3,4],[1,1,1],[1/math.sqrt(3)]*3)[mode]):self.assertAlmostEqual(a,b,places=6)

    def test_late_palette_and_singular_normal_failures_are_atomic(self):
        p=self.palette();before=bytes(p);globals=(Matrix*1)(matrix());bones=(SkinBone*2)(SkinBone(0,0,matrix()),SkinBone(256,0,matrix()))
        self.assertEqual(self.lib.dc_skin_palette_update(C.byref(p),bones,2,globals,1),4);self.assertEqual(bytes(p),before)
        vertex=MeshVertex((C.c_float*3)(1,2,3),(C.c_float*3)(0,0,1),(C.c_float*2)())
        sources=(MeshVertex*2)(vertex,vertex);weights=(XXWeights*2)(
            XXWeights((C.c_float*3)(1,0,0),(C.c_uint8*4)(0,255,255,255)),
            XXWeights((C.c_float*3)(1,0,0),(C.c_uint8*4)(1,255,255,255)))
        p.world[1].values[0]=0;out=(MeshVertex*2)();C.memset(out,0xa5,C.sizeof(out));before=bytes(out)
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),sources,weights,2,1,out,2),4);self.assertEqual(bytes(out),before)
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),sources,weights,2,0,out,2),0)
        self.assertEqual(out[1].position[0],0)

    def test_arguments_overlap_and_nonaffine_input(self):
        p=self.palette();v=(MeshVertex*1)();w=(XXWeights*1)();w[0].weights[0]=1
        out=(MeshVertex*1)();C.memset(out,0xa5,C.sizeof(out));before=bytes(out)
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),None,None,0,0,None,0),0)
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),v,w,1,0,v,1),1)
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),v,w,1,3,out,1),4)
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),v,w,1,0,out,0),4)
        p.world[0].values[3]=1
        self.assertEqual(self.lib.dc_skin_apply(C.byref(p),v,w,1,0,out,1),3);self.assertEqual(bytes(out),before)


if __name__=='__main__':unittest.main()
