"""Isolate the animated-track numeric path through the original frame update.

One synthetic bone has no target node. Root/material/morph/event/visibility
channels are absent. Scratch matrix constructors are synthetic no-ops followed
by the original caller's real-size zeroing boundaries; no pose interpolation,
asset or GPU executes. The original stack probe and empty-target pose walker
execute under the same instruction/write bounds as the numeric functions.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EBP, UC_X86_REG_EIP, UC_X86_REG_EAX
from oracle_animation import OBJECT, QUERY_OUT, STOP, STATE_OFFSETS, TARGET_SHA256
from oracle_animation_frames import OriginalAnimationFrames, HARNESS
from animation_tick_cases import cases, native_result
from native_core import library

TICK_ENTRY, TICK_STACK, BONES = HARNESS + 128, 0x10040000, OBJECT + 0xf000


class OriginalAnimationTick(OriginalAnimationFrames):
    def __init__(self, path):
        super().__init__(path, {0x405670: 936, 0x412c40: 935, 0x61e3c0: 61})
        self.uc.mem_map(0x10010000, 0x40000, UC_PROT_READ | UC_PROT_WRITE)
        code = b"\xdb\xe3\xd9\x2d" + struct.pack("<I", QUERY_OUT + 8)
        code += b"\xe9" + struct.pack("<i", 0x405670 - (TICK_ENTRY + 13))
        self.uc.mem_protect(HARNESS, 4096, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(TICK_ENTRY, code)
        self.uc.mem_protect(HARNESS, 4096, UC_PROT_READ | UC_PROT_EXEC)
        self.caller_instructions.update((TICK_ENTRY, TICK_ENTRY + 2, TICK_ENTRY + 8))

    def write_guard(self, uc, access, address, size, value, context):
        if 0x10000000 <= address and address + size <= 0x10050000:
            return
        if (address, size) == (OBJECT + 0xe358, 4):
            return
        super().write_guard(uc, access, address, size, value, context)

    def synthetic_return(self, uc, stack, pop=0):
        target = self.word(stack)
        if target not in self.instructions:
            raise RuntimeError("Synthetic host return leaves admitted update")
        uc.reg_write(UC_X86_REG_ESP, stack + 4 + pop)
        uc.reg_write(UC_X86_REG_EIP, target)

    def code_guard(self, uc, address, size, context):
        if address in (0x405755, 0x405766, 0x40595b):
            offset = -0x1c if address == 0x405766 else -0x14
            self.samples.append(struct.unpack("<f", bytes(uc.mem_read(uc.reg_read(UC_X86_REG_EBP) + offset, 4)))[0])
        if address == 0x406c30:
            stack = uc.reg_read(UC_X86_REG_ESP)
            destination, stride, count, constructor = [self.word(stack + i) for i in (4, 8, 12, 16)]
            if (stride, count, constructor) != (64, 1024, 0x4211e0) or not (
                    0x10000000 <= destination and destination + stride * count <= 0x10050000):
                raise RuntimeError("Unexpected scratch constructor boundary")
            self.synthetic_return(uc, stack, pop=16)
            return
        if address == 0x61dcd0:
            stack = uc.reg_read(UC_X86_REG_ESP)
            destination, value, length = [self.word(stack + i) for i in (4, 8, 12)]
            if length == 65536 and value == 0 and 0x10000000 <= destination and destination + length <= 0x10050000:
                uc.mem_write(destination, b"\0" * length)
                uc.reg_write(UC_X86_REG_EAX, destination)
                self.synthetic_return(uc, stack)
                return
        super().code_guard(uc, address, size, context)

    def run_tick(self, case, control_word):
        self.prepare_case(case)
        for offset in (0x2ec, 0x22c, 0x2cc, 0x2d4, 0xe378):
            self.uc.mem_write(OBJECT + offset, b"\0" * 4)
        self.uc.mem_write(OBJECT + 0x2dc, struct.pack("<2I", 1, BONES))
        self.uc.mem_write(BONES, b"\0" * 24)
        self.uc.mem_write(QUERY_OUT + 8, struct.pack("<H", control_word))
        self.uc.mem_write(TICK_STACK, struct.pack("<2I", STOP, OBJECT))
        self.uc.reg_write(UC_X86_REG_ESP, TICK_STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.samples = []
        self.uc.emu_start(TICK_ENTRY, STOP, count=15000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != TICK_STACK + 4:
            raise RuntimeError("Original update failed to return within admitted bound")
        state = {}
        for name, offset in STATE_OFFSETS.items():
            fmt = "<B" if name == "fixed_frame" else "<f" if name in ("blend", "frame", "pending_frame") else "<I"
            state[name] = struct.unpack(fmt, bytes(self.uc.mem_read(OBJECT + offset, struct.calcsize(fmt))))[0]
        return {"state": state,
                "iterations": [self.uc.mem_read(OBJECT + 0x399 + i * 0x70, 1)[0] for i in range(self.count)],
                "previous_frame": struct.unpack("<f", bytes(self.uc.mem_read(OBJECT + 0xe358, 4)))[0],
                "samples": self.samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    args = parser.parse_args()
    original, lib = OriginalAnimationTick(args.exe), library()
    digest, count = hashlib.sha256(), 0
    for case in cases():
        native = native_result(lib, case)
        for control_word in (0x27f, 0x37f):
            reference = original.run_tick(case, control_word)
            if reference != native:
                raise ValueError(f"Tick mismatch: cw={control_word:#x}, case={case}, original={reference}, native={native}")
            digest.update((json.dumps({**case, "control_word": control_word, "output": reference},
                          sort_keys=True, separators=(",", ":")) + "\n").encode())
            count += 1
    report = {"schema": 1, "target_sha256": TARGET_SHA256, "cases": count,
              "output_sha256": digest.hexdigest(), "original_function_sha256": original.hashes,
              "x87_control_words": [0x27f, 0x37f],
              "execution": "isolated original update, numeric getters/request/query, stack probe and empty-target pose walker",
              "coverage": "one synthetic non-null bone track with null node; root/material/morph/event/visibility channels absent; scratch constructors and memset/clock are synthetic",
              "comparison": "exact state, iteration bytes, previous frame and stored sample order",
              "original_game_resources_used": False, "game_playability": "not_verified"}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"cases": count, "matched": True, "sha256": digest.hexdigest()}))


if __name__ == "__main__":
    main()
