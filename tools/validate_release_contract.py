"""Validate the public-repository IPA/resource release contract."""
from __future__ import annotations
import argparse, json
from pathlib import Path

LIMIT = 1_000_000_000

def validate(root: Path) -> dict:
    manifest_path = root / "ios" / "Resources" / "DczlrData.manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("format") != "dczlr-resource-parts-v1" or manifest.get("game") != "dczlr":
        raise ValueError("invalid resource manifest identity")
    parts = manifest.get("parts", [])
    if len(parts) != 3 or manifest.get("part_bytes") != LIMIT:
        raise ValueError("release must contain exactly three 1 GB bounded parts")
    expected_total = 0
    for index, part in enumerate(parts, 1):
        expected = f"DczlrData.part{index:03d}.dczdata"
        if part.get("name") != expected or not (0 < part.get("size", 0) <= LIMIT) or len(part.get("sha256", "")) != 64:
            raise ValueError(f"invalid release part: {expected}")
        expected_total += part["size"]
    if expected_total != manifest.get("total_bytes"):
        raise ValueError("part total does not match manifest")
    files = manifest.get("files", [])
    if len(files) != manifest.get("file_count"):
        raise ValueError("file_count does not match manifest")
    part_index = 0
    part_offset = 0
    covered_total = 0
    previous = ""
    for record in files:
        path = record.get("path", "")
        if not path.startswith("Data/") or path <= previous or "\\" in path or "../" in path:
            raise ValueError(f"unsafe or unsorted resource path: {path}")
        previous = path
        covered = 0
        for segment in record.get("segments", []):
            if segment.get("part") != part_index or segment.get("offset") != part_offset:
                raise ValueError(f"non-contiguous segment in {path}")
            length = segment.get("length", 0)
            if length <= 0 or part_index >= len(parts) or part_offset + length > parts[part_index]["size"]:
                raise ValueError(f"segment outside release parts in {path}")
            covered += length
            covered_total += length
            part_offset += length
            if part_offset == parts[part_index]["size"]:
                part_index += 1
                part_offset = 0
        if covered != record.get("size"):
            raise ValueError(f"file segments do not cover {path}")
    if covered_total != manifest["total_bytes"] or part_index != len(parts) or part_offset != 0:
        raise ValueError("file segments do not cover all release parts")
    workflow = (root / ".github" / "workflows" / "release-ios.yml").read_text(encoding="utf-8")
    for required in ("PortLab-unsigned.ipa", "DczlrData.manifest.json", "gh release upload"):
        if required not in workflow:
            raise ValueError(f"release workflow missing {required}")
    return {"parts": len(parts), "total_bytes": expected_total, "max_part_bytes": max(p["size"] for p in parts), "release_workflow": True}

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("root",type=Path); a=p.parse_args(); print(json.dumps(validate(a.root),ensure_ascii=False))
if __name__ == "__main__": main()
