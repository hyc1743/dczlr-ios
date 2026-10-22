"""Inspect PE architecture and ordinary imports without loading the program.

Uses only Python's standard library. Does not inspect or extract game assets.
"""

import argparse
import hashlib
import json
import struct
from pathlib import Path


def inspect(path):
    path = Path(path)
    data = path.read_bytes()

    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError("PE structure extends beyond the file")
        return struct.unpack_from(fmt, data, offset)

    if data[:2] != b"MZ":
        raise ValueError("Missing MZ signature")
    pe = unpack("<I", 60)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Missing PE signature")
    machine, count, _, _, _, optional_size, _ = unpack("<HHIIIHH", pe + 4)
    optional = pe + 24
    magic = unpack("<H", optional)[0]
    if magic not in (0x10B, 0x20B):
        raise ValueError("Unsupported optional header")
    bits = 64 if magic == 0x20B else 32
    directories = optional + (112 if bits == 64 else 96)
    if optional_size < directories - optional:
        raise ValueError("Truncated optional header")
    sections = []
    for index in range(count):
        offset = optional + optional_size + index * 40
        unpack("<40s", offset)
        virtual_size, rva, raw_size, raw_offset = unpack("<IIII", offset + 8)
        sections.append({
            "name": data[offset:offset + 8].rstrip(b"\0").decode("ascii", "replace"),
            "rva": rva, "virtual_size": virtual_size,
            "raw_offset": raw_offset, "raw_size": raw_size,
        })

    headers_size = unpack("<I", optional + 60)[0]

    def raw(rva, size=1):
        if 0 <= rva < headers_size and rva + size <= min(headers_size, len(data)):
            return rva
        for section in sections:
            delta = rva - section["rva"]
            if 0 <= delta and delta + size <= section["raw_size"]:
                offset = section["raw_offset"] + delta
                if offset + size <= len(data):
                    return offset
        raise ValueError(f"RVA has no file-backed range: {rva:#x}")

    def string(rva):
        # Read each byte through the section map; no crossing into unrelated data.
        result = bytearray()
        for index in range(4096):
            value = data[raw(rva + index)]
            if value == 0:
                return result.decode("ascii", "replace")
            result.append(value)
        raise ValueError("Unterminated or excessively long import name")

    imports = []
    directory_count = unpack("<I", directories - 4)[0]
    if directory_count > 1:
        if directories + 16 > optional + optional_size:
            raise ValueError("Import directory exceeds optional header")
        import_rva, import_size = unpack("<II", directories + 8)
        if import_rva:
            terminated = False
            for delta in range(0, import_size - 19, 20):
                descriptor = unpack("<IIIII", raw(import_rva + delta, 20))
                if not any(descriptor):
                    terminated = True
                    break
                original, _, _, name, first = descriptor
                functions = []
                step = bits // 8
                thunk = original or first
                for index in range(len(data) // step):
                    value = unpack("<Q" if bits == 64 else "<I", raw(thunk + index * step, step))[0]
                    if value == 0:
                        break
                    functions.append(
                        {"ordinal": value & 0xFFFF}
                        if value & (1 << (bits - 1)) else {"name": string(value + 2)}
                    )
                else:
                    raise ValueError("Unterminated import thunk table")
                imports.append({"dll": string(name), "functions": functions})
            if not terminated:
                raise ValueError("Import directory lacks a bounded terminator")

    return {
        "path": path.name,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data), "machine": f"0x{machine:04x}",
        "architecture": {0x14C: "x86", 0x8664: "x86_64", 0xAA64: "arm64"}.get(machine, "unknown"),
        "bits": bits, "entry_rva": unpack("<I", optional + 16)[0],
        "sections": sections, "imports": imports,
        "limitations": [
            "Static file inspection only; target was not executed.",
            "Ordinary import table only; dynamic and delay-loaded APIs are not covered.",
            "Imports do not establish which functions execute or whether a port works.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = [inspect(path) for path in args.files]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Inspected {len(report)} PE files; wrote {args.output}")


if __name__ == "__main__":
    main()
