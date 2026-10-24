import ctypes as C
import math
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,MeshVertex,Matrix,Viewport,SpriteVertex,CameraOrbit,CameraLens,CameraMatrices
from scene_cases import matrix


def triangle(positions):
    vertices=(MeshVertex*3)()
    for v,p,uv in zip(vertices,positions,((0,0),(1,0),(.5,1))):v.position[:]=p;v.uv[:]=uv
    return vertices


class NativeMeshClipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()

    def project(self,vertices,mvp=None,viewport=None):
        mvp=mvp or matrix();viewport=viewport or Viewport(0,0,100,100,0,1)
        indices=(C.c_uint16*3)(0,1,2);count=C.c_size_t(999)
        args=(vertices,3,indices,3,C.byref(mvp),C.byref(viewport),0x80402010)
        self.assertEqual(self.lib.dc_mesh_clip_project(*args,None,0,C.byref(count)),0)
        out=(SpriteVertex*count.value)()
        self.assertEqual(self.lib.dc_mesh_clip_project(*args,out,len(out),C.byref(count)),0)
        self.assertEqual(count.value,len(out))
        return out

    def test_eye_and_near_crossing_retains_quad_and_interpolates_uv(self):
        orbit=CameraOrbit(matrix(),0,0,0,0);lens=CameraLens(math.pi/2,1,10,100,100);camera=CameraMatrices()
        self.assertEqual(self.lib.dc_camera_build(C.byref(orbit),C.byref(lens),C.byref(camera)),0)
        # The third input has W=0. Its visible edges end at the actual near
        # plane; the surviving quad has two triangles and new UV coordinates.
        vertices=triangle(((-.5,-.5,-2),(.5,-.5,-2),(0,.5,0)))
        out=self.project(vertices,camera.view_projection)
        self.assertEqual(len(out),6)
        unique={(round(v.x,4),round(v.y,4),round(v.rhw,4),round(v.u,4),round(v.v,4)) for v in out}
        self.assertEqual(unique,{(37.5,50,1,.25,.5),(37.5,62.5,.5,0,0),
                                (62.5,62.5,.5,1,0),(62.5,50,1,.75,.5)})
        self.assertTrue(all(v.diffuse==0x80402010 and 0<=v.z<=1 for v in out))
        for v in vertices:v.position[2]=2
        self.assertEqual(len(self.project(vertices,camera.view_projection)),0)

    def test_all_six_planes_clip_to_finite_viewport(self):
        for axis in range(3):
            for sign in (-1,1):
                positions=[[-.25,-.25,.5],[.25,-.25,.5],[0,.25,.5]]
                positions[0][axis]=(-2 if sign<0 else 2)
                out=self.project(triangle(positions),viewport=Viewport(10,20,100,200,.2,.8))
                self.assertGreaterEqual(len(out),3)
                for v in out:
                    self.assertTrue(10<=v.x<=110 and 20<=v.y<=220)
                    self.assertTrue(.2-1e-6<=v.z<=.8+1e-6)
                    self.assertEqual(v.rhw,1)
                    self.assertTrue(0<=v.u<=1 and 0<=v.v<=1)
        vertices=triangle(((-2,-.25,.5),(0,-.5,.5),(0,.5,.5)))
        out=self.project(vertices)
        self.assertEqual(len(out),6)
        self.assertTrue(any(v.x==0 for v in out))

    def test_fully_inside_retains_original_projection_and_index_order(self):
        vertices=triangle(((-.2,.3,.5),(.1,.25,.6),(.3,-.15,.4)))
        viewport=Viewport(5,9,300,200,.1,.9);mvp=matrix();mvp.values[15]=2
        indices=(C.c_uint16*3)(0,1,2);expected=(SpriteVertex*3)()
        self.assertEqual(self.lib.dc_mesh_project(vertices,3,indices,3,C.byref(mvp),C.byref(viewport),0x80402010,expected,3),0)
        out=self.project(vertices,mvp,viewport)
        self.assertEqual(len(out),3)
        for a,b in zip(out,expected):
            for name in ('x','y','z','rhw','u','v'):self.assertAlmostEqual(getattr(a,name),getattr(b,name),delta=2e-5)

    def test_late_errors_and_capacity_preserve_output_and_count(self):
        for kind in ('late_index','nan','capacity','overlap','zero_w','viewport','matrix_nan'):
            vertices=triangle(((-.2,.3,.5),(.1,.25,.6),(.3,-.15,.4)))
            indices=(C.c_uint16*6)(0,1,2,0,1,2);mvp=matrix();viewport=Viewport(0,0,100,100,0,1)
            out=(SpriteVertex*6)();C.memset(out,0xa5,C.sizeof(out));before=bytes(out);count=C.c_size_t(999)
            capacity=3 if kind=='capacity' else 6
            if kind=='late_index':indices[5]=99
            elif kind=='nan':vertices[2].uv[1]=float('nan')
            elif kind=='zero_w':mvp=Matrix()
            elif kind=='viewport':viewport.width=0
            elif kind=='matrix_nan':mvp.values[5]=float('nan')
            pointer=C.cast(vertices,C.POINTER(SpriteVertex)) if kind=='overlap' else out
            self.assertIn(self.lib.dc_mesh_clip_project(vertices,3,indices,6,C.byref(mvp),C.byref(viewport),0xffffffff,pointer,capacity,C.byref(count)),(1,4),kind)
            self.assertEqual(bytes(out),before,kind);self.assertEqual(count.value,999,kind)


if __name__=='__main__':unittest.main()
