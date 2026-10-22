"""Validate the metadata contract for converted D3DX effects."""
from __future__ import annotations
import argparse
import json
from pathlib import Path

REQUIRED = {"schema", "format", "source_artifact", "effects"}

def validate(path: Path) -> dict:
    doc = json.loads(path.read_text(encoding="utf-8"))
    missing = REQUIRED - set(doc)
    if missing:
        raise ValueError(f"missing top-level keys: {sorted(missing)}")
    if doc["schema"] != 1 or doc["format"] != "dczlr-ios-converted-effects-v1":
        raise ValueError("unsupported converted-effect manifest format")
    artifact = doc["source_artifact"]
    if not isinstance(artifact.get("sha256"), str) or len(artifact["sha256"]) != 64:
        raise ValueError("source_artifact.sha256 must be a SHA-256 digest")
    effects = doc["effects"]
    if not isinstance(effects, list) or not effects:
        raise ValueError("effects must be a non-empty list")
    ids = set()
    for effect in effects:
        for key in ("id", "source_sha256", "metal_library", "technique_count", "pass_count", "constant_bindings", "texture_bindings"):
            if key not in effect:
                raise ValueError(f"{effect.get('id', '<unknown>')}: missing {key}")
        if effect["id"] in ids:
            raise ValueError(f"duplicate effect id: {effect['id']}")
        ids.add(effect["id"])
        if len(effect["source_sha256"]) != 64 or not isinstance(effect["metal_library"], str):
            raise ValueError(f"{effect['id']}: invalid source digest or Metal library")
        if not isinstance(effect["technique_count"], int) or effect["technique_count"] < 1:
            raise ValueError(f"{effect['id']}: invalid technique_count")
        if not isinstance(effect["pass_count"], int) or effect["pass_count"] < 1:
            raise ValueError(f"{effect['id']}: invalid pass_count")
        if not isinstance(effect["constant_bindings"], list) or not isinstance(effect["texture_bindings"], list):
            raise ValueError(f"{effect['id']}: bindings must be lists")
    return {"effects": len(effects), "ids": sorted(ids), "source_sha256": artifact["sha256"]}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    result = validate(args.manifest)
    print(f"PASS: {result['effects']} converted effects ({', '.join(result['ids'])})")

if __name__ == "__main__": main()
