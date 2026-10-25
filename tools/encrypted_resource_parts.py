"""Encrypt and restore local Dczlr resource parts for a macOS CI run.

The encrypted bundle is intended to live outside Git history (for example as a
private release asset).  Only the AES-GCM key is stored as a GitHub Actions
secret.  Plaintext game resources are never written to the repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"DCZLRRESENCV1\0\0"
CHUNK_BYTES = 8 * 1024 * 1024
NONCE_BYTES = 12


def _key(args) -> bytes:
    value = args.key_hex or os.environ.get(args.key_env, "")
    if len(value) != 64:
        raise ValueError("resource key must be 64 hexadecimal characters")
    try:
        key = bytes.fromhex(value)
    except ValueError as error:
        raise ValueError("resource key is not hexadecimal") from error
    if len(key) != 32:
        raise ValueError("resource key must decode to 32 bytes")
    return key


def _manifest(parts: Path) -> tuple[bytes, list[Path]]:
    manifest_path = parts / "DczlrData.manifest.json"
    if not manifest_path.is_file():
        raise ValueError("missing DczlrData.manifest.json")
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    expected = [item["name"] for item in manifest.get("parts", [])]
    if not expected:
        raise ValueError("manifest contains no resource parts")
    paths = [parts / name for name in expected]
    for item, path in zip(manifest["parts"], paths):
        if not path.is_file() or path.stat().st_size != item["size"]:
            raise ValueError(f"resource part size mismatch: {item['name']}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.stat().st_size < 64 * 1024 * 1024 else _sha256(path)
        if digest != item["sha256"]:
            raise ValueError(f"resource part hash mismatch: {item['name']}")
    return manifest_bytes, [manifest_path, *paths]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(CHUNK_BYTES):
            digest.update(chunk)
    return digest.hexdigest()


def _associated(name: str, index: int) -> bytes:
    return name.encode("utf-8") + b"\0" + struct.pack("<Q", index)


def pack_bundle(parts: Path, output: Path, key: bytes) -> dict:
    manifest_bytes, files = _manifest(parts)
    records = []
    for path in files:
        records.append({"name": path.name, "size": path.stat().st_size, "sha256": _sha256(path)})
    header = {"format": "dczlr-encrypted-resource-v1", "chunk_bytes": CHUNK_BYTES, "files": records}
    header_bytes = json.dumps(header, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".partial")
    aes = AESGCM(key)
    try:
        with temporary.open("wb") as target:
            target.write(MAGIC)
            target.write(struct.pack("<I", len(header_bytes)))
            target.write(header_bytes)
            for record, path in zip(records, files):
                with path.open("rb") as source:
                    index = 0
                    while plain := source.read(CHUNK_BYTES):
                        nonce = os.urandom(NONCE_BYTES)
                        encrypted = aes.encrypt(nonce, plain, _associated(record["name"], index))
                        target.write(nonce)
                        target.write(struct.pack("<I", len(encrypted)))
                        target.write(encrypted)
                        index += 1
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return {"format": header["format"], "files": len(files), "bytes": output.stat().st_size,
            "sha256": _sha256(output)}


def unpack_bundle(bundle: Path, output: Path, key: bytes) -> dict:
    bundle = Path(bundle)
    with bundle.open("rb") as source:
        if source.read(len(MAGIC)) != MAGIC:
            raise ValueError("encrypted resource magic mismatch")
        raw_length = source.read(4)
        if len(raw_length) != 4:
            raise ValueError("encrypted resource header is truncated")
        header_length = struct.unpack("<I", raw_length)[0]
        if header_length <= 0 or header_length > 16 * 1024 * 1024:
            raise ValueError("encrypted resource header is invalid")
        header = json.loads(source.read(header_length))
        if header.get("format") != "dczlr-encrypted-resource-v1":
            raise ValueError("encrypted resource format mismatch")
        files = header.get("files", [])
        if not files:
            raise ValueError("encrypted resource contains no files")
        output = Path(output)
        output.mkdir(parents=True, exist_ok=True)
        aes = AESGCM(key)
        for record in files:
            name = record.get("name", "")
            if not name or Path(name).name != name or name in {".", ".."}:
                raise ValueError("unsafe encrypted resource filename")
            target = output / name
            temporary = target.with_suffix(target.suffix + ".partial")
            digest = hashlib.sha256()
            written = 0
            index = 0
            try:
                with temporary.open("wb") as destination:
                    while written < record["size"]:
                        nonce = source.read(NONCE_BYTES)
                        raw_length = source.read(4)
                        if len(nonce) != NONCE_BYTES or len(raw_length) != 4:
                            raise ValueError("encrypted resource chunk is truncated")
                        encrypted_length = struct.unpack("<I", raw_length)[0]
                        encrypted = source.read(encrypted_length)
                        if len(encrypted) != encrypted_length:
                            raise ValueError("encrypted resource payload is truncated")
                        try:
                            plain = aes.decrypt(nonce, encrypted, _associated(name, index))
                        except Exception as error:
                            raise ValueError(f"encrypted resource authentication failed: {name}") from error
                        if not plain or written + len(plain) > record["size"]:
                            raise ValueError("encrypted resource chunk size is invalid")
                        destination.write(plain)
                        digest.update(plain)
                        written += len(plain)
                        index += 1
                if digest.hexdigest() != record["sha256"]:
                    raise ValueError(f"restored resource hash mismatch: {name}")
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
        if source.read(1):
            raise ValueError("encrypted resource has trailing bytes")
    return {"format": header["format"], "files": len(files), "output": str(output)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-env", default="DCZLR_RESOURCE_KEY")
    parser.add_argument("--key-hex")
    sub = parser.add_subparsers(dest="command", required=True)
    pack = sub.add_parser("pack")
    pack.add_argument("--parts", type=Path, required=True)
    pack.add_argument("--output", type=Path, required=True)
    unpack = sub.add_parser("unpack")
    unpack.add_argument("--input", type=Path, required=True)
    unpack.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    key = _key(args)
    result = pack_bundle(args.parts, args.output, key) if args.command == "pack" else unpack_bundle(args.input, args.output, key)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
