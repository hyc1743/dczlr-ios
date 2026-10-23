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
    effect = parse(data)
    records = shader_records(effect, data)
    folder = args.output / "inputs"
    folder.mkdir(parents=True, exist_ok=True)
    for row in records:
        raw = data[row["offset"]:row["offset"] + row["bytes"]]
        (folder / (row["sha256"] + ".dx9")).write_bytes(raw)
        row["status"] = "size_and_disassembly_pass"
    audit = {"artifact_sha256": hashlib.sha256(data).hexdigest(), "failed": 0, "shaders": records}
    report = convert(audit, folder, args.compiler.resolve(strict=True), args.validator.resolve(strict=True), args.output)
    if report["failed"] or report["passed"] != 3:
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
