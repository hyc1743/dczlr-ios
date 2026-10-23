"""Compile a self-authored fixture with hash-pinned Microsoft D3DX, without GPU.

Windows x64 analysis tool only. Microsoft.DXSDK.D3DX 9.29.952.8 DLLs must be
supplied under --dll-dir; they are neither installed nor redistributed here.
The compiler reflects the source before compilation, supplying an independent
metadata/default-value reference for the offline binary reader's tests.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys

HASHES = {
    "D3DCompiler_43.dll": "ffedb064adc25328b24dcf145b04045a867a5574c931516d7845babf2a08937f",
    "D3DX9_43.dll": "36b84dfa0ef9d3ff3549a7ad54d2a8032bd22c879219ee1a959137c4ef8786c4",
}


class EffectDesc(C.Structure):
    _fields_ = [("creator", C.c_char_p), ("parameters", C.c_uint),
                ("techniques", C.c_uint), ("functions", C.c_uint)]


class ParameterDesc(C.Structure):
    _fields_ = [("name", C.c_char_p), ("semantic", C.c_char_p)] + [
        (name, C.c_uint) for name in ("class_", "type", "rows", "columns", "elements",
                                    "annotations", "members", "flags", "bytes")]


class TechniqueDesc(C.Structure):
    _fields_ = [("name", C.c_char_p), ("passes", C.c_uint), ("annotations", C.c_uint)]


class PassDesc(C.Structure):
    _fields_ = [("name", C.c_char_p), ("annotations", C.c_uint),
                ("vertex", C.c_void_p), ("pixel", C.c_void_p)]


def method(obj, index, result, *args):
    table = C.cast(obj, C.POINTER(C.POINTER(C.c_void_p))).contents
    return C.WINFUNCTYPE(result, C.c_void_p, *args)(table[index])


def release(obj):
    if obj:
        method(obj, 2, C.c_ulong)(obj)


def buffer_bytes(obj):
    pointer = method(obj, 3, C.c_void_p)(obj)
    length = method(obj, 4, C.c_size_t)(obj)
    if length > 16 * 1024 * 1024:
        raise ValueError("Compiler output exceeds analysis bound")
    return C.string_at(pointer, length)


def check(hr, errors=None):
    if hr < 0:
        message = buffer_bytes(errors).decode("utf-8", errors="replace") if errors else ""
        raise ValueError(f"D3DX failed 0x{hr & 0xffffffff:08x}: {message}")


def reflect(compiler):
    desc = EffectDesc()
    check(method(compiler, 3, C.c_long, C.POINTER(EffectDesc))(compiler, C.byref(desc)))
    if desc.parameters > 256 or desc.techniques > 64:
        raise ValueError("Fixture exceeds reflection limit")
    params = []
    for i in range(desc.parameters):
        handle = method(compiler, 8, C.c_void_p, C.c_void_p, C.c_uint)(compiler, None, i)
        p = ParameterDesc()
        check(method(compiler, 4, C.c_long, C.c_void_p, C.POINTER(ParameterDesc))(compiler, handle, C.byref(p)))
        row = {key: getattr(p, key) for key in ("class_", "type", "rows", "columns", "elements", "annotations", "members", "flags")}
        row.update(name=p.name.decode("ascii"), semantic=p.semantic.decode("ascii") if p.semantic else None)
        if p.class_ <= 3:
            if p.bytes > 65536 or p.bytes % 4:
                raise ValueError("Fixture numeric data exceeds reflection limit")
            data = C.create_string_buffer(p.bytes)
            check(method(compiler, 21, C.c_long, C.c_void_p, C.c_void_p, C.c_uint)(compiler, handle, data, p.bytes))
            row["words"] = list(struct.unpack("<" + "I" * (p.bytes // 4), data.raw))
        params.append(row)
    techs = []
    for i in range(desc.techniques):
        handle = method(compiler, 12, C.c_void_p, C.c_uint)(compiler, i)
        t = TechniqueDesc()
        check(method(compiler, 5, C.c_long, C.c_void_p, C.POINTER(TechniqueDesc))(compiler, handle, C.byref(t)))
        if t.passes > 64:
            raise ValueError("Fixture has too many passes")
        passes = []
        for j in range(t.passes):
            ph = method(compiler, 14, C.c_void_p, C.c_void_p, C.c_uint)(compiler, handle, j)
            p = PassDesc()
            check(method(compiler, 6, C.c_long, C.c_void_p, C.POINTER(PassDesc))(compiler, ph, C.byref(p)))
            passes.append({"name": p.name.decode("ascii"), "annotations": p.annotations})
        techs.append({"name": t.name.decode("ascii"), "annotations": t.annotations, "passes": passes})
    return {"parameters": params, "techniques": techs}


def compile_fixture(source, directory):
    if sys.platform != "win32" or C.sizeof(C.c_void_p) != 8:
        raise ValueError("Requires Windows x64; portable tests use the recorded fixture")
    for filename, digest in HASHES.items():
        if hashlib.sha256((directory / filename).read_bytes()).hexdigest() != digest:
            raise ValueError("Unrecognized analysis DLL: " + filename)
    # Explicitly preload the compiler: D3DX loads it by basename internally.
    libraries = [C.WinDLL(str(directory / filename), winmode=0x1100) for filename in HASHES]
    fn = libraries[-1].D3DXCreateEffectCompiler
    fn.argtypes = [C.c_void_p, C.c_uint, C.c_void_p, C.c_void_p, C.c_uint,
                   C.POINTER(C.c_void_p), C.POINTER(C.c_void_p)]
    fn.restype = C.c_long
    compiler, errors, output = C.c_void_p(), C.c_void_p(), C.c_void_p()
    try:
        hr = fn(source, len(source), None, None, 0, C.byref(compiler), C.byref(errors))
        check(hr, errors)
        metadata = reflect(compiler)
        release(errors)
        errors = C.c_void_p()
        hr = method(compiler, 59, C.c_long, C.c_uint, C.POINTER(C.c_void_p), C.POINTER(C.c_void_p))(
            compiler, 0, C.byref(output), C.byref(errors))
        check(hr, errors)
        return buffer_bytes(output), metadata
    finally:
        for obj in (errors, output, compiler):
            release(obj)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll-dir", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reflection", required=True, type=Path)
    args = parser.parse_args()
    source = args.source.read_bytes()
    if not source or len(source) > 65536:
        raise ValueError("Fixture source length outside analysis limit")
    binary, reflected = compile_fixture(source, args.dll_dir.resolve(strict=True))
    report = {"schema": 1, "method": "Microsoft D3DX effect-compiler source reflection followed by CompileEffect",
              "self_authored_source": args.source.name, "source_sha256": hashlib.sha256(source).hexdigest(),
              "binary_sha256": hashlib.sha256(binary).hexdigest(), "analysis_dll_sha256": HASHES,
              "gpu_used": False, "original_game_input_used": False, **reflected}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(binary)
    args.reflection.parent.mkdir(parents=True, exist_ok=True)
    args.reflection.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("binary_sha256", "gpu_used", "original_game_input_used")}))


if __name__ == "__main__":
    main()
