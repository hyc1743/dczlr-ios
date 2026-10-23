"""Compare native animation request/query with two pinned, isolated x86 leaves.

Only request 0x004046c0 (464 bytes) and query 0x00464ab0 (69 bytes) execute.
memset and clock reads are synthetic boundaries. No game process, real asset,
graphics API or operating-system routine is invoked. Original instructions are
read from the supplied hash-pinned PE and are not saved into public fixtures.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

import capstone
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EAX, UC_X86_REG_EBP
from animation_cases import cases
from native_core import library, AnimationClip, AnimationState

TARGET_SHA256 = "70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07"
RANGES = {0x4046c0: 464, 0x464ab0: 69}
OBJECT, QUERY_OUT, STACK, STOP = 0x20000000, 0x20010000, 0x10008000, 0x30000000
GLOBAL = 0x7a6268
STUBS = {0x61dcd0: "memset", 0x4223b0: "clock"}
STATE_OFFSETS = {"previous": 0xe34c, "current": 0xe350, "pending": 0xe354,
                 "blend_start": 0x33c, "blend_end": 0x340, "blend": 0x344,
                 "frame": 0xe35c, "pending_frame": 0xe360, "fixed_frame": 0xe364}
CLIP_OFFSETS = {"first_frame": 0x48, "last_frame": 0x4c, "blend_duration": 0x5c,
                "loop": 0x50, "iterations": 0x51, "reverse": 0x58}


class OriginalAnimation:
    def __init__(self, path):
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != TARGET_SHA256:
            raise ValueError("Original input differs from pinned analyzed PE")
        pe = struct.unpack_from("<I", data, 60)[0]
        optional = pe + 24
        if struct.unpack_from("<H", data, pe + 4)[0] != 0x14c or struct.unpack_from("<H", data, optional)[0] != 0x10b:
            raise ValueError("Expected PE32 x86")
        base = struct.unpack_from("<I", data, optional + 28)[0]
        image_size, headers = struct.unpack_from("<II", data, optional + 56)
        image_size = (image_size + 4095) & ~4095
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.uc.mem_map(base, image_size, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(base, data[:headers])
        sections = optional + struct.unpack_from("<H", data, pe + 20)[0]
        for i in range(struct.unpack_from("<H", data, pe + 6)[0]):
            _, rva, size, raw = struct.unpack_from("<IIII", data, sections + 40 * i + 8)
            self.uc.mem_write(base + rva, data[raw:raw + size])
        self.instructions, self.hashes = set(), {}
        disassembler = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        for start, length in RANGES.items():
            code = bytes(self.uc.mem_read(start, length))
            instructions = list(disassembler.disasm(code, start))
            if sum(i.size for i in instructions) != length or instructions[-1].mnemonic != "ret":
                raise ValueError("Function framing differs from analyzed boundaries")
            self.instructions.update(i.address for i in instructions)
            self.hashes[hex(start)] = hashlib.sha256(code).hexdigest()
        self.uc.mem_write(GLOBAL, struct.pack("<I", OBJECT))
        self.uc.mem_protect(base, image_size, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_map(OBJECT, 0x11000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(0x10000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(STOP, 4096, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.hook_add(UC_HOOK_CODE, self.code_guard)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self.write_guard)

    def word(self, address):
        return struct.unpack("<I", bytes(self.uc.mem_read(address, 4)))[0]

    def write_guard(self, uc, access, address, size, value, context):
        if 0x10000000 <= address and address + size <= 0x10010000:
            return
        if (address, size) == (QUERY_OUT, 4):
            return
        for name, offset in STATE_OFFSETS.items():
            if (address, size) == (OBJECT + offset, 1 if name == "fixed_frame" else 4):
                return
        if size == 1 and address in [OBJECT + 0x399 + i * 0x70 for i in range(self.count)]:
            return
        raise RuntimeError(f"Original wrote outside admitted state: {address:#x}/{size}")

    def code_guard(self, uc, address, size, context):
        if address in self.instructions:
            return
        if address not in STUBS:
            raise RuntimeError(f"Execution outside admitted functions: {address:#x}")
        stack = uc.reg_read(UC_X86_REG_ESP)
        target = self.word(stack)
        if target not in self.instructions:
            raise RuntimeError("Synthetic host return leaves admitted instructions")
        if STUBS[address] == "memset":
            if [self.word(stack + i) for i in (4, 8, 12)] != [OBJECT + 0x33c, 0, 4]:
                raise RuntimeError("Unexpected memset arguments")
            uc.mem_write(OBJECT + 0x33c, b"\0" * 4)
            uc.reg_write(UC_X86_REG_EAX, OBJECT + 0x33c)
        else:
            self.clock_reads += 1
            uc.reg_write(UC_X86_REG_EAX, self.now)
        uc.reg_write(UC_X86_REG_ESP, stack + 4)
        uc.reg_write(UC_X86_REG_EIP, target)

    def execute(self, address, *arguments):
        self.uc.mem_write(STACK, struct.pack("<" + "I" * (len(arguments) + 1), STOP, *arguments))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(address, STOP, count=1000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original failed to return within admitted bound")

    def run(self, case):
        self.now, self.clock_reads = case["now"], 0
        self.count = len(case["clips"])
        self.uc.mem_write(OBJECT, b"\xa5" * 0x10000)
        for name, value in case["state"].items():
            format = "<B" if name == "fixed_frame" else "<f" if name in ("blend", "frame", "pending_frame") else "<I"
            self.uc.mem_write(OBJECT + STATE_OFFSETS[name], struct.pack(format, value))
        for i, clip in enumerate(case["clips"]):
            for name, value in clip.items():
                format = "<B" if name in ("loop", "iterations", "reverse") else "<f" if name.endswith("frame") else "<I"
                self.uc.mem_write(OBJECT + 0x348 + i * 0x70 + CLIP_OFFSETS[name], struct.pack(format, value))
        self.execute(0x4046c0, OBJECT, case["requested"], case["force"])
        state = {}
        for name, offset in STATE_OFFSETS.items():
            format = "<B" if name == "fixed_frame" else "<f" if name in ("blend", "frame", "pending_frame") else "<I"
            state[name] = struct.unpack(format, bytes(self.uc.mem_read(OBJECT + offset, struct.calcsize(format))))[0]
        iterations = [self.uc.mem_read(OBJECT + 0x399 + i * 0x70, 1)[0] for i in range(self.count)]
        self.execute(0x464ab0, QUERY_OUT)
        query = [self.word(QUERY_OUT), self.uc.reg_read(UC_X86_REG_EAX)]
        self.execute(0x464ab0, 0)
        if self.uc.reg_read(UC_X86_REG_EAX) != query[1]:
            raise RuntimeError("Optional query output changes return value")
        return {"state": state, "iterations": iterations, "query": query}


def native_result(lib, case):
    state = AnimationState(**case["state"])
    clips = (AnimationClip * len(case["clips"]))(*(AnimationClip(**clip) for clip in case["clips"]))
    if lib.dc_animation_request(C.byref(state), clips, len(clips), case["requested"], case["force"], case["now"]):
        raise ValueError("Native animation request rejected valid input")
    current, ready = C.c_uint32(), C.c_uint32()
    if lib.dc_animation_query(C.byref(state), clips, len(clips), C.byref(current), C.byref(ready)):
        raise ValueError("Native animation query rejected valid input")
    return {"state": state.record(), "iterations": [clip.iterations for clip in clips],
            "query": [current.value, ready.value]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    args = parser.parse_args()
    original, lib = OriginalAnimation(args.exe), library()
    digest, count, clock_reads = hashlib.sha256(), 0, 0
    for case in cases():
        reference, native = original.run(case), native_result(lib, case)
        if reference != native:
            raise ValueError(f"Animation mismatch: case={case}, original={reference}, native={native}")
        digest.update((json.dumps({**case, "output": reference}, sort_keys=True, separators=(",", ":")) + "\n").encode())
        count += 1
        clock_reads += original.clock_reads
    report = {"schema": 1, "target_sha256": TARGET_SHA256, "cases": count,
              "output_sha256": digest.hexdigest(), "original_function_sha256": original.hashes,
              "execution": "isolated Unicorn x86 request/query with synthetic memset and clock",
              "query_calls": count * 2, "clock_reads": clock_reads,
              "coverage": "request and current-clip loop-byte query only; XA loading, frame advancement, poses, materials and GPU excluded",
              "original_game_resources_used": False, "game_playability": "not_verified"}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"cases": count, "matched": True, "sha256": digest.hexdigest()}))


if __name__ == "__main__":
    main()
