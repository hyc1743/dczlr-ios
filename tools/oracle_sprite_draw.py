"""Isolate one pinned sprite draw routine; intercept every device call.

Runs only 0x00420e60's 867 analyzed instruction bytes in Unicorn, plus eight
synthetic stdcall-return stubs. Never calls a real Windows/D3D API, runs a GPU,
or launches the game. The jump table is checked against instruction boundaries.
Only the original cache byte and synthetic stack may be written by this run.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

import capstone
from capstone.x86_const import X86_OP_IMM
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn import UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EBP
from native_core import library, SpriteDraw, SpritePlan
from sprite_cases import cases

TARGET_SHA256 = "70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07"
ENTRY, LENGTH = 0x420e60, 867
CACHE, DEVICE_GLOBAL, SOFTWARE = 0x661350, 0x79f7f8, 0x79f7f0
STACK, STOP, STUBS = 0x10008000, 0x30000000, 0x30001000
SPRITE, TEXTURE_OBJECT, DEVICE, VTABLE = 0x20001000, 0x20002000, 0x20003000, 0x20004000
# vtable byte offset: (portable command kind, number of arguments excluding this)
METHODS = {0xe4: (1, 2), 0x10c: (2, 3), 0x114: (3, 3), 0x134: (4, 1),
           0x104: (5, 2), 0x190: (6, 4), 0x164: (7, 1), 0x144: (8, 3)}


class OriginalSprite:
    def __init__(self, path, baseline=False):
        entry, length = (0x41fe60, 241) if baseline else (ENTRY, LENGTH)
        self.entry = entry
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != TARGET_SHA256:
            raise ValueError("Original input differs from pinned analyzed PE")
        pe = struct.unpack_from("<I", data, 60)[0]
        optional = pe + 24
        if struct.unpack_from("<H", data, pe + 4)[0] != 0x14c:
            raise ValueError("Expected PE32 x86")
        base = struct.unpack_from("<I", data, optional + 28)[0]
        image_size, headers = struct.unpack_from("<II", data, optional + 56)
        image_size = (image_size + 4095) & ~4095
        sections = struct.unpack_from("<H", data, pe + 6)[0]
        optional_size = struct.unpack_from("<H", data, pe + 20)[0]
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.uc.mem_map(base, image_size, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(base, data[:headers])
        for i in range(sections):
            address = optional + optional_size + i * 40
            _, rva, size, raw = struct.unpack_from("<IIII", data, address + 8)
            if size:
                self.uc.mem_write(base + rva, data[raw:raw + size])
        code = bytes(self.uc.mem_read(entry, length))
        disassembler = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        disassembler.detail = True
        instructions = list(disassembler.disasm(code, entry))
        addresses = {i.address for i in instructions}
        if sum(i.size for i in instructions) != length or instructions[-1].mnemonic != "ret":
            raise ValueError("Function range differs from analyzed boundaries")
        for instruction in instructions:
            if instruction.mnemonic in ("int", "syscall", "sysenter"):
                raise ValueError("System instruction outside admitted scope")
            if instruction.mnemonic.startswith("j") and instruction.operands[0].type == X86_OP_IMM:
                if instruction.operands[0].imm not in addresses:
                    raise ValueError("Branch outside admitted function")
        table = bytes(self.uc.mem_read(entry + length, 16)) if not baseline else b""
        if not baseline and any(target not in addresses for target in struct.unpack("<4I", table)):
            raise ValueError("Switch table leaves admitted function")
        self.code_sha256 = hashlib.sha256(code).hexdigest()
        self.jump_table_sha256 = hashlib.sha256(table).hexdigest()
        self.uc.mem_protect(base, image_size, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_protect(CACHE & ~4095, 4096, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(0x10000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(0x20000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(STOP, 0x2000, UC_PROT_READ | UC_PROT_WRITE)
        self.stubs = {}
        for i, (slot, (kind, count)) in enumerate(METHODS.items()):
            target = STUBS + i * 16
            self.uc.mem_write(VTABLE + slot, struct.pack("<I", target))
            self.uc.mem_write(target, b"\x31\xc0\xc2" + struct.pack("<H", (count + 1) * 4))
            self.stubs[target] = (kind, count)
        self.uc.mem_protect(STOP, 0x2000, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_protect(VTABLE, 4096, UC_PROT_READ)
        self.uc.mem_write(DEVICE, struct.pack("<I", VTABLE))
        self.uc.mem_write(DEVICE_GLOBAL, struct.pack("<I", DEVICE))
        self.records = []

        def code_guard(uc, address, size, context):
            if entry <= address < entry + length and address in addresses:
                return
            start = address & ~15
            if start not in self.stubs or address not in (start, start + 2):
                raise RuntimeError("Execution left admitted function and device stubs")
            if address == start:
                kind, count = self.stubs[start]
                stack = uc.reg_read(UC_X86_REG_ESP)
                args = struct.unpack("<" + "I" * (count + 2), bytes(uc.mem_read(stack, (count + 2) * 4)))
                if args[0] not in addresses or args[1] != DEVICE:
                    raise RuntimeError("Unexpected COM return address or this pointer")
                self.records.append([kind, list(args[2:])])
                if len(self.records) > 17:
                    raise RuntimeError("Original emitted more than admitted command bound")

        def write_guard(uc, access, address, size, value, context):
            if address == CACHE and size == 1:
                return
            if 0x10000000 <= address and address + size <= 0x10010000:
                return
            raise RuntimeError("Original wrote outside stack and cache byte")

        self.uc.hook_add(UC_HOOK_CODE, code_guard)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, write_guard)

    def run(self, case):
        draw = case["draw"]
        sprite = bytearray(0x5c)
        texture = bytearray(0x5c)
        if draw:
            struct.pack_into("<II", sprite, 0, draw["vertex_buffer"], TEXTURE_OBJECT)
            sprite[0x50], sprite[0x58], sprite[0x59] = draw["blend_mode"], draw["hidden"], draw["point_filter"]
            struct.pack_into("<I", texture, 0x58, draw["texture"])
        self.uc.mem_write(SPRITE - 16, b"\xa5" * 16 + bytes(sprite) + b"\xa5" * 16)
        self.uc.mem_write(TEXTURE_OBJECT, bytes(texture))
        self.uc.mem_write(CACHE - 1, bytes([0xa5, case["cached_mode"], 0xa5]))
        self.uc.mem_write(SOFTWARE, bytes([draw["software_vertex"] if draw else 0]))
        self.uc.mem_write(STACK, struct.pack("<II", STOP, SPRITE if draw else 0))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.records = []
        self.uc.emu_start(self.entry, STOP, timeout=1_000_000, count=3000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original did not return through cdecl boundary")
        if bytes(self.uc.mem_read(SPRITE - 16, 0x5c + 32)) != b"\xa5" * 16 + bytes(sprite) + b"\xa5" * 16:
            raise RuntimeError("Original modified sprite or canaries")
        if bytes(self.uc.mem_read(TEXTURE_OBJECT, 0x5c)) != bytes(texture):
            raise RuntimeError("Original modified texture object")
        cache = bytes(self.uc.mem_read(CACHE - 1, 3))
        if cache[0] != 0xa5 or cache[2] != 0xa5:
            raise RuntimeError("Original overwrote cache canaries")
        return {"commands": self.records, "next_mode": cache[1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path)
    args = parser.parse_args()
    original = OriginalSprite(args.exe)
    lib = library()
    baseline = OriginalSprite(args.exe, baseline=True)
    expected_begin = baseline.run({"cached_mode": 3, "draw": None})
    begin_plan = SpritePlan()
    if lib.dc_sprite_begin_plan(C.byref(begin_plan)) or {
            "commands": begin_plan.records(), "next_mode": begin_plan.next_mode} != expected_begin:
        raise RuntimeError("Native sprite-entry plan differs from original")
    digests, counts = {}, {}
    total = 0
    for case in cases():
        expected = original.run(case)
        plan = SpritePlan()
        draw = SpriteDraw(**case["draw"]) if case["draw"] else None
        status = lib.dc_sprite_build_plan(C.byref(draw) if draw is not None else None,
                                          case["cached_mode"], C.byref(plan))
        actual = {"commands": plan.records(), "next_mode": plan.next_mode}
        if status or actual != expected:
            raise RuntimeError(f"Native differs from isolated original: {case}: {expected} != {actual}")
        key = str(case["cached_mode"])
        digests.setdefault(key, hashlib.sha256()).update((json.dumps(expected, sort_keys=True, separators=(",", ":")) + "\n").encode())
        counts[key] = counts.get(key, 0) + 1
        total += 1
    vectors = {"schema": 1, "original_sha256": TARGET_SHA256,
               "function_address": hex(ENTRY), "function_bytes": LENGTH,
               "function_sha256": original.code_sha256, "jump_table_sha256": original.jump_table_sha256,
               "generator": "sprite_cases.cases v1", "case_count": total,
               "begin_plan": {"function_address": "0x41fe60", "function_bytes": 241,
                              "function_sha256": baseline.code_sha256, **expected_begin},
               "groups": {key: {"cases": counts[key], "original_commands_sha256": value.hexdigest()} for key, value in digests.items()}}
    result = {**vectors, "method": "Isolated original sprite routine with bounded synthetic COM capture versus native C command plan",
              "all_commands_and_cache_match": True, "real_d3d_calls": False, "gpu_execution": False,
              "product_cpu_emulation": False, "game_playability": "not_verified"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.vectors:
        args.vectors.parent.mkdir(parents=True, exist_ok=True)
        args.vectors.write_text(json.dumps(vectors, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
