"""Converter admission checks and structural reflection; tool execution is CI smoke."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from convert_effect_shaders import convert, spirv_metadata


def instruction(opcode, *operands):
    return [((len(operands) + 1) << 16) | opcode, *operands]


def words(data):
    return struct.pack("<" + "I" * len(data), *data)


class ShaderConversionTests(unittest.TestCase):
    def test_legacy_regressions_are_self_authored_and_hash_bound(self):
        import json
        root = Path(__file__).parent / "fixtures/shader-compat"
        report = json.loads((root / "fixture-report.json").read_text(encoding="utf-8"))
        self.assertTrue(report["self_authored"])
        self.assertFalse(report["original_game_inputs"])
        self.assertFalse(report["gpu_used"])
        self.assertEqual(len(report["shaders"]), 7)
        for row in report["shaders"]:
            source = (root / row["source_file"]).read_bytes()
            binary = (root / row["binary_file"]).read_bytes()
            self.assertEqual(hashlib.sha256(source).hexdigest(), row["source_sha256"])
            self.assertEqual(hashlib.sha256(binary).hexdigest(), row["sha256"])
            self.assertEqual(len(binary), row["bytes"])
            token = struct.unpack_from("<I", binary)[0]
            self.assertEqual(token >> 16, 0xfffe if row["stage"] == "vertex" else 0xffff)
            self.assertEqual(struct.unpack_from("<I", binary, len(binary) - 4)[0], 0xffff)

    def test_entry_points_and_binding_metadata(self):
        # Structural fixture only; this is deliberately not a complete shader.
        data = [0x07230203, 0x10000, 0, 20, 0]
        data += instruction(15, 0, 1, 0x6e69616d, 0)  # "main"
        data += instruction(5, 4, 0x00786574)  # "tex"
        data += instruction(71, 4, 34, 2)  # descriptor set
        data += instruction(71, 4, 33, 3)  # binding
        data += instruction(72, 2, 0, 35, 16)  # member offset
        data += instruction(59, 3, 4, 0)
        result = spirv_metadata(words(data))
        self.assertEqual(result["entry_points"], [{"execution_model": 0, "name": "main"}])
        self.assertEqual(result["variables"], [{"id": 4, "storage_class": 0,
                                              "name": "tex", "decorations": [[34, 2], [33, 3]]}])
        self.assertEqual(result["member_decorations"], [[2, 0, 35, 16]])
        self.assertEqual(result["instructions"], 6)

    def test_truncated_headers_instruction_ranges_and_strings_fail(self):
        header = [0x07230203, 0x10000, 0, 20, 0]
        bad = [b"", words(header)[:-1], words([0, *header[1:]]),
               words(header + [15]), words(header + [(8 << 16) | 15, 0]),
               words(header + instruction(15, 0, 1, 0x61616161)),
               words(header + instruction(71, 4)),
               words(header + instruction(59, 1, 2))]
        for payload in bad:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                spirv_metadata(payload)

    def test_input_rejected_before_tools_or_output_are_touched(self):
        root = Path(__file__).resolve().parents[1]
        fixture = root / "tests/fixtures/effect-synthetic.fxbin"
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
        wrong_rows = [{"status": "unverified", "sha256": digest, "bytes": fixture.stat().st_size},
                      {"status": "size_and_disassembly_pass", "sha256": "../secret", "bytes": 8}]
        with patch("convert_effect_shaders.run") as tool:
            for row in wrong_rows:
                with self.assertRaises(ValueError):
                    convert({"failed": 0, "shaders": [row]}, fixture.parent, fixture, fixture, root / "out/not-created-by-test")
            with self.assertRaises(ValueError):
                convert({"failed": 1, "shaders": []}, fixture.parent, fixture, fixture, root / "out/not-created-by-test")
            tool.assert_not_called()


if __name__ == "__main__":
    unittest.main()
