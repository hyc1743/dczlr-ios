"""Isolate pinned original material interpolation and one-track sampling.

Only 0x00416cd0 and 0x00416ee0 execute. All keys/baselines are self-authored.
The fallback memcpy is an exact bounded synthetic copy. Flow, writes, return
addresses and instruction budgets are guarded; no resource/OS/GPU executes.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EBP, UC_X86_REG_EIP, UC_X86_REG_EAX
from oracle_animation import OriginalAnimation, OBJECT, QUERY_OUT, STACK, STOP, TARGET_SHA256
from material_cases import cases, native_result, value
from native_core import library, MaterialKey

CALLER, TRACK, MATERIAL, KEYS = 0x30001000, OBJECT + 0x1000, OBJECT + 0x2000, OBJECT + 0x3000
SELECTED = set(range(17)) - {7, 11, 15}


class OriginalMaterial(OriginalAnimation):
    def __init__(self, path):
        super().__init__(path, {0x416cd0: 517, 0x416ee0: 252})
        self.uc.mem_map(CALLER, 4096, UC_PROT_READ | UC_PROT_WRITE)
        self.caller_instructions = set()
        for offset, entry in ((0, 0x416cd0), (128, 0x416ee0)):
            start = CALLER + offset
            code = b"\xdb\xe3\xd9\x2d" + struct.pack("<I", QUERY_OUT + 8)
            code += b"\xe9" + struct.pack("<i", entry - (start + 13))
            self.uc.mem_write(start, code)
            self.caller_instructions.update((start, start + 2, start + 8))
        self.uc.mem_protect(CALLER, 4096, UC_PROT_READ | UC_PROT_EXEC)

    def write_guard(self, uc, access, address, size, result, context):
        if 0x10000000 <= address and address + size <= 0x10010000:
            return
        relative = address - MATERIAL - 8
        if size == 4 and relative % 4 == 0 and relative // 4 in SELECTED:
            return
        raise RuntimeError(f"Material helper wrote outside admitted components: {address:#x}/{size}")

    def code_guard(self, uc, address, size, context):
        if address in self.instructions or address in self.caller_instructions:
            return
        if address != 0x61dfb0:
            raise RuntimeError(f"Material helper left admitted instructions: {address:#x}")
        stack = uc.reg_read(UC_X86_REG_ESP)
        target, destination, source, length = [self.word(stack + i) for i in (0, 4, 8, 12)]
        if target not in self.instructions or (destination, source, length) != (MATERIAL + 8, TRACK + 12, 68):
            raise RuntimeError("Unexpected material fallback copy")
        uc.mem_write(destination, bytes(uc.mem_read(source, length)))
        uc.reg_write(UC_X86_REG_EAX, destination)
        uc.reg_write(UC_X86_REG_ESP, stack + 4)
        uc.reg_write(UC_X86_REG_EIP, target)

    def run_material(self, case, control_word, pair=False):
        self.uc.mem_write(OBJECT, b"\0" * 0x10000)
        self.uc.mem_write(OBJECT + 0x2cc, struct.pack("<2I", 1, TRACK))
        self.uc.mem_write(TRACK + 8, struct.pack("<I", MATERIAL))
        self.uc.mem_write(TRACK + 12, bytes(value(case["baseline"])))
        self.uc.mem_write(TRACK + 0x50, struct.pack("<2I", len(case["keys"]), KEYS))
        key_bytes = b"".join(bytes(MaterialKey(value(k["values"]), k["frame"])) for k in case["keys"])
        if key_bytes:
            self.uc.mem_write(KEYS, key_bytes)
        self.uc.mem_write(MATERIAL, b"\xa5" * 8 + bytes(value(case["initial"])) + b"\x5a" * 16)
        self.uc.mem_write(QUERY_OUT + 8, struct.pack("<H", control_word))
        frame_bits = struct.unpack("<I", struct.pack("<f", case["frame"]))[0]
        arguments = (TRACK, 0, frame_bits) if pair else (OBJECT, frame_bits)
        self.uc.mem_write(STACK, struct.pack("<" + "I" * (1 + len(arguments)), STOP, *arguments))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(CALLER if pair else CALLER + 128, STOP, count=5000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original material call failed to return within bound")
        if bytes(self.uc.mem_read(MATERIAL, 8)) != b"\xa5" * 8 or bytes(self.uc.mem_read(MATERIAL + 76, 16)) != b"\x5a" * 16:
            raise RuntimeError("Material canary changed")
        if key_bytes and bytes(self.uc.mem_read(KEYS, len(key_bytes))) != key_bytes:
            raise RuntimeError("Input keys changed")
        return bytes(self.uc.mem_read(MATERIAL + 8, 68)).hex()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    args = parser.parse_args()
    original, lib = OriginalMaterial(args.exe), library()
    digest, count = hashlib.sha256(), 0
    totals = {"pair": 0, "track": 0}
    for case in cases():
        for pair in ((False, True) if len(case["keys"]) == 2 else (False,)):
            output = native_result(lib, case, pair)
            for control_word in (0x27f, 0x37f):
                reference = original.run_material(case, control_word, pair)
                if reference != output:
                    raise ValueError(f"Material mismatch cw={control_word:#x}, pair={pair}, case={case}, original={reference}, native={output}")
                digest.update((json.dumps({**case, "pair": pair, "control_word": control_word, "output": reference},
                              sort_keys=True, separators=(",", ":")) + "\n").encode())
                count += 1
                totals["pair" if pair else "track"] += 1
    report = {"schema": 1, "target_sha256": TARGET_SHA256, "cases": count, "calls": totals,
              "output_sha256": digest.hexdigest(), "original_function_sha256": original.hashes,
              "x87_control_words": [0x27f, 0x37f], "comparison": "exact 17-component output bytes",
              "execution": "isolated original interpolation and one-track selection with synthetic bounded fallback memcpy",
              "coverage": "self-authored finite keys; zero/one/duplicate/unordered keys, timestamps near signed limits, extrapolation and preserved components; original model binding and resources excluded",
              "original_game_resources_used": False, "game_playability": "not_verified"}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"cases": count, "matched": True, "sha256": digest.hexdigest()}))


if __name__ == "__main__":
    main()
