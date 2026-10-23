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
import struct
import sys

from compile_effect_fixture import HASHES, buffer_bytes, release, method, check
from parse_dx9_effect import parse, shader_records


class ConstantTableDesc(C.Structure):
    _fields_ = [("creator", C.c_char_p), ("version", C.c_uint32), ("constants", C.c_uint32)]


class ConstantDesc(C.Structure):
    _fields_ = [("name", C.c_char_p)] + [(name, C.c_uint32) for name in (
        "register_set", "register_index", "register_count", "class_", "type",
        "rows", "columns", "elements", "struct_members", "bytes")] + [("default", C.c_void_p)]


def reflect_constants(dll, raw):
    """Read declared top-level register layouts with the actual Microsoft DLL.

    No CTAB means declarations are absent, not that assembly uses no registers.
    Members/default values are deliberately not inferred from the top-level row.
    """
    offset = 4
    has_ctab = False
    while offset + 4 <= len(raw):
        token = struct.unpack_from("<I", raw, offset)[0]
        if token & 0xffff != 0xfffe:
            break
        count = (token >> 16) & 0x7fff
        if not count or (count + 1) * 4 > len(raw) - offset:
            raise ValueError("Invalid shader comment while locating CTAB")
        has_ctab |= raw[offset + 4:offset + 8] == b"CTAB"
        offset += (count + 1) * 4
    if not has_ctab:
        return {"status": "no_ctab", "constants": [],
                "limitation": "Assembly register use is not determined from absent declarations"}
    reflect = dll.D3DXGetShaderConstantTable
    reflect.argtypes = [C.c_void_p, C.POINTER(C.c_void_p)]
    reflect.restype = C.c_long
    table = C.c_void_p()
    try:
        check(reflect(raw, C.byref(table)))
        if not table:
            raise ValueError("D3DX returned no table for declared CTAB")
        desc = ConstantTableDesc()
        check(method(table, 5, C.c_long, C.POINTER(ConstantTableDesc))(table, C.byref(desc)))
        if desc.constants > 4096:
            raise ValueError("Too many shader constants")
        rows = []
        for i in range(desc.constants):
            handle = method(table, 8, C.c_void_p, C.c_void_p, C.c_uint)(table, None, i)
            count = C.c_uint(1)
            item = ConstantDesc()
            check(method(table, 6, C.c_long, C.c_void_p, C.POINTER(ConstantDesc), C.POINTER(C.c_uint))(
                table, handle, C.byref(item), C.byref(count)))
            if count.value != 1 or not item.name:
                raise ValueError("Unexpected constant descriptor count/name")
            row = {key: getattr(item, key) for key, type_ in ConstantDesc._fields_
                   if key not in ("name", "default")}
            row.update(name=item.name.decode("ascii"), has_default=bool(item.default))
            rows.append(row)
        return {"status": "d3dx_reflected", "version": desc.version,
                "creator": desc.creator.decode("ascii") if desc.creator else None,
                "constants": rows, "limitation": "Top-level declarations only; no GPU upload or effect parameter matching proven"}
    finally:
        release(table)


def link_constants(table, effect):
    """Attach checked effect storage declarations; do not claim GPU upload.

    Matrix row/column layout differences are recorded explicitly. Generic
    effect samplers can be refined by shader sampler type, but texture sources
    still require the separate sampler-state bindings in the parsed effect.
    """
    parameters = {p["type"]["name"]: p for p in effect["parameters"]}
    for constant in table["constants"]:
        parameter = parameters.get(constant["name"])
        if parameter is None:
            raise ValueError("Shader constant has no matching effect declaration: " + constant["name"])
        shape = parameter["type"]
        if max(shape["elements"], 1) != max(constant["elements"], 1):
            raise ValueError("Shader/effect array lengths differ: " + constant["name"])
        if constant["register_set"] == 3:
            if shape["class"] != 4 or constant["class_"] != 4 or not 10 <= shape["type"] <= 14:
                raise ValueError("Shader sampler differs from effect declaration")
            if shape["type"] != 10 and shape["type"] != constant["type"]:
                raise ValueError("Shader sampler dimensions differ from effect declaration")
            constant["effect_binding"] = {"parameter": shape["name"], "kind": "sampler_declaration",
                                          "effect_type": shape["type"], "shader_type": constant["type"],
                                          "texture_source": "resolve_effect_sampler_states"}
            continue
        if constant["register_set"] != 2 or shape["type"] != constant["type"]:
            raise ValueError("Unsupported numeric register/type mapping")
        if (shape.get("rows"), shape.get("columns")) != (constant["rows"], constant["columns"]):
            raise ValueError("Shader/effect numeric dimensions differ")
        matrix = shape["class"] in (2, 3) and constant["class_"] in (2, 3)
        if shape["class"] != constant["class_"] and not matrix:
            raise ValueError("Shader/effect numeric classes differ")
        constant["effect_binding"] = {"parameter": shape["name"], "kind": "numeric_declaration",
                                      "effect_class": shape["class"], "shader_class": constant["class_"],
                                      "transpose_on_upload": matrix and shape["class"] != constant["class_"],
                                      "register_byte_offset": constant["register_index"] * 16,
                                      "register_byte_capacity": constant["register_count"] * 16,
                                      "effect_bytes": len(parameter["value"]["words"]) * 4,
                                      "padding": "apply_shader_register_layout; do_not_flat_copy_effect_storage"}


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
                        row["constant_table"] = reflect_constants(libraries[-1], raw)
                        link_constants(row["constant_table"], effect)
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
              "constant_tables_reflected": sum(r.get("constant_table", {}).get("status") == "d3dx_reflected" for r in rows),
              "without_constant_table": sum(r.get("constant_table", {}).get("status") == "no_ctab" for r in rows),
              "linked_constant_declarations": sum(len(r.get("constant_table", {}).get("constants", [])) for r in rows),
              "matrix_transpose_declarations": sum(c.get("effect_binding", {}).get("transpose_on_upload", False)
                  for r in rows for c in r.get("constant_table", {}).get("constants", [])),
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
