import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from parse_dx9_shader import parse


def words(*values):
    return struct.pack("<" + "I" * len(values), *values)


class ShaderFramingTests(unittest.TestCase):
    def test_mov_length_counts_two_operands_after_instruction(self):
        data = words(0xFFFF0200, 0x02000001, 0x800F0800, 0x80E40000, 0xFFFF)
        result = parse(data, 0)
        self.assertTrue(result["valid"])
        self.assertEqual(result["length"], len(data))
        self.assertEqual(result["instruction_count"], 1)
        self.assertEqual(len(result["instructions"][0]["operands"]), 2)

    def test_comment_payload_can_contain_end_and_version_tokens(self):
        data = words(0xFFFF0200, 0x0003FFFE, 0x42415443, 0xFFFF, 0xFFFF0200,
                     0x02000001, 0x800F0800, 0x80E40000, 0xFFFF)
        result = parse(data, 0)
        self.assertTrue(result["valid"])
        self.assertEqual(result["length"], len(data))
        self.assertEqual(result["comment_count"], 1)
        self.assertEqual(result["instructions"][0]["offset"], 20)

    def test_def_immediate_end_does_not_terminate_shader(self):
        data = words(0xFFFF0200, 0x05000051, 0xA00F0000, 0xFFFF, 0, 0, 0,
                     0x02000001, 0x800F0800, 0xA0E40000, 0xFFFF)
        result = parse(data, 0)
        self.assertTrue(result["valid"])
        self.assertEqual(result["instruction_count"], 2)
        self.assertEqual(result["length"], len(data))

    def test_invalid_tokens_and_truncation_are_rejected(self):
        for data in [words(0xFFFF0200, 0xABABAB00, 0xFFFF),
                     words(0xFFFF0200, 0x00000003, 0xFFFF),
                     words(0xFFFF0200, 0x0005FFFE, 0),
                     words(0xFFFF0200, 0x02000001, 0x800F0800),
                     words(0xFFFF0200, 0x02000001, 0x800F0800, 0x80E40000)]:
            with self.subTest(data=data.hex()):
                self.assertFalse(parse(data, 0)["valid"])
        self.assertFalse(parse(words(0xFFFF0200), -4)["valid"])

    def test_zero_operand_control_instruction_is_accepted(self):
        self.assertTrue(parse(words(0xFFFE0300, 28, 0xFFFF), 0)["valid"])


if __name__ == "__main__":
    unittest.main()
