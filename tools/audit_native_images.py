"""Offline pixel comparison against Pillow; never exports original images.

Requires Pillow on the analysis host only. Does not execute the original EXE
or establish original D3DX texture sampling, resizing, color-key or GPU behavior.
"""
import argparse
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import struct

from PIL import Image, __version__ as pillow_version
from native_core import PPArchive, ROOT, decode_image


def audit(directory):
    rows = []
    excluded = []
    formats = Counter()
    for path in sorted(directory.glob("*.pp")):
        try:
            archive = PPArchive(path)
        except ValueError as error:
            excluded.append({"archive": path.name, "reason": str(error)})
            continue
        with archive:
            for index in range(archive.count):
                entry = archive.entry(index)
                extension = entry.name_bytes.rsplit(b".", 1)[-1].lower()
                if extension not in (b"bmp", b"tga", b"ema"):
                    continue
                row = {"archive": path.name, "index": index,
                       "format": extension.decode(), "source_bytes": entry.size}
                try:
                    data = archive.read(index)
                    row["source_sha256"] = hashlib.sha256(data).hexdigest()
                    reference_data = data[13:] if extension == b"ema" else data
                    # Original 0x0041f130 restores BM before calling D3DX.
                    if extension == b"ema" and data[8:13] == b".bmp\0" and reference_data[:2] == b"\0\0":
                        reference_data = b"BM" + reference_data[2:]
                        row["reference_header_restored"] = True
                    with Image.open(io.BytesIO(reference_data)) as reference:
                        expected_size = reference.size
                        expected = reference.convert("RGBA").tobytes()
                    info, actual = decode_image(data, {b"bmp": 1, b"tga": 2, b"ema": 3}[extension])
                    if (info.width, info.height) != expected_size or actual != expected:
                        raise ValueError("Native pixels or dimensions differ from Pillow")
                    if extension == b"ema" and struct.unpack_from("<II", data) != expected_size:
                        raise ValueError("EMA envelope dimensions differ from embedded image")
                    formats[extension.decode()] += 1
                    row.update(status="all_pixels_match", width=info.width, height=info.height,
                               rgba_sha256=hashlib.sha256(actual).hexdigest())
                except (ValueError, OSError) as error:
                    row.update(status="failed", reason=str(error))
                rows.append(row)
    return {"method": "Native C full RGBA pixel comparison with independent Pillow decoder",
            "pillow_version": pillow_version, "images": rows, "matched_formats": dict(formats),
            "matched": sum(r["status"] == "all_pixels_match" for r in rows),
            "failed": sum(r["status"] != "all_pixels_match" for r in rows),
            "excluded_archives": excluded,
            "native_source_sha256": hashlib.sha256((ROOT / "native/resource/dc_image.c").read_bytes()).hexdigest(),
            "original_d3dx_oracle": "not_performed", "gpu_upload": "not_tested",
            "game_playability": "not_verified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "images"}))
    raise SystemExit(1 if result["failed"] or not result["matched"] else 0)
