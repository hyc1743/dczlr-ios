"""Check real compiler output against independent source reflection and bounds."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from parse_dx9_effect import EffectFormatError, parse, scalar_copy_binding, shader_records

FIXTURES = Path(__file__).parent / "fixtures"


class EffectRecordTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = (FIXTURES / "effect-synthetic.fxbin").read_bytes()
        cls.reference = json.loads((FIXTURES / "effect-synthetic-reflection.json").read_text())
        cls.effect = parse(cls.binary)

    def test_compiler_fixture_identity_and_independent_parameter_reflection(self):
        self.assertEqual(hashlib.sha256(self.binary).hexdigest(), self.reference["binary_sha256"])
        self.assertEqual(hashlib.sha256((FIXTURES / "effect-synthetic.fx").read_bytes()).hexdigest(),
                         self.reference["source_sha256"])
        self.assertFalse(self.reference["gpu_used"])
        self.assertFalse(self.reference["original_game_input_used"])
        self.assertEqual(self.effect["source_sha256"], self.reference["binary_sha256"])
        self.assertEqual(self.effect["parameter_count"], len(self.reference["parameters"]))
        for actual, expected in zip(self.effect["parameters"], self.reference["parameters"]):
            shape = actual["type"]
            for key in ["name", "semantic", "type", "elements"]:
                self.assertEqual(shape[key], expected[key])
            self.assertEqual(shape["class"], expected["class_"])
            self.assertEqual(shape.get("rows", 0), expected["rows"])
            self.assertEqual(shape.get("columns", 0), expected["columns"])
            self.assertEqual(actual["flags"], expected["flags"])
            self.assertEqual(len(actual["annotations"]), expected["annotations"])
            if "words" in expected:
                self.assertEqual(actual["value"]["words"], expected["words"])

    def test_compiler_technique_passes_and_attached_shader_ranges(self):
        self.assertEqual(self.effect["technique_count"], len(self.reference["techniques"]))
        for actual, expected in zip(self.effect["techniques"], self.reference["techniques"]):
            self.assertEqual(actual["name"], expected["name"])
            self.assertEqual(len(actual["annotations"]), expected["annotations"])
            self.assertEqual([p["name"] for p in actual["passes"]], [p["name"] for p in expected["passes"]])
        fixed, shaded = self.effect["techniques"][0]["passes"]
        for operation in (0x92, 0x93):
            state = next(s for s in fixed["states"] if s["operation"] == operation)
            self.assertNotIn("binding", state)
            self.assertEqual(state["initial"]["words"], [0])
        selector = next(s["binding"] for s in shaded["states"] if s["operation"] == 0x92)
        self.assertEqual((selector["kind"], selector["parameter"]), ("parameter_array_selector", "variants"))
        self.assertEqual(selector["selector"]["parameter"], "variant")
        profiles = []
        for binding in shader_records(self.effect, self.binary):
            framed = binding["shader_framing"]
            self.assertTrue(framed["valid"])
            self.assertEqual(framed["length"], binding["bytes"])
            raw = self.binary[binding["offset"]:binding["offset"] + binding["bytes"]]
            self.assertEqual(hashlib.sha256(raw).hexdigest(), binding["sha256"])
            profiles.append(framed["profile"])
        self.assertCountEqual(profiles, ["vs_2_0", "vs_2_0", "ps_2_0"])
        self.assertTrue(all(any("Synthetic/Shaded" in owner for owner in shader["owners"])
                            for shader in shader_records(self.effect, self.binary)))

    def test_dynamic_scalar_array_and_sampler_references(self):
        states = self.effect["techniques"][0]["passes"][0]["states"]
        blend = next(s for s in states if s["operation"] == 0xd)
        self.assertEqual(blend["binding"]["kind"], "scalar_parameter_copy")
        self.assertEqual((blend["binding"]["parameter"], blend["binding"]["element"]), ("blend", 0))
        color = next(s for s in states if s["operation"] == 0x67)
        self.assertEqual((color["binding"]["parameter"], color["binding"]["element"]), ("ops", 0))
        sampler = next(s for s in states if s["operation"] == 0xb2)
        self.assertEqual(sampler["binding"]["parameter"], "base")
        base = next(p for p in self.effect["parameters"] if p["type"]["name"] == "base")
        texture = next(s for s in base["value"]["samplers"][0] if s["operation"] == 0xa4)
        self.assertEqual(texture["binding"]["parameter"], "decal")

    def test_every_truncated_fixture_and_unknown_tag_fail(self):
        for length in range(len(self.binary)):
            with self.subTest(length=length), self.assertRaises(EffectFormatError):
                parse(self.binary[:length])
        with self.assertRaises(EffectFormatError):
            parse(b"\0" * 8 + self.binary[8:])
        with self.assertRaises(EffectFormatError):
            parse(self.binary + b"\0" * 4)

    def test_corrupt_offsets_counts_and_recursive_sampler_fail_boundedly(self):
        start = 8 + struct.unpack_from("<I", self.binary, 4)[0]
        for offset in [4, start, start + 4, start + 8, start + 12, start + 16, start + 20, start + 28]:
            changed = bytearray(self.binary)
            struct.pack_into("<I", changed, offset, 0xffffffff)
            with self.subTest(offset=offset), self.assertRaises(EffectFormatError):
                parse(bytes(changed))
        base = next(p for p in self.effect["parameters"] if p["type"]["name"] == "base")
        state = base["value"]["samplers"][0][0]
        changed = bytearray(self.binary)
        # Point one sampler state at the sampler's own type/value records.
        struct.pack_into("<II", changed, state["record_offset"] + 8,
                         base["type"]["type_offset"] - 8, base["value"]["value_offset"] - 8)
        with self.assertRaisesRegex(EffectFormatError, "nesting"):
            parse(bytes(changed))

    def test_scalar_copy_rejects_corrupt_bounds_and_leaves_unknown_programs_opaque(self):
        state = next(s for s in self.effect["techniques"][0]["passes"][0]["states"] if s["operation"] == 0xd)
        binding = state["binding"]
        raw = self.binary[binding["offset"]:binding["offset"] + binding["bytes"]]
        self.assertEqual(scalar_copy_binding(raw)["parameter"], "blend")
        with self.assertRaises(EffectFormatError):
            scalar_copy_binding(raw[:-4])
        changed = bytearray(raw)
        # Replace CTAB's name offset with an invalid pointer.
        ctab = raw.index(b"CTAB") + 4
        entries = struct.unpack_from("<I", raw, ctab + 16)[0]
        struct.pack_into("<I", changed, ctab + entries, 0xffffffff)
        with self.assertRaises(EffectFormatError):
            scalar_copy_binding(bytes(changed))
        changed = bytearray(raw)
        fxlc = raw.index(b"FXLC") + 4
        struct.pack_into("<I", changed, fxlc + 4, 0x10100001)  # NEG requires later semantic work.
        self.assertIsNone(scalar_copy_binding(bytes(changed)))

    def test_shader_inventory_rejects_unrelated_input_and_wrong_stage(self):
        with self.assertRaises(EffectFormatError):
            shader_records(self.effect, self.binary + b"\0")
        changed = json.loads(json.dumps(self.effect))
        param = next(p for p in changed["parameters"] if p["type"]["name"] == "variants")
        param["type"]["type"] = 15
        with self.assertRaisesRegex(EffectFormatError, "stage"):
            shader_records(changed, self.binary)
        changed = json.loads(json.dumps(self.effect))
        selector = next(s["binding"] for s in changed["techniques"][0]["passes"][1]["states"] if s["operation"] == 0x92)
        selector["parameter"] = "decal"
        with self.assertRaisesRegex(EffectFormatError, "non-shader"):
            shader_records(changed, self.binary)


if __name__ == "__main__":
    unittest.main()
