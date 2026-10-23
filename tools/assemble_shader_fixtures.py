"""Assemble only the repository's self-authored legacy shader regression cases.

Uses pinned Microsoft analysis DLLs, records bytecode length/disassembly, and
does not create a device or execute shaders. DLLs are not redistributed.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

from compile_effect_fixture import HASHES, buffer_bytes, check, release


def assemble(directory):
    for filename, digest in HASHES.items():
        if hashlib.sha256((directory / filename).read_bytes()).hexdigest() != digest:
            raise ValueError("Analysis DLL differs from pinned input")
    libraries = [C.WinDLL(str(directory / name), winmode=0x1100) for name in HASHES]
    dll = libraries[-1]
    assembler = dll.D3DXAssembleShader
    assembler.argtypes = [C.c_void_p, C.c_uint, C.c_void_p, C.c_void_p, C.c_uint,
                          C.POINTER(C.c_void_p), C.POINTER(C.c_void_p)]
    assembler.restype = C.c_long
    get_size = dll.D3DXGetShaderSize
    get_size.argtypes = [C.c_void_p]
    get_size.restype = C.c_uint
    disassemble = dll.D3DXDisassembleShader
    disassemble.argtypes = [C.c_void_p, C.c_int, C.c_void_p, C.POINTER(C.c_void_p)]
    disassemble.restype = C.c_long
    root = Path(__file__).resolve().parents[1] / "tests/fixtures/shader-compat"
    rows = []
    for source in sorted(root.glob("*.asm")):
        text = source.read_bytes()
        binary, errors, assembly = C.c_void_p(), C.c_void_p(), C.c_void_p()
        try:
            check(assembler(text, len(text), None, None, 0, C.byref(binary), C.byref(errors)), errors)
            data = buffer_bytes(binary)
            if get_size(data) != len(data):
                raise ValueError("D3DX bytecode size differs from assembler result")
            check(disassemble(data, 0, None, C.byref(assembly)))
            token = struct.unpack_from("<I", data)[0]
            stage = "vertex" if token >> 16 == 0xfffe else "pixel"
            profile = ("vs" if stage == "vertex" else "ps") + f"_{(token >> 8) & 255}_{token & 255}"
            target = source.with_suffix(".dx9")
            target.write_bytes(data)
            rows.append({"source_file": source.name, "source_sha256": hashlib.sha256(text).hexdigest(),
                         "binary_file": target.name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
                         "disassembly_sha256": hashlib.sha256(buffer_bytes(assembly)).hexdigest(),
                         "profile": profile, "stage": stage, "status": "size_and_disassembly_pass"})
        finally:
            for obj in (assembly, errors, binary):
                release(obj)
    report = {"schema": 1, "method": "Microsoft D3DXAssembleShader with size and disassembly checks",
              "self_authored": True, "original_game_inputs": False, "gpu_used": False,
              "analysis_dll_sha256": HASHES, "shaders": rows}
    (root / "fixture-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll-dir", type=Path, required=True)
    args = parser.parse_args()
    result = assemble(args.dll_dir.resolve(strict=True))
    print(json.dumps({"self_authored_shaders": len(result["shaders"]), "gpu_used": False}))
