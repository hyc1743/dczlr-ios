"""Isolate original XX material decoding; inputs and heap are self-authored.

Material loader, bytewise name decoder and checksum routine execute. Allocator
and memcpy are bounded synthetic cdecl boundaries. No original model, Windows
process, D3D or GPU executes. Compare normalized material bytes, not checksum
policy, which is outside the current native metadata reader's contract.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EBP, UC_X86_REG_EAX
from oracle_animation import OriginalAnimation, OBJECT, STACK, STOP, TARGET_SHA256
from native_core import XXModel
from xx_cases import material_tables

CURSOR, INPUT, HEAP, CALLER = 0x78f710, 0x20010000, 0x20030000, 0x30001000
CONTROL_WORD = 0x2002f000


class OriginalXXMaterials(OriginalAnimation):
    def __init__(self, path):
        # Ghidra's material function has two exact fragments; its ten-byte
        # intervening gap is deliberately absent from admitted instructions.
        super().__init__(path, {0x40aee0: 1317, 0x40b40f: 4, 0x40d770: 72, 0x40d9c0: 316},
                         fragment_ends={0x40aee0: "jmp"})
        self.uc.mem_protect(CURSOR & ~4095, 4096, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(INPUT + 4096, 0x3f000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(CALLER, 4096, UC_PROT_READ | UC_PROT_WRITE)
        code = b"\xdb\xe3\xd9\x2d" + struct.pack("<I", CONTROL_WORD)
        code += b"\xe9" + struct.pack("<i", 0x40aee0 - (CALLER + 13))
        self.uc.mem_write(CALLER, code)
        self.uc.mem_protect(CALLER, 4096, UC_PROT_READ | UC_PROT_EXEC)
        self.caller = {CALLER, CALLER + 2, CALLER + 8}

    def heap_range(self, address, length):
        return any(start <= address and address + length <= start + size for start, size in self.allocations)

    def write_guard(self, uc, access, address, size, value, context):
        if 0x10000000 <= address and address + size <= 0x10010000: return
        if (address, size) == (CURSOR, 4): return
        if size == 4 and address in (OBJECT + 0x2c0, OBJECT + 0x2c4, OBJECT + 0x2c8): return
        if self.heap_range(address, size): return
        raise RuntimeError(f"Original material write outside admitted spans: {address:#x}/{size}")

    def code_guard(self, uc, address, size, context):
        if address in self.instructions or address in self.caller: return
        if address not in (0x4233d0, 0x61dfb0):
            raise RuntimeError(f"Original left admitted material functions: {address:#x}")
        stack = uc.reg_read(UC_X86_REG_ESP)
        target = self.word(stack)
        if target not in self.instructions: raise RuntimeError("Host return outside admitted caller")
        if address == 0x4233d0:
            length = self.word(stack + 4)
            if not length or self.heap_next + length > HEAP + 0x10000: raise RuntimeError("Allocator request out of bounds")
            destination = self.heap_next
            self.heap_next = (destination + length + 15) & ~15
            self.allocations.append((destination, length))
            uc.mem_write(destination, b"\0" * length)
            uc.reg_write(UC_X86_REG_EAX, destination)
        else:
            destination, source, length = [self.word(stack + i) for i in (4, 8, 12)]
            if source != INPUT + self.word(CURSOR) or not (INPUT <= source and source + length <= INPUT + self.input_length):
                raise RuntimeError("Unexpected material source range")
            object_copy = destination in (OBJECT + 0x2c0, OBJECT + 0x2c4) and length == 4
            if not object_copy and not self.heap_range(destination, length): raise RuntimeError("Unexpected material destination range")
            uc.mem_write(destination, bytes(uc.mem_read(source, length)))
            uc.reg_write(UC_X86_REG_EAX, destination)
        uc.reg_write(UC_X86_REG_ESP, stack + 4)
        uc.reg_write(UC_X86_REG_EIP, target)

    def run_table(self, table, control_word):
        if len(table) > 65536: raise ValueError("Synthetic input too large")
        self.input_length = len(table)
        self.allocations, self.heap_next = [], HEAP
        self.uc.mem_protect(INPUT, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(INPUT, table)
        self.uc.mem_write(CONTROL_WORD, struct.pack("<H", control_word))
        self.uc.mem_protect(INPUT, 0x10000, UC_PROT_READ)
        self.uc.mem_write(OBJECT, b"\0" * 0x10000)
        self.uc.mem_write(CURSOR, b"\0" * 4)
        self.uc.mem_write(STACK, struct.pack("<3I", STOP, OBJECT, INPUT))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(CALLER, STOP, count=50000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original material table did not return within bound")
        if self.word(CURSOR) != len(table): raise RuntimeError("Material table cursor mismatch")
        count, materials = self.word(OBJECT + 0x2c4), self.word(OBJECT + 0x2c8)
        if count and not self.heap_range(materials, count * 0x134): raise RuntimeError("Material array outside heap")
        return b"".join(bytes(self.uc.mem_read(materials + i * 0x134 + 8, 68)) for i in range(count))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    args = parser.parse_args()
    original = OriginalXXMaterials(args.exe)
    digest, cases = hashlib.sha256(), 0
    for count, pattern, table, data in material_tables():
        with XXModel(data) as model:
            native = b"".join(bytes(model.baseline(i)) for i in range(count))
        for control_word in (0x27f, 0x37f):
            reference = original.run_table(table, control_word)
            if native != reference: raise ValueError("Original/native normalized material bytes differ")
            digest.update(struct.pack("<3I", count, pattern, control_word) + reference)
            cases += 1
    report = {"schema": 1, "target_sha256": TARGET_SHA256, "cases": cases, "output_sha256": digest.hexdigest(),
              "original_function_sha256": original.hashes, "x87_control_words": [0x27f, 0x37f],
              "execution": "isolated original material loader/name decoder/checksum with bounded synthetic allocator/memcpy",
              "comparison": "exact normalized 17-component material bytes on self-authored records, including signed zero",
              "exclusions": "original XX hierarchy, meshes, images, shader binding, checksum acceptance policy and GPU output",
              "original_game_resources_used": False, "game_playability": "not_verified"}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"cases": cases, "matched": True, "sha256": digest.hexdigest()}))


if __name__ == "__main__": main()
