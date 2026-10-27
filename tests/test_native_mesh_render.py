import ctypes as C
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from native_core import library,XXModel,XXMeshRenderState,PPArchive
from xx_cases import fixture

class MeshRenderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.lib=library()
    def test_subset_and_node_flags_are_independent_of_texture_alpha(self):
        data=bytearray(fixture())
        with XXModel(bytes(data)) as model:
            mesh=model.at('submesh',0);node=model.at('node',mesh.node)
        data[mesh.indices.offset-24:mesh.indices.offset-21]=bytes((0x29,42,1))
        data[node.matrix_offset+65]=1;data[node.matrix_offset+68]=30
        with XXModel(bytes(data)) as model:
            flags=XXMeshRenderState()
            self.assertEqual(self.lib.dc_xx_mesh_render_state_at(model.handle,0,C.byref(flags)),0)
            self.assertEqual(list(bytes(flags)),[1,2,1,1,42,1,30,0])
    def test_invalid_flag_and_index_do_not_modify_output(self):
        data=bytearray(fixture())
        with XXModel(bytes(data)) as model:mesh=model.at('submesh',0)
        data[mesh.indices.offset-24]=0x1c
        with XXModel(bytes(data)) as model:
            out=XXMeshRenderState.from_buffer_copy(bytes([0xa5])*8);before=bytes(out)
            self.assertEqual(self.lib.dc_xx_mesh_render_state_at(model.handle,0,C.byref(out)),3)
            self.assertEqual(bytes(out),before)
            self.assertEqual(self.lib.dc_xx_mesh_render_state_at(model.handle,1,C.byref(out)),4)
            self.assertEqual(bytes(out),before)
    def test_all_three_original_shadow_meshes_use_inverse_color(self):
        if not (ROOT/'Data/RPP_08.pp').exists():self.skipTest('private resource gate')
        with PPArchive(ROOT/'Data/RPP_08.pp') as pp:
            ids={pp.entry(i).name_bytes.decode():i for i in range(pp.count)}
            for prefix in 'bca':
                with XXModel(pp.read(ids[prefix+'m00_01.xx'])) as model:
                    matched=0
                    for i in range(model.info().submeshes):
                        node=model.at('node',model.at('submesh',i).node)
                        name=bytes(b^255 for b in model.span(node.name)).rstrip(b'\0')
                        if name!=b'z_On_kage':continue
                        flags=XXMeshRenderState();self.assertEqual(self.lib.dc_xx_mesh_render_state_at(model.handle,i,C.byref(flags)),0)
                        self.assertEqual((flags.hidden,flags.blend_mode,flags.transparent_queue,flags.priority),(0,2,1,30));matched+=1
                    self.assertEqual(matched,1)

if __name__=='__main__':unittest.main()
