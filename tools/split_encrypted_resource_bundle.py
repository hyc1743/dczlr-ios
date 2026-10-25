"""Split an encrypted resource bundle into ordered uploadable chunks."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


def split_bundle(source: Path, output: Path, part_bytes: int = 950_000_000) -> list[dict]:
    if part_bytes <= 0:
        raise ValueError("part_bytes must be positive")
    source = Path(source)
    if not source.is_file():
        raise ValueError(f"missing encrypted bundle: {source}")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    records = []
    with source.open("rb") as input_file:
        index = 1
        while True:
            target = output / f"{source.stem}.part{index:03d}{source.suffix}"
            written = 0
            digest = hashlib.sha256()
            with target.open("wb") as part:
                while written < part_bytes:
                    chunk = input_file.read(min(8 * 1024 * 1024, part_bytes - written))
                    if not chunk:
                        break
                    part.write(chunk)
                    digest.update(chunk)
                    written += len(chunk)
            if not written:
                target.unlink(missing_ok=True)
                break
            records.append({"name": target.name, "size": written, "sha256": digest.hexdigest()})
            index += 1
    return records


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--part-bytes", type=int, default=950_000_000)
    args = parser.parse_args(argv)
    import json
    print(json.dumps({"parts": split_bundle(args.input, args.output, args.part_bytes)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
