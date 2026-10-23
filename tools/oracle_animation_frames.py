"""Isolated original numeric frame advancement with a synthetic x87 caller.

The admitted original routines are the 944-byte frame getter, the previously
verified request and current-loop query. No XA or other game resource is used.
The caller initializes x87, selects a control word and stores the returned
value as binary32, matching the separately observed pose-update caller boundary.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EBP, UC_X86_REG_EIP, UC_X86_REG_EAX
from oracle_animation import OriginalAnimation, RANGES, TARGET_SHA256
from oracle_animation import OBJECT, QUERY_OUT, STACK, STOP, STATE_OFFSETS, CLIP_OFFSETS
from animation_frame_cases import cases, native_result
from native_core import library

HARNESS, RETURN = 0x30001000, 0x30001020


class OriginalAnimationFrames(OriginalAnimation):
    def __init__(self, path, ranges=None):
        super().__init__(path, {**RANGES, 0x404bd0: 944, **(ranges or {})})
        constants = [struct.unpack("<f", bytes(self.uc.mem_read(a, 4)))[0]
                     for a in (0x62e668, 0x62e66c, 0x62e670)]
        if constants != [0.0, 1000.0, 1.0]:
            raise ValueError("Analyzed frame constants differ")
        self.uc.mem_map(HARNESS, 4096, UC_PROT_READ | UC_PROT_WRITE)
        # fninit; fldcw [QUERY_OUT+8]; jmp original frame getter
        entry = b"\xdb\xe3\xd9\x2d" + struct.pack("<I", QUERY_OUT + 8)
        entry += b"\xe9" + struct.pack("<i", 0x404bd0 - (HARNESS + 13))
        # fstp dword [QUERY_OUT+4]; jmp STOP (preserve cdecl argument stack)
        exit_code = b"\xd9\x1d" + struct.pack("<I", QUERY_OUT + 4)
        exit_code += b"\xe9" + struct.pack("<i", STOP - (RETURN + 11))
        self.uc.mem_write(HARNESS, entry)
        self.uc.mem_write(RETURN, exit_code)
        self.uc.mem_protect(HARNESS, 4096, UC_PROT_READ | UC_PROT_EXEC)
        self.caller_instructions = {HARNESS, HARNESS + 2, HARNESS + 8, RETURN, RETURN + 6}

    def code_guard(self, uc, address, size, context):
        if address in getattr(self, "caller_instructions", set()):
            return
        super().code_guard(uc, address, size, context)

    def write_guard(self, uc, access, address, size, value, context):
        if (address, size) == (QUERY_OUT + 4, 4):
            return
        super().write_guard(uc, access, address, size, value, context)

    def prepare_case(self, case):
        self.now, self.clock_reads = case["now"], 0
        self.count = len(case["clips"])
        self.uc.mem_write(OBJECT, b"\xa5" * 0x10000)
        for name, value in case["state"].items():
            fmt = "<B" if name == "fixed_frame" else "<f" if name in ("blend", "frame", "pending_frame") else "<I"
            self.uc.mem_write(OBJECT + STATE_OFFSETS[name], struct.pack(fmt, value))
        for i, clip in enumerate(case["clips"]):
            for name, value in clip.items():
                fmt = "<B" if name in ("loop", "iterations", "reverse") else "<f" if name.endswith("frame") else "<I"
                self.uc.mem_write(OBJECT + 0x348 + i * 0x70 + CLIP_OFFSETS[name], struct.pack(fmt, value))
            timing = case["timing"][i]
            for offset, fmt, name in ((0x40, "<f", "duration_seconds"), (0x52, "<B", "loop_limit"),
                                      (0x53, "<B", "chain"), (0x54, "<I", "next_clip")):
                self.uc.mem_write(OBJECT + 0x348 + i * 0x70 + offset, struct.pack(fmt, timing[name]))
        self.uc.mem_write(OBJECT + 0xe368, struct.pack("<If", case["delta"], case["speed"]))

    def run_frame(self, case, control_word):
        self.prepare_case(case)
        self.uc.mem_write(QUERY_OUT + 8, struct.pack("<H", control_word))
        self.uc.mem_write(STACK, struct.pack("<3I", RETURN, OBJECT, case["lane"]))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(HARNESS, STOP, count=10000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original frame update did not return within admitted bound")
        state = {}
        for name, offset in STATE_OFFSETS.items():
            fmt = "<B" if name == "fixed_frame" else "<f" if name in ("blend", "frame", "pending_frame") else "<I"
            state[name] = struct.unpack(fmt, bytes(self.uc.mem_read(OBJECT + offset, struct.calcsize(fmt))))[0]
        result = struct.unpack("<f", bytes(self.uc.mem_read(QUERY_OUT + 4, 4)))[0]
        iterations = [self.uc.mem_read(OBJECT + 0x399 + i * 0x70, 1)[0] for i in range(self.count)]
        self.execute(0x464ab0, QUERY_OUT)
        return {"state": state, "iterations": iterations, "returned_frame": result,
                "query": [self.word(QUERY_OUT), self.uc.reg_read(UC_X86_REG_EAX)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    args = parser.parse_args()
    original, lib = OriginalAnimationFrames(args.exe), library()
    digest, count = hashlib.sha256(), 0
    for case in cases():
        native = native_result(lib, case)
        for control_word in (0x27f, 0x37f):
            reference = original.run_frame(case, control_word)
            if reference != native:
                raise ValueError(f"Frame mismatch: cw={control_word:#x}, case={case}, original={reference}, native={native}")
            digest.update((json.dumps({**case, "control_word": control_word, "output": reference},
                          sort_keys=True, separators=(",", ":")) + "\n").encode())
            count += 1
    report = {"schema": 1, "target_sha256": TARGET_SHA256, "cases": count,
              "output_sha256": digest.hexdigest(), "original_function_sha256": original.hashes,
              "x87_control_words": [0x27f, 0x37f], "return_boundary": "synthetic caller stores original ST0 as binary32",
              "execution": "isolated numeric frame getter/request/query; synthetic memset and clock",
              "coverage": "finite synthetic records, both lanes, clamp, loops and chaining; no blend promotion, XA loading, poses, materials or GPU",
              "comparison": "exact state, iteration bytes, returned binary32 value and query",
              "original_game_resources_used": False, "game_playability": "not_verified"}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"cases": count, "matched": True, "sha256": digest.hexdigest()}))


if __name__ == "__main__":
    main()
