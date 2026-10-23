"""Declaration linking retains matrix layout and rejects unproven mappings."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from audit_dx9_effect_shaders import link_constants


class ShaderBindingTests(unittest.TestCase):
    def fixture(self):
        effect = {"parameters": [{"type": {"name": "matrix", "type": 3, "class": 2,
                    "rows": 3, "columns": 2, "elements": 0}, "value": {"words": [0] * 6}},
                  {"type": {"name": "base", "type": 10, "class": 4, "elements": 0},
                   "value": {"samplers": [[]]}}]}
        constants = [{"name": "matrix", "type": 3, "class_": 3, "rows": 3, "columns": 2,
                      "elements": 1, "register_set": 2, "register_index": 4, "register_count": 2},
                     {"name": "base", "type": 12, "class_": 4, "rows": 1, "columns": 1,
                      "elements": 1, "register_set": 3, "register_index": 1, "register_count": 1}]
        return {"constants": constants}, effect

    def test_matrix_padding_transpose_and_generic_sampler_are_explicit(self):
        table, effect = self.fixture()
        link_constants(table, effect)
        numeric, sampler = [c["effect_binding"] for c in table["constants"]]
        self.assertTrue(numeric["transpose_on_upload"])
        self.assertEqual(numeric["register_byte_offset"], 64)
        self.assertEqual(numeric["register_byte_capacity"], 32)
        self.assertEqual(numeric["effect_bytes"], 24)
        self.assertIn("do_not_flat_copy", numeric["padding"])
        self.assertEqual(sampler["texture_source"], "resolve_effect_sampler_states")
        self.assertEqual((sampler["effect_type"], sampler["shader_type"]), (10, 12))

    def test_missing_names_shapes_arrays_and_unsupported_registers_fail(self):
        table, effect = self.fixture()
        changes = [("name", "missing"), ("type", 2), ("class_", 1),
                   ("rows", 4), ("columns", 4), ("elements", 2), ("register_set", 1)]
        for key, value in changes:
            changed = deepcopy(table)
            changed["constants"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                link_constants(changed, effect)
        effect["parameters"][1]["type"]["type"] = 13
        with self.assertRaises(ValueError):
            link_constants(table, effect)


if __name__ == "__main__":
    unittest.main()
