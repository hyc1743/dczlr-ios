"""Probe PE RCDATA resources for D3DX effect bytecode metadata."""
from __future__ import annotations
import argparse
import json
import re
import struct
from pathlib import Path

MAGIC = 0xFEFF0901

def probe(exe: Path, evidence: Path) -> dict:
    source = json.loads(evidence.read_text(encoding="utf-8"))
    blob = exe.read_bytes()
    resources = []
    for item in source["named_resources"]:
        payload = blob[item["file_offset"]:item["file_offset"] + item["bytes"]]
        if len(payload) != item["bytes"]:
            raise ValueError(f"truncated resource: {item['name']}")
        first = struct.unpack_from("<I", payload, 0)[0]
        header_words = list(struct.unpack_from("<12I", payload, 0))
        names, seen = [], set()
        for match in re.finditer(rb"[A-Za-z_][A-Za-z0-9_]{2,63}", payload[:min(len(payload), 65536)]):
            name = match.group().decode("ascii")
            if name not in seen:
                seen.add(name)
                names.append(name)
            if len(names) >= 128:
                break
        resources.append({
            "id": item["name"], "bytes": len(payload),
            "first_u32_le": f"0x{first:08x}",
            "header_words_le": [f"0x{word:08x}" for word in header_words],
            "d3dx_effect_magic_match": first == MAGIC,
            "bounded_parameter_names": [n for n in names if n.startswith(("g_", "World", "View", "Proj", "Texture", "Light", "Color", "Blend", "Z"))][:64],
        })
    return {"schema": 1, "artifact": {"path": str(exe), "sha256": source["artifact"]["sha256"]},
            "method": "Bounded static header and printable-name probe; no shader execution or decoding.",
            "resources": resources,
            "interpretation": {"confidence": "strong_static_consistency",
                "observation": "All seven named resources begin with 0xFEFF0901 and expose effect-like parameter names.",
                "unknowns": ["Exact D3DX effect version/profile and pass graph are not decoded.", "Runtime loading and technique selection are not observed."]}}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", type=Path); parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(); result = probe(args.exe, args.evidence)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Probed {len(result['resources'])} resources; wrote {args.output}")

if __name__ == "__main__": main()
