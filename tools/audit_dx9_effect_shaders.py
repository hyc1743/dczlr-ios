"""Check declared original shader ranges with pinned Microsoft D3DX, without GPU.

Does not launch the original executable or run shader instructions. D3DX only
reports bytecode lengths and disassembles the explicitly recorded shaders.
Original shader assembly/optional bytecode belongs in a local ignored folder.
"""
import argparse
from collections import Counter
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys

from compile_effect_fixture import HASHES, buffer_bytes, release
from parse_dx9_effect import parse, shader_records


def audit(exe, evidence, dll_dir, output, export_bytecode=False):
    if sys.platform != "win32" or C.sizeof(C.c_void_p) != 8:
        raise ValueError("Requires Windows x64 for the pinned D3DX analysis library")
    source = exe.read_bytes()
    index = json.loads(evidence.read_text(encoding="utf-8"))
    if hashlib.sha256(source).hexdigest() != index["artifact"]["sha256"]:
        raise ValueError("Executable differs from recorded artifact")
    for filename, digest in HASHES.items():
        if hashlib.sha256((dll_dir / filename).read_bytes()).hexdigest() != digest:
            raise ValueError("Unrecognized analysis DLL: " + filename)
    libraries = [C.WinDLL(str(dll_dir / filename), winmode=0x1100) for filename in HASHES]
    size = libraries[-1].D3DXGetShaderSize
    size.argtypes = [C.c_void_p]
    size.restype = C.c_uint
    disassemble = libraries[-1].D3DXDisassembleShader
    disassemble.argtypes = [C.c_void_p, C.c_int, C.c_void_p, C.POINTER(C.c_void_p)]
    disassemble.restype = C.c_long
    output.mkdir(parents=True, exist_ok=True)
    rows, effects = [], []
    for record in index["named_resources"]:
        data = source[record["file_offset"]:record["file_offset"] + record["bytes"]]
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError("Effect range/hash mismatch")
        effect = parse(data)
        shaders = shader_records(effect, data)
        effects.append({"id": record["name"], "shader_records": len(shaders),
                        "techniques": [{"name": t["name"], "passes": len(t["passes"])} for t in effect["techniques"]]})
        for shader in shaders:
            row = {"effect": record["name"], **shader}
            raw = data[shader["offset"]:shader["offset"] + shader["bytes"]]
            oracle_size = size(raw)
            row["d3dx_reported_bytes"] = oracle_size
            if oracle_size != len(raw):
                row.update(status="failed", reason="D3DX shader size differs from declared record")
            else:
                assembly = C.c_void_p()
                try:
                    hr = disassemble(raw, 0, None, C.byref(assembly))
                    if hr < 0 or not assembly:
                        row.update(status="failed", reason=f"D3DXDisassembleShader 0x{hr & 0xffffffff:08x}")
                    else:
                        text = buffer_bytes(assembly)
                        path = output / (shader["sha256"] + ".asm")
                        path.write_bytes(text.rstrip(b"\0") + b"\n")
                        if export_bytecode:
                            (output / (shader["sha256"] + ".dx9")).write_bytes(raw)
                        row.update(status="size_and_disassembly_pass", assembly_file=path.name,
                                   assembly_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                finally:
                    release(assembly)
            rows.append(row)
    result = {"schema": 1, "artifact_sha256": index["artifact"]["sha256"],
              "method": "Structured effect ranges compared with D3DXGetShaderSize and D3DXDisassembleShader",
              "analysis_dll_sha256": HASHES, "effects": effects, "shaders": rows,
              "shader_records": len(rows), "unique_sha256": len({r["sha256"] for r in rows}),
              "profiles": dict(Counter(r["profile"] for r in rows)),
              "passed": sum(r["status"] == "size_and_disassembly_pass" for r in rows),
              "failed": sum(r["status"] == "failed" for r in rows),
              "gpu_used": False, "original_executable_launched": False,
              "shader_conversion": "not_performed", "game_playability": "not_verified"}
    (output / "shader-audit.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--dll-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--export-bytecode", action="store_true")
    args = parser.parse_args()
    result = audit(args.exe, args.evidence, args.dll_dir.resolve(strict=True), args.output, args.export_bytecode)
    print(json.dumps({k: v for k, v in result.items() if k not in ("shaders", "effects")}))
    raise SystemExit(1 if result["failed"] or not result["shader_records"] else 0)
