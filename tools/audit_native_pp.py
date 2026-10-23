"""Compare the native archive index with local file framing and sample reads.

This is a cross-language check of observations, not an original-code oracle.
Game payload bytes are not exported; only metadata and sample digests are saved.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
from native_core import PPArchive


def audit(directory):
    archives = []
    total_entries = 0
    formats = Counter()
    format_bytes = Counter()
    for path in sorted(directory.glob("*.pp")):
        row = {"file": path.name, "bytes": path.stat().st_size}
        try:
            archive = PPArchive(path)
        except ValueError as error:
            row.update(status="unrecognized_or_invalid", reason=str(error))
            archives.append(row)
            continue
        with archive, path.open("rb") as source:
            count, payload_size = struct.unpack("<II", source.read(8))
            raw_names = source.read(count * 32)
            sizes = struct.unpack("<" + "I" * count, source.read(count * 4))
            assert count == archive.count
            assert sum(sizes) == payload_size
            position = 8 + 36 * count
            digest = hashlib.sha256()
            sample_ranges = 0
            archive_formats = Counter()
            for index in range(count):
                entry = archive.entry(index)
                name = bytes((-v) & 255 for v in raw_names[index * 32:index * 32 + 32]).split(b"\0", 1)[0]
                assert entry.name_bytes == name
                assert entry.offset == position and entry.size == sizes[index]
                suffix = name.rsplit(b".", 1)[-1].lower() if b"." in name else b""
                extension = suffix.decode("ascii", errors="backslashreplace") or "(no extension)"
                archive_formats[extension] += 1
                formats[extension] += 1
                format_bytes[extension] += entry.size
                for offset in sorted({0, max(0, entry.size - 64)}):
                    length = min(64, entry.size - offset)
                    source.seek(position + offset)
                    expected = bytes((-v) & 255 for v in source.read(length))
                    actual = archive.read(index, offset, length)
                    assert actual == expected
                    digest.update(struct.pack("<IIQ", index, length, offset))
                    digest.update(actual)
                    sample_ranges += 1
                position += entry.size
            assert position == path.stat().st_size
            row.update(status="native_index_and_samples_match", entries=count,
                       sample_ranges=sample_ranges, sample_sha256=digest.hexdigest(),
                       entry_formats=dict(sorted(archive_formats.items())))
            total_entries += count
        archives.append(row)
    return {"method": "Native C index and sample reads compared with an independent Python observation parser",
            "archives": archives, "recognized_archives": sum(r["status"] == "native_index_and_samples_match" for r in archives),
            "total_archives": len(archives), "recognized_entries": total_entries,
            "entry_formats": dict(sorted(formats.items())),
            "format_payload_bytes": dict(sorted(format_bytes.items())),
            "format_coverage_note": "Extensions describe inventory, not decoder or runtime compatibility; embedded assets are not enumerated",
            "original_code_oracle": "not_performed_by_this_command", "game_playability": "not_verified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = audit(args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "archives"}))
