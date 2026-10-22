"""Build a metadata-only iOS resource manifest from REA PE evidence.

The tool deliberately does not extract or decode payload bytes. It binds a
resource identifier to the verified source range and the future Bundle name.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def build(source: Path) -> dict:
    evidence = json.loads(source.read_text(encoding="utf-8"))
    if evidence.get("operation") != "inspect_pe_resources":
        raise ValueError("source is not PE resource evidence")
    artifact = evidence.get("artifact", {})
    if artifact.get("format") != "pe32" or artifact.get("architecture") != "x86":
        raise ValueError("expected the verified x86 PE artifact")
    resources = evidence.get("named_resources")
    if not isinstance(resources, list) or not resources:
        raise ValueError("evidence has no named resources")

    entries = []
    names = set()
    for item in resources:
        name = item.get("name")
        digest = item.get("sha256")
        size = item.get("bytes")
        if not isinstance(name, str) or not name.startswith("IDR_"):
            raise ValueError(f"invalid resource name: {name!r}")
        if name in names:
            raise ValueError(f"duplicate resource name: {name}")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ValueError(f"invalid resource digest for {name}")
        if not isinstance(size, int) or size <= 0:
            raise ValueError(f"invalid resource size for {name}")
        names.add(name)
        entries.append({
            "id": name,
            "bundle_file": f"{name}.bin",
            "source": {
                "file_offset": item["file_offset"],
                "bytes": size,
                "sha256": digest,
                "language_id": item["language_id"],
            },
            "decoded_format": None,
            "status": "source-range-verified",
        })
    entries.sort(key=lambda item: item["id"])
    return {
        "schema": 1,
        "format": "dczlr-ios-resource-manifest-v1",
        "source_artifact": {
            "path": artifact["path"],
            "sha256": artifact["sha256"],
            "architecture": artifact["architecture"],
        },
        "resources": entries,
        "limitations": [
            "Bundle files are not present yet; this is metadata only.",
            "decoded_format is intentionally unknown until a format-aware test is run.",
            "Source hashes bind the PE ranges, not a future converted payload.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = build(args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(result['resources'])} resource entries to {args.output}")


if __name__ == "__main__":
    main()
