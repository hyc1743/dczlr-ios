"""Find bounded DX9 shader bytecode candidates in verified effect payloads."""
from __future__ import annotations
import argparse, hashlib, json, struct
from pathlib import Path

PROFILES = {0xFFFE0200: "vs_2_0", 0xFFFF0200: "ps_2_0", 0xFFFE0300: "vs_3_0", 0xFFFF0300: "ps_3_0"}
END = 0x0000FFFF

def extract(exe: Path, evidence: Path, max_bytes: int = 256 * 1024) -> dict:
    source = json.loads(evidence.read_text(encoding="utf-8")); blob = exe.read_bytes(); effects = []
    for item in source["named_resources"]:
        data = blob[item["file_offset"]:item["file_offset"] + item["bytes"]]
        candidates = []; seen = set()
        for start in range(0, len(data) - 4, 4):
            profile = PROFILES.get(struct.unpack_from("<I", data, start)[0])
            if not profile: continue
            end = None
            limit = min(len(data), start + max_bytes)
            for cursor in range(start + 4, limit, 4):
                if struct.unpack_from("<I", data, cursor)[0] == END:
                    end = cursor + 4; break
            if end is None or end <= start + 8: continue
            value = data[start:end]; digest = hashlib.sha256(value).hexdigest()
            key = (start, end, digest)
            if key in seen: continue
            seen.add(key)
            candidates.append({"offset": start, "length": end - start, "profile": profile, "sha256": digest})
        effects.append({"id": item["name"], "source_sha256": item["sha256"], "candidates": candidates})
    return {"schema": 1, "artifact_sha256": source["artifact"]["sha256"],
            "method": "Aligned DX9 profile/end-token scan; candidates are not disassembled or executed.",
            "effects": effects,
            "limitations": ["Effect metadata can contain duplicated shader blobs.", "Token scanning does not prove technique/pass ownership.", "Candidates require a DX9 bytecode parser before conversion."]}

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__); p.add_argument("exe", type=Path); p.add_argument("evidence", type=Path); p.add_argument("--output", required=True, type=Path); a = p.parse_args()
    result = extract(a.exe, a.evidence); a.output.parent.mkdir(parents=True, exist_ok=True); a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"); print(f"Found shader candidates in {len(result['effects'])} effects")

if __name__ == "__main__": main()
