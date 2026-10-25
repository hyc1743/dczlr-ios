"""Stage verified Dczlr resource parts for a private Git/LFS repository."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from pack_resources import verify  # noqa: E402


def prepare(parts: Path, output: Path, hardlink: bool = False) -> None:
    verify(parts, None, None)
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"output is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    for name in ("DczlrData.manifest.json", "DczlrData.part001.dczdata",
                 "DczlrData.part002.dczdata", "DczlrData.part003.dczdata"):
        source = parts / name
        target = output / name
        if hardlink:
            target.hardlink_to(source)
        else:
            shutil.copy2(source, target)
    (output / ".gitattributes").write_text(
        "DczlrData.part*.dczdata filter=lfs diff=lfs merge=lfs -text\n",
        encoding="utf-8")
    (output / "README.md").write_text(
        "# Private Dczlr resources\n\n"
        "This repository contains local game resource parts for the private "
        "simulator workflow. Keep the repository private and use Git LFS for "
        "the `.dczdata` files. The public dczlr source repository contains "
        "only the manifest contract and never these resources.\n",
        encoding="utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hardlink", action="store_true")
    args = parser.parse_args(argv)
    prepare(args.parts, args.output, args.hardlink)
    print(f"staged private resource repository: {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
