import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import library, XXModel, XXInfo, XXNode, MaterialValue, MaterialKey, ImageInfo, XAMaterialTrack, Matrix
from xx_cases import fixture, node, u32, name, material_tables, diagnostic_fixture


class NativeXXTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.lib = library()

    def test_node_hierarchy_and_separate_uv_payload_spans(self):
        for uv in range(4):
            data = fixture(uv_sets=uv)
            with XXModel(data) as model:
                self.assertEqual(model.info().record(), {"nodes": 2, "submeshes": 1, "materials": 2, "textures": 2,
                    "bones": 1, "version_bits": 0x404c28f6, "parsed_bytes": len(data),
                    "opaque_tail": {"offset": len(data), "length": 0}})
                root, child = model.at("node", 0), model.at("node", 1)
                self.assertEqual((root.parent, root.children, root.submeshes), (0xffffffff, 1, 0))
                self.assertEqual((child.parent, child.children, child.submeshes), (0, 0, 1))
                mesh = model.at("submesh", 0)
                self.assertEqual((mesh.node, mesh.material, mesh.index_count, mesh.vertex_count, mesh.uv_sets), (1, 0, 3, 3, uv))
                self.assertEqual(model.span(mesh.indices), struct.pack("<3H", 0, 1, 2))
                self.assertEqual(mesh.vertices.length, 3 * 52)
                self.assertEqual([s.length for s in mesh.extra_uv], [24 if i < uv else 0 for i in range(3)])

    def test_baseline_negates_16_components_and_preserves_power(self):
        with XXModel(fixture()) as model:
            self.assertEqual(list(model.baseline(0).components), [0.25 + i * 0.125 for i in range(16)] + [7.5])

    def test_recorded_original_last_node_name_match_and_serialized_matrix(self):
        reference=json.loads((ROOT/'tests/fixtures/node-lookup-original-vectors.json').read_text())
        for row in reference['vectors']:
            with XXModel(fixture(depth=row['depth'])) as model:
                name=bytes(b^255 for b in bytes.fromhex(row['query_hex']));result=C.c_uint32(0xffffffff)
                status=self.lib.dc_xx_find_node_encoded(model.handle,name,len(name),C.byref(result))
                if row['selected'] is None:
                    self.assertEqual((status,result.value),(6,0xffffffff))
                else:
                    self.assertEqual((status,result.value),(0,row['selected']))
                    matrix=Matrix()
                    self.assertEqual(self.lib.dc_xx_node_matrix(model.handle,result.value,C.byref(matrix)),0)
                    self.assertEqual(bytes(matrix),model.data[model.at('node',result.value).matrix_offset:][:64])
        data=bytearray(fixture())
        with XXModel(bytes(data)) as model:root=model.at('node',0).name
        data[root.offset:root.offset+root.length]=bytes(b^255 for b in b'synthetic-root\0')
        with XXModel(bytes(data)) as model:
            encoded=bytes(b^255 for b in b'synthetic-root\0');result=C.c_uint32(123)
            self.assertEqual(self.lib.dc_xx_find_node_encoded(model.handle,encoded,len(encoded),C.byref(result)),6)
            self.assertEqual(result.value,123)

    def test_recorded_original_material_loader_outputs(self):
        reference = json.loads((ROOT / "tests/fixtures/xx-material-original-vectors.json").read_text())
        digest, cases = hashlib.sha256(), 0
        for count, pattern, _, data in material_tables():
            with XXModel(data) as model:
                output = b"".join(bytes(model.baseline(i)) for i in range(count))
            for control_word in reference["x87_control_words"]:
                digest.update(struct.pack("<3I", count, pattern, control_word) + output)
                cases += 1
        self.assertEqual(cases, reference["cases"])
        self.assertEqual(digest.hexdigest(), reference["output_sha256"])

    def test_xa_encoded_target_binds_first_material_and_samples_its_baseline(self):
        data = b"\1" + u32(1) + name(b"material\0") + u32(2)
        data += struct.pack("<17fi17fi", *([0] * 17), 0, *([1] * 17), 8) + bytes(3)
        track, index, keys = XAMaterialTrack(), C.c_uint32(), (MaterialKey * 2)()
        self.assertEqual(self.lib.dc_xa_material_track_at(data, len(data), 0, C.byref(track)), 0)
        self.assertEqual(self.lib.dc_xa_load_material_keys(data, len(data), 0, keys, 2), 0)
        with XXModel(fixture(material_names=(b"other\0", b"material\0", b"material\0"))) as model:
            encoded = data[track.name_offset:track.name_offset + track.name_length]
            self.assertEqual(self.lib.dc_xx_find_material_encoded(model.handle, encoded, len(encoded), C.byref(index)), 0)
            self.assertEqual(index.value, 1)
            baseline = model.baseline(index.value)
            for frame in (-1, 4, 9):
                out = MaterialValue.from_buffer_copy(baseline)
                self.assertEqual(self.lib.dc_material_sample(keys, 2, C.byref(baseline), frame, C.byref(out)), 0)
                expected = list(baseline.components)
                if frame == 4:
                    expected = [expected[i] if i in (7, 11, 15) else 0.5 for i in range(17)]
                self.assertEqual(list(out.components), expected)

    def test_ios_embedded_checker_fixture_is_reproducible_and_decodes(self):
        from generate_xx_fixture import source
        self.assertEqual((ROOT / "ios/Native/dc_diagnostic_xx.h").read_text(), source())
        with XXModel(diagnostic_fixture()) as model:
            info, pixels = model.image(0)
            self.assertEqual((info.width, info.height), (2, 2))
            self.assertEqual(pixels, bytes((255,80,40,255, 40,220,100,255, 40,100,255,255, 250,230,100,255)))

    def test_first_encoded_c_string_match_and_case_sensitivity(self):
        with XXModel(fixture(material_names=(b"material\0", b"material\0extra"))) as model:
            result = C.c_uint32(999)
            for query, expected in ((b"material\0", 0), (b"material\0ignored", 0)):
                encoded = bytes(b ^ 255 for b in query)
                self.assertEqual(self.lib.dc_xx_find_material_encoded(model.handle, encoded, len(encoded), C.byref(result)), 0)
                self.assertEqual(result.value, expected)
            for query, status in ((b"Material\0", 6), (b"material", 3)):
                result.value = 999
                encoded = bytes(b ^ 255 for b in query)
                self.assertEqual(self.lib.dc_xx_find_material_encoded(model.handle, encoded, len(encoded), C.byref(result)), status)
                self.assertEqual(result.value, 999)

    def test_embedded_bmp_zero_signature_and_tga_rgba(self):
        with XXModel(fixture()) as model:
            for index, rgba in ((0, bytes((10, 20, 30, 255))), (1, bytes((10, 20, 30, 40)))):
                info, pixels = model.image(index)
                self.assertEqual((info.width, info.height, info.rgba_bytes), (1, 1, 4))
                self.assertEqual(pixels, rgba)
            out, info = C.create_string_buffer(b"\xa5" * 4), ImageInfo(7, 8, 9)
            self.assertEqual(self.lib.dc_xx_image_decode(model.handle, 0, out, 3, C.byref(info)), 4)
            self.assertEqual((out.raw, info.width, info.height), (b"\xa5" * 4 + b"\0", 7, 8))
            self.assertEqual(self.lib.dc_xx_image_decode(model.handle, 0, model.source, len(model.source), None), 1)

    def test_every_truncation_and_bad_tail_leave_probe_unchanged(self):
        data = fixture()
        source, info = C.create_string_buffer(data), XXInfo()
        C.memset(C.byref(info), 0xa5, C.sizeof(info))
        before = bytes(info)
        for size in range(len(data)):
            self.assertIn(self.lib.dc_xx_probe(source, size, C.byref(info)), (3, 4), size)
            self.assertEqual(bytes(info), before)
        handle = C.c_void_p(123)
        self.assertEqual(self.lib.dc_xx_open(data[:-1], len(data) - 1, C.byref(handle)), 3)
        self.assertFalse(handle)

    def test_original_unread_tail_is_retained_without_interpreting_it(self):
        prefix = fixture()
        tail = b"opaque-extension\0" * 7
        with XXModel(prefix + tail) as model:
            info = model.info()
            self.assertEqual(info.parsed_bytes, len(prefix))
            self.assertEqual(model.span(info.opaque_tail), tail)
            self.assertEqual(model.image(1)[1], bytes((10, 20, 30, 40)))

    def test_unknown_header_and_recursive_limits_are_bounded(self):
        supported = bytearray(fixture())
        struct.pack_into("<I", supported, 0, 0x404ae148)
        with XXModel(bytes(supported)) as model:
            self.assertEqual(model.info().version_bits, 0x404ae148)
        data = fixture(depth=65)
        info = XXInfo()
        self.assertEqual(self.lib.dc_xx_probe(data, len(data), C.byref(info)), 4)
        data = bytearray(fixture())
        data[0] ^= 1
        self.assertEqual(self.lib.dc_xx_probe(bytes(data), len(data), C.byref(info)), 3)
        # Root's child count is a bounded u32, not an allocation request.
        data = u32(0x404c28f6) + bytes(17) + u32(0) + u32(0xffffffff)
        self.assertEqual(self.lib.dc_xx_probe(data, len(data), C.byref(info)), 4)

    def test_invalid_handles_indices_and_outputs_preserve_values(self):
        info = XXInfo()
        self.assertEqual(self.lib.dc_xx_probe(None, 0, C.byref(info)), 1)
        self.assertEqual(self.lib.dc_xx_get_info(None, C.byref(info)), 1)
        with XXModel(fixture()) as model:
            output = XXNode()
            C.memset(C.byref(output), 0xa5, C.sizeof(output))
            before = bytes(output)
            self.assertEqual(self.lib.dc_xx_node_at(model.handle, 2, C.byref(output)), 4)
            self.assertEqual(bytes(output), before)
        self.lib.dc_xx_close(None)

    def test_outputs_must_not_overwrite_borrowed_model_source(self):
        with XXModel(fixture()) as model:
            before = model.source.raw
            for operation, kind in (("get_info", XXInfo), ("node_at", XXNode)):
                output = C.cast(model.source, C.POINTER(kind))
                function = getattr(self.lib, "dc_xx_" + operation)
                args = (model.handle, output) if operation == "get_info" else (model.handle, 0, output)
                self.assertEqual(function(*args), 1)
            self.assertEqual(self.lib.dc_xx_material_baseline(model.handle, 0,
                C.cast(model.source, C.POINTER(MaterialValue))), 1)
            self.assertEqual(self.lib.dc_xx_find_material_encoded(model.handle, b"\xff", 1,
                C.cast(model.source, C.POINTER(C.c_uint32))), 1)
            self.assertEqual(self.lib.dc_xx_image_probe(model.handle, 0,
                C.cast(model.source, C.POINTER(ImageInfo))), 1)
            self.assertEqual(self.lib.dc_xx_node_matrix(model.handle,0,
                C.cast(model.source,C.POINTER(Matrix))),1)
            self.assertEqual(self.lib.dc_xx_find_node_encoded(model.handle,b'\xff',1,
                C.cast(model.source,C.POINTER(C.c_uint32))),1)
            self.assertEqual(model.source.raw, before)


if __name__ == "__main__": unittest.main()
