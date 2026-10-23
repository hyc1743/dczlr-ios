"""Exercise actual offline converter/validator executables with self-authored shaders."""
import argparse
import hashlib
import json
from pathlib import Path

from convert_effect_shaders import convert
from parse_dx9_effect import parse, shader_records


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--validator", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference", type=Path)
    args = parser.parse_args()
    fixture = Path(__file__).resolve().parents[1] / "tests/fixtures/effect-synthetic.fxbin"
    data = fixture.read_bytes()
    reference = json.loads(fixture.with_name("effect-synthetic-reflection.json").read_text(encoding="utf-8"))
    if hashlib.sha256(data).hexdigest() != reference["binary_sha256"]:
        raise SystemExit("Self-authored fixture differs from recorded compiler output")
    effect = parse(data)
    records = shader_records(effect, data)
    folder = args.output / "inputs"
    folder.mkdir(parents=True, exist_ok=True)
    for row in records:
        raw = data[row["offset"]:row["offset"] + row["bytes"]]
        if not row.get("shader_framing", {}).get("valid") or row["shader_framing"]["length"] != len(raw):
            raise SystemExit("Self-authored fixture shader framing failed")
        (folder / (row["sha256"] + ".dx9")).write_bytes(raw)
        row["status"] = "self_authored_fixture_framing_pass"
    compat_root = fixture.parent / "shader-compat"
    compat = json.loads((compat_root / "fixture-report.json").read_text(encoding="utf-8"))
    if not compat["self_authored"] or compat["original_game_inputs"] or len(compat["shaders"]) != 5:
        raise SystemExit("Unexpected legacy fixture provenance")
    for recorded in compat["shaders"]:
        source = (compat_root / recorded["source_file"]).read_bytes()
        raw = (compat_root / recorded["binary_file"]).read_bytes()
        if hashlib.sha256(source).hexdigest() != recorded["source_sha256"] or hashlib.sha256(raw).hexdigest() != recorded["sha256"]:
            raise SystemExit("Legacy regression fixture differs from recorded source/binary")
        row = dict(recorded)
        (folder / (row["sha256"] + ".dx9")).write_bytes(raw)
        records.append(row)
    audit = {"artifact_sha256": hashlib.sha256(data).hexdigest(), "failed": 0, "shaders": records}
    report = convert(audit, folder, args.compiler.resolve(strict=True), args.validator.resolve(strict=True), args.output)
    if report["failed"] or report["passed"] != 8:
        print(json.dumps([{"source_sha256": row["source_sha256"], "profile": row["profile"],
                           "reason": row.get("reason")} for row in report["shaders"] if row["status"] == "failed"]), flush=True)
        raise SystemExit("Self-authored shader conversion/validation failed")
    # Host/compiler binaries differ; compare only SPIR-V for identical inputs.
    if args.reference:
        reference = json.loads(args.reference.read_text(encoding="utf-8"))
        expected = {r["source_sha256"]: r["spirv_sha256"] for r in reference["shaders"]}
        actual = {r["source_sha256"]: r["spirv_sha256"] for r in report["shaders"]}
        if actual != expected:
            raise SystemExit("Native Linux and Windows converter output differs")
    print(json.dumps({"self_authored_shaders": report["passed"], "original_game_inputs": False,
                      "gpu_used": False, "cross_host_match": bool(args.reference)}))
