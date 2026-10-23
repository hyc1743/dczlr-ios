"""Compare the native PP codec to one pinned original x86 leaf function.

Only the admitted 67-byte decoder executes inside Unicorn's isolated memory.
The game entry point, Win32 APIs and game flow are never invoked. This tool is
analysis-only and is not linked into any iOS product.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import random
import struct

import capstone
from capstone.x86_const import X86_OP_IMM
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC, UC_HOOK_BLOCK
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EBP
from native_core import ROOT, library

TARGET_SHA256 = "70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07"
ENTRY = 0x004227D0
FUNCTION_BYTES = 67
STACK = 0x10008000
BUFFER = 0x20001000
STOP = 0x30000000


class OriginalCodec:
    def __init__(self, path):
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != TARGET_SHA256:
            raise ValueError("Original executable revision does not match the analyzed decoder")
        pe = struct.unpack_from("<I", data, 60)[0]
        optional = pe + 24
        if struct.unpack_from("<H", data, pe + 4)[0] != 0x14c:
            raise ValueError("Expected analyzed PE32 x86 input")
        image_base = struct.unpack_from("<I", data, optional + 28)[0]
        image_size, header_size = struct.unpack_from("<II", data, optional + 56)
        sections = struct.unpack_from("<H", data, pe + 6)[0]
        optional_size = struct.unpack_from("<H", data, pe + 20)[0]
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.uc.mem_map(image_base, (image_size + 4095) & ~4095, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(image_base, data[:header_size])
        for index in range(sections):
            offset = optional + optional_size + index * 40
            _, rva, size, raw = struct.unpack_from("<IIII", data, offset + 8)
            if size:
                self.uc.mem_write(image_base + rva, data[raw:raw + size])
        code = bytes(self.uc.mem_read(ENTRY, FUNCTION_BYTES))
        self.code_sha256 = hashlib.sha256(code).hexdigest()
        disassembler = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        disassembler.detail = True
        instructions = list(disassembler.disasm(code, ENTRY))
        addresses = {i.address for i in instructions}
        if sum(i.size for i in instructions) != FUNCTION_BYTES or instructions[-1].mnemonic != "ret":
            raise ValueError("Decoder range does not match analyzed instruction boundaries")
        for instruction in instructions:
            if instruction.mnemonic in ("call", "syscall", "sysenter", "int"):
                raise ValueError("Admitted decoder must be a leaf without OS calls")
            if instruction.mnemonic.startswith("j"):
                if instruction.operands[0].type != X86_OP_IMM or instruction.operands[0].imm not in addresses:
                    raise ValueError("Decoder control flow leaves its verified instruction range")
        self.uc.mem_protect(image_base, (image_size + 4095) & ~4095, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_map(0x10000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(0x20000000, 0x20000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(STOP, 0x1000, UC_PROT_READ | UC_PROT_EXEC)

        def guard(uc, address, size, context):
            if address < ENTRY or address + size > ENTRY + FUNCTION_BYTES:
                raise RuntimeError("Original execution left the admitted decoder")

        self.uc.hook_add(UC_HOOK_BLOCK, guard)

    def decode(self, data):
        if len(data) > 16384:
            raise ValueError("Oracle input exceeds its explicit analysis bound")
        canary = b"\xa5" * 16
        self.uc.mem_write(BUFFER - 16, canary + data + canary)
        self.uc.mem_write(STACK, struct.pack("<III", STOP, BUFFER, len(data)))
        self.uc.reg_write(UC_X86_REG_ESP, STACK)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(ENTRY, STOP, timeout=1_000_000, count=max(256, len(data) * 24 + 128))
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK + 4:
            raise RuntimeError("Original decoder did not return through the expected cdecl boundary")
        result = bytes(self.uc.mem_read(BUFFER - 16, len(data) + 32))
        if result[:16] != canary or result[-16:] != canary:
            raise RuntimeError("Original decoder wrote outside its admitted output buffer")
        return result[16:-16]


def compare(exe, data_directory=None):
    original = OriginalCodec(exe)
    lib = library()
    vectors = [("all-byte-values", bytes(range(256)))]
    random_source = random.Random(0x4227D0)
    for size in [0, 1, 2, 3, 4, 15, 16, 31, 32, 33, 63, 64, 127, 128, 255, 256, 257, 1024, 4096, 8192]:
        vectors.append(("generated-" + str(size), random_source.randbytes(size)))
    archive_vectors = 0
    if data_directory:
        for path in sorted(data_directory.glob("*.pp")):
            with path.open("rb") as source:
                header = source.read(8)
                if len(header) != 8:
                    continue
                count, size = struct.unpack("<II", header)
                if count > 65535 or 8 + 36 * count + size != path.stat().st_size:
                    continue
                vectors.append((path.name + ":name-prefix", source.read(min(count * 32, 4096))))
                source.seek(8 + 36 * count)
                vectors.append((path.name + ":payload-prefix", source.read(min(size, 256))))
                archive_vectors += 2
    digest = hashlib.sha256()
    generated_vectors = []
    canary = b"\xa5" * 16
    for label, data in vectors:
        expected = original.decode(data)
        output = C.create_string_buffer(canary + data + canary, len(data) + 32)
        status = lib.dc_pp_decode_bytes(C.c_void_p(C.addressof(output) + 16), len(data))
        if status or output.raw[:16] != canary or output.raw[-16:] != canary:
            raise RuntimeError("Native decoder violated output bounds for " + label)
        if output.raw[16:-16] != expected:
            raise RuntimeError("Native decoder disagrees with original for " + label)
        digest.update(struct.pack("<I", len(data)))
        digest.update(data)
        digest.update(expected)
        if not ":" in label:
            generated_vectors.append({"label": label, "length": len(data),
                "input_sha256": hashlib.sha256(data).hexdigest(),
                "original_output_sha256": hashlib.sha256(expected).hexdigest()})
    return {"method": "Original pinned x86 leaf executed in isolated Unicorn memory vs compiled native C",
            "original_exe_sha256": TARGET_SHA256, "function_entry": hex(ENTRY),
            "function_bytes": FUNCTION_BYTES, "function_sha256": original.code_sha256,
            "cases": len(vectors), "archive_input_cases": archive_vectors,
            "generated_vectors": generated_vectors,
            "comparison_digest": digest.hexdigest(), "all_cases_match": True,
            "native_source_sha256": hashlib.sha256((ROOT / "native/resource/dc_pp.c").read_bytes()).hexdigest(),
            "guest_process_started": False, "windows_apis_invoked": False,
            "ios_execution": "not_tested", "full_archive_loader": "not_compared", "game_playability": "not_verified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--data", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--public-vectors", type=Path,
                        help="Export only synthetic-vector digests, never game code or resource bytes")
    args = parser.parse_args()
    result = compare(args.exe, args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.public_vectors:
        public = {k: result[k] for k in ["original_exe_sha256", "function_entry", "function_bytes", "function_sha256", "generated_vectors"]}
        public.update(schema=1, generator_seed=0x4227D0,
                      method="Digests recorded from isolated original x86 decoder; synthetic inputs only")
        args.public_vectors.parent.mkdir(parents=True, exist_ok=True)
        args.public_vectors.write_text(json.dumps(public, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "generated_vectors"}))
