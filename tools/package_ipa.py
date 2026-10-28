"""Create an iOS IPA with a conservative ZIP layout for older importers."""
from __future__ import annotations

import argparse
from pathlib import Path
import stat
import zipfile

ZIP_METHOD = zipfile.ZIP_DEFLATED


def _entry(info: Path, name: str) -> zipfile.ZipInfo:
    is_dir = info.is_dir()
    zi = zipfile.ZipInfo(name if is_dir else name)
    zi.date_time = (1980, 1, 1, 0, 0, 0)
    zi.compress_type = ZIP_METHOD
    mode = stat.S_IFDIR | 0o755 if is_dir else stat.S_IFREG | (0o755 if info.name == "PortLab" else 0o644)
    zi.external_attr = mode << 16
    return zi


def package(app: Path, output: Path) -> None:
    app = app.resolve()
    if not app.is_dir() or app.name != "PortLab.app":
        raise ValueError("expected a PortLab.app directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=ZIP_METHOD, compresslevel=9, allowZip64=False) as archive:
        payload = zipfile.ZipInfo("Payload/")
        payload.date_time = (1980, 1, 1, 0, 0, 0)
        payload.external_attr = (stat.S_IFDIR | 0o755) << 16
        archive.writestr(payload, b"")
        root = zipfile.ZipInfo("Payload/PortLab.app/")
        root.date_time = (1980, 1, 1, 0, 0, 0)
        root.external_attr = (stat.S_IFDIR | 0o755) << 16
        archive.writestr(root, b"")
        for path in sorted(app.rglob("*")):
            relative = path.relative_to(app).as_posix()
            name = f"Payload/PortLab.app/{relative}"
            if path.is_dir():
                archive.writestr(_entry(path, name + "/"), b"")
            elif path.is_file():
                archive.writestr(_entry(path, name), path.read_bytes())
            else:
                raise ValueError(f"unsupported app member: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app, args.output)


if __name__ == "__main__":
    main()
