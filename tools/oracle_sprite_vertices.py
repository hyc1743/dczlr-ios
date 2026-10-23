"""Isolated original sprite vertex update versus portable C geometry.

Executes only four pinned original routines (vertex update, two constructors
and float-to-integer conversion). Buffer Lock/Unlock and memcpy are bounded
synthetic callbacks. Rotation/Vec2 math calls use separately hash-pinned host
Microsoft D3DX functions, not original x86 D3DX implementation. No game launch,
Windows device or GPU. Rotated XY is compared numerically, not bit-for-bit.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import random
import struct

import capstone
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EAX, UC_X86_REG_EBP, UC_X86_REG_FPCW
from compile_effect_fixture import HASHES
from native_core import SpritePose, SpriteVertex, library
from oracle_sprite_draw import TARGET_SHA256

ENTRY = 0x420a60
FUNCTIONS = {ENTRY: 1023, 0x4211e0: 14, 0x406c30: 35, 0x61e344: 117}
STACK, STOP = 0x10008000, 0x30000000
SPRITE, VBUFFER, VTABLE, OUTPUT = 0x20001000, 0x20002000, 0x20003000, 0x20004000
LOCK, UNLOCK = 0x30001000, 0x30001010


def poses():
    rng = random.Random(0x420a60)
    for angle in (0.0, -0.0, 0.125, -0.75, 1.57079637, 3.14159274):
        for i in range(64):
            yield SpritePose(
                rng.uniform(0, 1024), rng.uniform(0, 768),
                rng.uniform(-2048, 2048), rng.uniform(-2048, 2048), rng.uniform(0, 1),
                rng.choice((0, 0.5, 1, -0.25)), rng.choice((0, 0.5, 1, 1.25)),
                rng.uniform(-2, 2), rng.uniform(-2, 2),
                rng.uniform(-1, 2), angle, rng.uniform(-1, 2), rng.uniform(-1, 2), rng.uniform(-1, 2),
                rng.uniform(-1, 1), rng.uniform(0, 2), rng.uniform(-1, 1), rng.uniform(0, 2))


class VertexOracle:
    def __init__(self, exe, dll_dir):
        data = exe.read_bytes()
        if hashlib.sha256(data).hexdigest() != TARGET_SHA256:
            raise ValueError("Original executable differs from pinned analysis")
        dll = dll_dir / "D3DX9_43.dll"
        if hashlib.sha256(dll.read_bytes()).hexdigest() != HASHES[dll.name]:
            raise ValueError("Host D3DX differs from pinned analysis library")
        self.dll = C.WinDLL(str(dll.resolve()), winmode=0x1100)
        self.rotate = self.dll.D3DXMatrixRotationZ
        self.rotate.argtypes = [C.c_void_p, C.c_float]
        self.rotate.restype = C.c_void_p
        self.transform = self.dll.D3DXVec2TransformCoord
        self.transform.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p]
        self.transform.restype = C.c_void_p
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        pe = struct.unpack_from("<I", data, 60)[0]
        optional = pe + 24
        if struct.unpack_from("<H", data, pe + 4)[0] != 0x14c:
            raise ValueError("Expected fixed PE32 x86")
        base = struct.unpack_from("<I", data, optional + 28)[0]
        image_size, headers = struct.unpack_from("<II", data, optional + 56)
        image_size = (image_size + 4095) & ~4095
        self.uc.mem_map(base, image_size, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(base, data[:headers])
        count = struct.unpack_from("<H", data, pe + 6)[0]
        optional_size = struct.unpack_from("<H", data, pe + 20)[0]
        for i in range(count):
            section = optional + optional_size + i * 40
            _, rva, size, raw = struct.unpack_from("<IIII", data, section + 8)
            if size:
                self.uc.mem_write(base + rva, data[raw:raw + size])
        self.addresses = set()
        self.hashes = {}
        disassembler = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        for entry, length in FUNCTIONS.items():
            code = bytes(self.uc.mem_read(entry, length))
            ins = list(disassembler.disasm(code, entry))
            if sum(i.size for i in ins) != length or not ins[-1].mnemonic.startswith("ret"):
                raise ValueError("Function range differs from static boundaries")
            self.addresses.update(i.address for i in ins)
            self.hashes[hex(entry)] = hashlib.sha256(code).hexdigest()
        self.uc.mem_protect(base, image_size, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_map(0x10000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(0x20000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(STOP, 0x2000, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_write(VTABLE + 0x2c, struct.pack("<I", LOCK))
        self.uc.mem_write(VTABLE + 0x30, struct.pack("<I", UNLOCK))
        self.uc.mem_write(VBUFFER, struct.pack("<I", VTABLE))
        self.uc.mem_protect(0x20000000, 0x4000, UC_PROT_READ)
        self.events = []

        def return_from(uc, clean, value=0):
            stack = uc.reg_read(UC_X86_REG_ESP)
            target = struct.unpack("<I", bytes(uc.mem_read(stack, 4)))[0]
            if target not in self.addresses:
                raise RuntimeError("Callback return leaves admitted original routines")
            uc.reg_write(UC_X86_REG_ESP, stack + 4 + clean)
            uc.reg_write(UC_X86_REG_EAX, value)
            uc.reg_write(UC_X86_REG_EIP, target)

        def args(uc, count):
            return struct.unpack("<" + "I" * count, bytes(uc.mem_read(uc.reg_read(UC_X86_REG_ESP) + 4, count * 4)))

        def code_guard(uc, address, size, context):
            if address in self.addresses:
                return
            if address == LOCK:
                this, offset, length, out, flags = args(uc, 5)
                if (this, offset, length, flags) != (VBUFFER, 0, 128, 0x2000) or not STACK - 1024 <= out < STACK:
                    raise RuntimeError("Unexpected vertex lock request")
                uc.mem_write(out, struct.pack("<I", OUTPUT))
                self.events.append("lock")
                return_from(uc, 20)
            elif address == UNLOCK:
                if args(uc, 1) != (VBUFFER,):
                    raise RuntimeError("Unexpected unlock object")
                self.events.append("unlock")
                return_from(uc, 4)
            elif address == 0x61dfb0:
                dst, src, length = args(uc, 3)
                if dst != OUTPUT or length != 128 or not STACK - 1024 <= src <= STACK - 128:
                    raise RuntimeError("Memcpy outside admitted vertex result")
                uc.mem_write(dst, bytes(uc.mem_read(src, length)))
                self.events.append("copy")
                return_from(uc, 0, dst)
            elif address == 0x60ac22:
                out, angle = args(uc, 2)
                if not STACK - 1024 <= out <= STACK - 64:
                    raise RuntimeError("Rotation output outside synthetic stack")
                matrix = (C.c_float * 16)()
                radians = struct.unpack("<f", struct.pack("<I", angle))[0]
                self.rotate(matrix, radians)
                uc.mem_write(out, bytes(matrix))
                self.events.append("host_d3dx_rotation")
                return_from(uc, 8, out)
            elif address == 0x60ac58:
                out, source, matrix = args(uc, 3)
                if not all(STACK - 1024 <= p < STACK for p in (out, source, matrix)):
                    raise RuntimeError("Transform input/output outside synthetic stack")
                vector = (C.c_float * 2).from_buffer_copy(bytes(uc.mem_read(source, 8)))
                transform = (C.c_float * 16).from_buffer_copy(bytes(uc.mem_read(matrix, 64)))
                result = (C.c_float * 2)()
                self.transform(result, vector, transform)
                uc.mem_write(out, bytes(result))
                self.events.append("host_d3dx_transform")
                return_from(uc, 12, out)
            else:
                raise RuntimeError(f"Execution left admitted routines/callbacks: {address:#x}")

        def writes(uc, access, address, size, value, context):
            if 0x10000000 <= address and address + size <= 0x10010000:
                return
            raise RuntimeError("Original instruction wrote outside synthetic stack")

        self.uc.hook_add(UC_HOOK_CODE, code_guard)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, writes)

    def run(self, pose):
        sprite = struct.pack("<II", VBUFFER, 0) + bytes(pose) + b"\0" * 12
        self.uc.mem_write(SPRITE, sprite)
        self.uc.mem_write(OUTPUT - 16, b"\xa5" * 160)
        self.uc.mem_write(STACK, struct.pack("<II", STOP, SPRITE))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.reg_write(UC_X86_REG_FPCW, 0x37f)
        self.events = []
        self.uc.emu_start(ENTRY, STOP, timeout=1_000_000, count=6000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original vertex routine did not return")
        if self.events[-3:] != ["lock", "copy", "unlock"]:
            raise RuntimeError("Unexpected buffer submission order")
        if bytes(self.uc.mem_read(SPRITE, len(sprite))) != sprite:
            raise RuntimeError("Original modified its sprite input")
        result = bytes(self.uc.mem_read(OUTPUT - 16, 160))
        if result[:16] != b"\xa5" * 16 or result[-16:] != b"\xa5" * 16:
            raise RuntimeError("Vertex output canary changed")
        return result[16:-16]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--dll-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vectors", type=Path)
    args = parser.parse_args()
    original = VertexOracle(args.exe, args.dll_dir)
    lib = library()
    rows = []
    exact = rotated = 0
    max_error = 0.0
    for pose in poses():
        expected = original.run(pose)
        output = (SpriteVertex * 4)()
        if lib.dc_sprite_build_vertices(C.byref(pose), output):
            raise RuntimeError("Native rejected original-valid synthetic input")
        actual = bytes(output)
        if pose.rotation == 0:
            if actual != expected:
                raise RuntimeError(f"Zero-rotation vertices differ: {list(struct.unpack('<18f',bytes(pose)))} / {expected.hex()} / {actual.hex()}")
            exact += 1
        else:
            for i in range(4):
                a, b = struct.unpack_from("<2f", actual, i * 32), struct.unpack_from("<2f", expected, i * 32)
                for x, y in zip(a, b):
                    error = abs(x - y)
                    max_error = max(error, max_error)
                    if error > 0.001 + 1e-6 * max(abs(x), abs(y)):
                        raise RuntimeError(f"Rotated position differs: {a} / {b}")
                if actual[i * 32 + 8:i * 32 + 32] != expected[i * 32 + 8:i * 32 + 32]:
                    raise RuntimeError("Rotated non-XY vertex fields differ")
            rotated += 1
        rows.append({"pose_hex": bytes(pose).hex(), "original_vertices_hex": expected.hex()})
    report = {"schema": 1, "original_sha256": TARGET_SHA256, "functions_sha256": original.hashes,
              "zero_rotation_bit_exact_cases": exact, "rotated_numeric_cases": rotated,
              "rotated_max_absolute_xy_error": max_error, "rotated_absolute_tolerance": 0.001,
              "rotated_relative_tolerance": 1e-6, "host_rotation_reference": "hash-pinned Microsoft D3DX9_43 x64; original x86 D3DX not executed",
              "host_dll_sha256": HASHES["D3DX9_43.dll"], "gpu_execution": False,
              "game_playability": "not_verified", "vectors": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.vectors:
        # Keep a representative selection; no original instructions/resources.
        selected = {**report, "vectors": rows[::8]}
        args.vectors.write_text(json.dumps(selected, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "vectors"}))


if __name__ == "__main__":
    main()
