"""Record the verified RPP14 audio inventory and static slot bindings."""
import argparse
import hashlib
import json
from pathlib import Path

from native_core import PPArchive


VERIFIED_SLOT_BINDINGS = {
    0: "se100.wav",
    10: "se016.wav",
    17: "se322.wav",
    20: "se332.wav",
}

CHAPTER3_SLOT_NAMES = (
    "se000.wav", "se015.wav", "se016.wav", "se017.wav", "se018.wav",
    "se019.wav", "se020.wav", "se021.wav", "se022.wav", "se023.wav",
    "se024.wav", "se025.wav", "se026.wav", "se027.wav", "se028.wav",
    "se029.wav", "se030.wav", "se031.wav", "se100.wav", "se101.wav",
    "se200.wav", "se300.wav", "se301.wav", "se302.wav", "se310.wav",
    "se311.wav", "se312.wav", "se320.wav", "se321.wav", "se322.wav",
    "se330.wav", "se331.wav", "se332.wav",
)


def audit(data_directory: Path) -> dict:
    archive_path = data_directory / "RPP_14.pp"
    with PPArchive(archive_path) as archive:
        entries = []
        for index in range(archive.count):
            entry = archive.entry(index)
            if not entry.name_bytes.lower().endswith(b".wav"):
                continue
            payload = archive.read(index)
            entries.append({
                "archive_index": index,
                "name": entry.name_bytes.decode("ascii"),
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            })
    names = {entry["name"] for entry in entries}
    missing = [name for name in VERIFIED_SLOT_BINDINGS.values() if name not in names]
    if missing:
        raise ValueError("verified slot names are missing from RPP_14.pp: " + ", ".join(missing))
    missing_chapter3 = [name for name in CHAPTER3_SLOT_NAMES if name not in names]
    if missing_chapter3:
        raise ValueError("chapter-3 slot names are missing from RPP_14.pp: " + ", ".join(missing_chapter3))
    return {
        "schema": 1,
        "method": "local PP inventory plus static call-site slot bindings",
        "archive": "RPP_14.pp",
        "entries": entries,
        "runtime_slot_count_observed": 35,
        "chapter3_slot_names": list(CHAPTER3_SLOT_NAMES),
        "chapter3_slot_names_verified": True,
        "verified_slot_bindings": [
            {"slot": slot, "name": name, "source": source}
            for slot, name, source in (
                (0, "se100.wav", "00513690 input keys 0x3b/0x3c"),
                (10, "se016.wav", "005201e0 static slot table"),
                (17, "se322.wav", "005201e0 static slot table"),
                (20, "se332.wav", "005201e0 static slot table"),
            )
        ],
        "unresolved_context_slots": [
            {"context_offset": "0x106c", "context_offset_alt": "0x1070", "dispatcher": "00532240",
             "reason": "caller-owned context object and interaction-to-slot index are not recovered"}
        ],
        "gameplay_trigger_wiring": "not_claimed",
        "audio_device_execution": "not_tested",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "entries"}))
