"""Audit the native XL light reader against every local RPP_07 entry."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path

from native_core import PPArchive, XLInfo, XLLight, library


def decode_name(data, span):
    raw = data[span.offset:span.offset + span.length]
    decoded = bytes(value ^ 255 for value in raw)
    return decoded.split(b"\0", 1)[0].decode("ascii")


def audit(directory):
    lib = library()
    rows = []
    for path in sorted(directory.glob("*.pp")):
        try:
            archive = PPArchive(path)
        except ValueError:
            continue
        with archive:
            for index in range(archive.count):
                entry = archive.entry(index)
                if not entry.name_bytes.lower().endswith(b".xl"):
                    continue
                data = archive.read(index)
                info = XLInfo()
                status = lib.dc_xl_probe(data, len(data), C.byref(info))
                if status:
                    rows.append({
                        "archive": path.name,
                        "entry": entry.name_bytes.decode("ascii", errors="replace"),
                        "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "status": "outside_native_xl_profile",
                        "native_status": status,
                    })
                    continue
                lights = []
                for light_index in range(info.lights):
                    view = XLLight()
                    status = lib.dc_xl_light_at(data, len(data), light_index, C.byref(view))
                    if status:
                        raise ValueError(f"native XL view rejected {path.name}:{entry.name_bytes!r}:{light_index}: {status}")
                    lights.append({
                        "index": light_index,
                        "name": decode_name(data, view.name),
                        "target": decode_name(data, view.target),
                        "kind": view.kind,
                        "enabled": view.enabled,
                        "diffuse": [round(value, 7) for value in view.diffuse],
                        "ambient": [round(value, 7) for value in view.ambient],
                        "specular": [round(value, 7) for value in view.specular],
                        "position": [round(value, 7) for value in view.position],
                        "direction": [round(value, 7) for value in view.direction],
                        "parameters": [round(value, 7) for value in view.parameters],
                    })
                rows.append({
                    "archive": path.name,
                    "entry": entry.name_bytes.decode("ascii"),
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "lights": lights,
                    "status": "native_xl_profile_verified",
                })
    verified = sum(row["status"] == "native_xl_profile_verified" for row in rows)
    return {
        "schema": 1,
        "method": "native dc_xl framing and light views; encoded names decoded only for labels",
        "entries": rows,
        "entries_examined": len(rows),
        "verified_entries": verified,
        "outside_native_profile": len(rows) - verified,
        "expected_rpp07_entries": 31,
        "expected_local_entries": 73,
        "game_playability": "not_verified",
        "original_gpu_lighting": "not_executed",
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
