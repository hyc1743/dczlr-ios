"""Convert verified local DX9 shader records to SPIR-V and run spirv-val.

Conversion is offline. No original shaders are downloaded or uploaded. A pass
here proves translation and SPIR-V validity, not binding compatibility, GPU
pixel equivalence, effect execution, or a playable game.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import uuid


def spirv_metadata(data):
    if len(data) < 20 or len(data) % 4:
        raise ValueError("Truncated SPIR-V header/word")
    words = struct.unpack("<" + "I" * (len(data) // 4), data)
    magic, version, generator, bound, schema = words[:5]
    if magic != 0x07230203 or schema or not 0 < bound <= 0x3fffff:
        raise ValueError("Invalid SPIR-V header")
    entries, names, decorations, members, variables = [], {}, {}, [], []
    pos = 5
    instructions = 0

    def string(values):
        raw = struct.pack("<" + "I" * len(values), *values)
        end = raw.find(b"\0")
        if end < 0:
            raise ValueError("Unterminated SPIR-V string")
        return raw[:end].decode("utf-8")

    while pos < len(words):
        count, op = words[pos] >> 16, words[pos] & 0xffff
        if not count or count > len(words) - pos:
            raise ValueError("Invalid SPIR-V instruction range")
        operands = words[pos + 1:pos + count]
        if op == 15:
            if len(operands) < 3:
                raise ValueError("Truncated SPIR-V entry point")
            entries.append({"execution_model": operands[0], "name": string(operands[2:])})
        elif op == 5:
            if len(operands) < 2:
                raise ValueError("Truncated SPIR-V name")
            names[operands[0]] = string(operands[1:])
        elif op == 71:
            if len(operands) < 2:
                raise ValueError("Truncated SPIR-V decoration")
            decorations.setdefault(operands[0], []).append(list(operands[1:]))
        elif op == 72:
            if len(operands) < 3:
                raise ValueError("Truncated SPIR-V member decoration")
            members.append(list(operands))
        elif op == 59:
            if len(operands) < 3:
                raise ValueError("Truncated SPIR-V variable")
            variables.append({"id": operands[1], "storage_class": operands[2]})
        instructions += 1
        pos += count
    for variable in variables:
        variable.update(name=names.get(variable["id"]), decorations=decorations.get(variable["id"], []))
    return {"version": version, "generator": generator, "id_bound": bound,
            "instructions": instructions, "entry_points": entries,
            "variables": variables, "member_decorations": members}


def run(command):
    result = subprocess.run([str(p) for p in command], capture_output=True, text=True,
                            errors="replace", timeout=120)
    if result.returncode:
        raise ValueError(f"Tool exited {result.returncode}: {(result.stderr + result.stdout)[-8000:]}")
    return (result.stdout + result.stderr).strip()


def convert(audit, shaders, compiler, validator, output):
    if audit.get("failed") or not audit.get("shaders"):
        raise ValueError("A nonempty passing shader audit is required")
    records = {}
    for row in audit["shaders"]:
        if row["status"] != "size_and_disassembly_pass":
            raise ValueError("Unverified input shader")
        digest = row["sha256"]
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("Invalid input shader hash")
        if digest in records and records[digest]["bytes"] != row["bytes"]:
            raise ValueError("Inconsistent shader records")
        records[digest] = row
    # Check every input before invoking the first conversion.
    for digest, row in records.items():
        data = (shaders / (digest + ".dx9")).read_bytes()
        if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("Shader bytes differ from passing audit: " + digest)
    version = run([compiler, "--version"])
    validator_version = run([validator, "--version"])
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    for digest, record in records.items():
        row = {"source_sha256": digest, "profile": record["profile"], "stage": record["stage"]}
        temporary = output / (digest + "." + uuid.uuid4().hex + ".partial")
        try:
            row["compiler_diagnostic"] = run([compiler, "--strip-debug", "-x", "d3dbc", "-b", "spirv-binary",
                                               "-o", temporary, shaders / (digest + ".dx9")])
            data = temporary.read_bytes()
            metadata = spirv_metadata(data)
            model = 0 if record["stage"] == "vertex" else 4
            if len(metadata["entry_points"]) != 1 or metadata["entry_points"][0]["execution_model"] != model:
                raise ValueError("Converted entry point has unexpected stage")
            row["validator_diagnostic"] = run([validator, "--target-env", "vulkan1.0", temporary])
            target = output / (digest + ".spv")
            temporary.replace(target)
            row.update(status="converted_and_validated", spirv_file=target.name,
                       spirv_bytes=len(data), spirv_sha256=hashlib.sha256(data).hexdigest(), metadata=metadata)
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            row.update(status="failed", reason=str(error))
        finally:
            if temporary.exists():
                temporary.unlink()
        rows.append(row)
    report = {"schema": 1, "artifact_sha256": audit["artifact_sha256"],
              "compiler_version": version, "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(),
              "validator_version": validator_version, "validator_sha256": hashlib.sha256(validator.read_bytes()).hexdigest(),
              "target_environment": "vulkan1.0", "strip_debug": True, "shader_records": len(audit["shaders"]),
              "unique_inputs": len(rows), "passed": sum(r["status"] == "converted_and_validated" for r in rows),
              "failed": sum(r["status"] == "failed" for r in rows), "shaders": rows,
              "gpu_equivalence": "not_tested", "effect_binding_integration": "not_performed",
              "game_playability": "not_verified"}
    (output / "conversion-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--shaders", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--validator", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = convert(json.loads(args.audit.read_text(encoding="utf-8")), args.shaders,
                     args.compiler.resolve(strict=True), args.validator.resolve(strict=True), args.output)
    print(json.dumps({k: report[k] for k in ["unique_inputs", "passed", "failed", "target_environment", "gpu_equivalence"]}))
    raise SystemExit(1 if report["failed"] else 0)
