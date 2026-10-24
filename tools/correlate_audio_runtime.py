"""Correlate bounded Windows runtime read sizes with local PP audio entries."""
import argparse
import json
from pathlib import Path

from native_core import PPArchive


def inventory(data_directory):
    result = {}
    for archive_name in ("RPP_01.pp", "RPP_14.pp"):
        path = data_directory / archive_name
        with PPArchive(path) as archive:
            result[archive_name] = [
                {"name": archive.entry(index).name_bytes.decode("ascii"), "bytes": archive.entry(index).size,
                 "offset": archive.entry(index).offset}
                for index in range(archive.count)
                if archive.entry(index).name_bytes.lower().endswith(b".wav")
            ]
    return result


def correlate(probe, data_directory):
    doc = json.loads(probe.read_text(encoding="utf-8"))
    entries = inventory(data_directory)
    observations = []
    for event in doc.get("events", []):
        if event.get("kind") != "read":
            continue
        path = str(event.get("path", ""))
        archive_name = next((name for name in entries if path.lower().endswith(name.lower())), None)
        if not archive_name:
            continue
        matches = [item for item in entries[archive_name] if item["bytes"] == event.get("bytes")]
        if matches:
            observations.append({"archive": archive_name, "read_bytes": event["bytes"],
                                 "time": event.get("time"), "matches": matches})
    return {
        "schema": 1,
        "method": "runtime ReadFile byte count matched against local PP entry sizes",
        "probe": str(probe),
        "observations": observations,
        "verified_title_audio": sorted({(o["archive"], m["name"])
                                         for o in observations for m in o["matches"]}),
        "gameplay_audio_observed": any(
            o["archive"] == "RPP_14.pp" and any(m["name"] in {"se016.wav", "se322.wav", "se332.wav"}
                                                for m in o["matches"])
            for o in observations
        ),
        "process_interaction": doc.get("process_interaction", "unknown"),
        "device_audio": "not_tested",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = correlate(args.probe, args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "observations"}, ensure_ascii=False))
