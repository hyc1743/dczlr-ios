"""Build self-authored Vulkan sprite shaders offline and validate each module."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(command):
    result = subprocess.run([str(s) for s in command], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError((result.stdout + result.stderr)[-6000:])
    return (result.stdout + result.stderr).strip()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--glslang", default="glslangValidator")
    parser.add_argument("--validator", default="spirv-val")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    header = ["/* Generated from self-authored sprite GLSL; no original game bytecode. */",
              "#include <stdint.h>", "#include <stddef.h>"]
    reports = []
    for stage in ("vert", "frag"):
        source = ROOT / "native/render/vulkan/shaders" / ("sprite." + stage)
        target = args.output / ("sprite." + stage + ".spv")
        run([args.glslang, "-V", "--target-env", "vulkan1.0", "-o", target, source])
        run([args.validator, "--target-env", "vulkan1.0", target])
        data = target.read_bytes()
        if len(data) % 4 or data[:4] != b"\x03\x02\x23\x07":
            raise ValueError("Compiler did not produce SPIR-V")
        values = struct.unpack("<" + "I" * (len(data) // 4), data)
        header.append(f"static const uint32_t dc_sprite_{stage}_spv[] = {{")
        for offset in range(0, len(values), 8):
            header.append("    " + ", ".join(f"0x{value:08x}u" for value in values[offset:offset + 8]) + ",")
        header.append("};")
        reports.append({"stage": stage, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                        "spirv_sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
    (args.output / "dc_sprite_spv.h").write_text("\n".join(header) + "\n", encoding="utf-8")
    report = {"schema": 1, "compiler": run([args.glslang, "--version"]),
              "validator": run([args.validator, "--version"]), "target": "vulkan1.0", "shaders": reports}
    (args.output / "sprite-shaders.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"self_authored_shaders": len(reports), "validated": True}))
