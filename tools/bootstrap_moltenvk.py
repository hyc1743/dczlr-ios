"""Fetch the pinned official MoltenVK public-API release, never game inputs."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
import tarfile
import urllib.request

VERSION = "1.4.2"
SIZE = 180474368
SHA256 = "562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276"
URL = f"https://github.com/KhronosGroup/MoltenVK/releases/download/v{VERSION}/MoltenVK-all.tar"


def bootstrap(root, notices=None):
    root.mkdir(parents=True, exist_ok=True)
    archive = root / "MoltenVK-all.tar"
    if not archive.exists() or archive.stat().st_size != SIZE or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        partial = root / "MoltenVK-all.tar.partial"
        digest = hashlib.sha256()
        count = 0
        with urllib.request.urlopen(URL, timeout=60) as response, partial.open("wb") as target:
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > SIZE:
                    raise ValueError("MoltenVK download exceeds pinned size")
                digest.update(chunk)
                target.write(chunk)
        if count != SIZE or digest.hexdigest() != SHA256:
            raise ValueError("MoltenVK archive identity mismatch")
        partial.replace(archive)
    # Python's data filter rejects absolute/escaping paths and unsafe links.
    with tarfile.open(archive) as source:
        source.extractall(root, filter="data")
    report = {"version": VERSION, "url": URL, "sha256": SHA256, "bytes": SIZE,
              "api": "public", "game_inputs": False}
    (root / "dependency.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if notices:
        notices.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / "MoltenVK/LICENSE", notices / "MoltenVK-LICENSE.txt")
        shutil.copyfile(root / "MoltenVK/Docs/MoltenVK_Runtime_UserGuide.md", notices / "MoltenVK_Runtime_UserGuide.md")
        shutil.copyfile(root / "dependency.json", notices / "dependency.json")
    print(json.dumps(report))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".tools/moltenvk-1.4.2"))
    parser.add_argument("--notices-output", type=Path)
    args = parser.parse_args()
    bootstrap(args.output, args.notices_output)
