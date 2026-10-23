"""Isolate the pinned original 711-byte serialized clip-table loader.

Only synthetic table records are supplied. memcpy is an exact bounded byte-copy
boundary. The original 72-byte name decoder executes, while names are excluded
from the native API and comparison. Cursor, flow, return and writes are guarded.
No full XA loader, resource, original process, platform API or GPU is executed.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EBP, UC_X86_REG_EIP, UC_X86_REG_EAX
from oracle_animation import OriginalAnimation, TARGET_SHA256, OBJECT, STACK, STOP
from native_core import library, AnimationClip, AnimationTiming
from xa_cases import clip_table, fixture

ENTRY, LENGTH, CURSOR, INPUT = 0x40dc80, 711, 0x78f710, 0x20010000


class OriginalClips(OriginalAnimation):
    def __init__(self, path):
        super().__init__(path, {ENTRY: LENGTH, 0x40d770: 72})
        self.uc.mem_protect(CURSOR & ~4095, 4096, UC_PROT_READ | UC_PROT_WRITE)
        # The base harness supplies the first INPUT page for query output.
        self.uc.mem_map(INPUT + 4096, 0xf000, UC_PROT_READ | UC_PROT_WRITE)

    def write_guard(self, uc, access, address, size, value, context):
        if 0x10000000 <= address and address + size <= 0x10010000:
            return
        if (address, size) == (CURSOR, 4):
            return
        relative = address - OBJECT - 0x348
        if size == 1 and 0 <= relative < 512 * 112 and relative % 112 < 64:
            return
        raise RuntimeError(f"Original wrote outside clip cursor/stack: {address:#x}/{size}")

    def code_guard(self, uc, address, size, context):
        if address == 0x40d770:
            stack = uc.reg_read(UC_X86_REG_ESP)
            destination, length = self.word(stack + 4), self.word(stack + 8)
            if length != 64 or (destination - OBJECT - 0x348) % 112 != 0 or not (
                    OBJECT + 0x348 <= destination < OBJECT + 0xe348):
                raise RuntimeError("Unexpected name decoder arguments")
        if address in self.instructions:
            return
        if address != 0x61dfb0:
            raise RuntimeError(f"Original left admitted clip loader: {address:#x}")
        stack = uc.reg_read(UC_X86_REG_ESP)
        target, destination, length = self.word(stack), self.word(stack + 4), self.word(stack + 8)
        if target not in self.instructions:
            raise RuntimeError("Synthetic boundary return leaves clip loader")
        if address == 0x61dfb0:
            source, length = self.word(stack + 8), self.word(stack + 12)
            if length not in (1, 4, 64) or source != INPUT + self.word(CURSOR) or not (
                    INPUT <= source and source + length <= INPUT + self.input_length and
                    OBJECT + 0x348 <= destination and destination + length <= OBJECT + 0xe348):
                raise RuntimeError("Original clip copy left admitted spans")
            uc.mem_write(destination, bytes(uc.mem_read(source, length)))
            uc.reg_write(UC_X86_REG_EAX, destination)
        uc.reg_write(UC_X86_REG_ESP, stack + 4)
        uc.reg_write(UC_X86_REG_EIP, target)

    def run_table(self, table):
        self.input_length = len(table)
        self.uc.mem_write(INPUT, table)
        self.uc.mem_protect(INPUT, 0x10000, UC_PROT_READ)
        self.uc.mem_write(OBJECT, b"\0" * 0x10000)
        self.uc.mem_write(CURSOR, b"\0" * 4)
        self.uc.mem_write(STACK, struct.pack("<3I", STOP, OBJECT, INPUT))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(ENTRY, STOP, count=2000000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original clip loader did not return within bound")
        if self.word(CURSOR) != len(table):
            raise RuntimeError("Original clip loader consumed a different table size")
        clips, timing = bytearray(), bytearray()
        for i in range(512):
            record = bytes(self.uc.mem_read(OBJECT + 0x348 + i * 112, 112))
            clips.extend(record[72:80] + record[92:96] + bytes((record[80], record[81], record[88], 0)))
            timing.extend(record[64:68] + record[84:88] + bytes((record[82], record[83], 0, 0)))
        return bytes(clips), bytes(timing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    args = parser.parse_args()
    original, lib = OriginalClips(args.exe), library()
    table = clip_table()
    expected = original.run_table(table)
    data, _ = fixture(all_sections=False, table=table)
    clips, timing = (AnimationClip * 512)(), (AnimationTiming * 512)()
    if lib.dc_xa_load_clips(data, len(data), clips, timing, 512) or (bytes(clips), bytes(timing)) != expected:
        raise ValueError("Native numeric clip descriptors differ from original loader")
    digest = hashlib.sha256(expected[0] + expected[1]).hexdigest()
    report = {"schema": 1, "target_sha256": TARGET_SHA256, "records": 512,
              "output_sha256": digest, "original_function_sha256": original.hashes,
              "execution": "isolated original clip loader and name decoder; synthetic bounded memcpy",
              "coverage": "numeric table fields with fresh zero iteration bytes; full XA prefix, names and key payload semantics excluded",
              "source": "self-authored synthetic records including special float bit patterns",
              "original_game_resources_used": False, "game_playability": "not_verified"}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"records": 512, "matched": True, "sha256": digest}))


if __name__ == "__main__":
    main()
