"""Offline comparison of the pinned original basename scanner and native C.

Only the admitted x86 leaf is interpreted on the analysis host; it is never
linked into the iOS runtime. No full game process or Windows APIs are invoked.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
from native_core import library, PPArchive
from oracle_pp_codec import OriginalCodec, TARGET_SHA256


def compare(exe, directory):
    original = OriginalCodec(exe, 0x423250, 118)
    lib = library()
    values = [b"a.bmp", b"Data\\a.bmp", b"one\\two\\a.bmp", b"dir.name\\a.bmp",
              b"dir/asset.bmp", b"\x81\\folder\\a.bmp", b"\x81.a.bmp"]
    for path in sorted(directory.glob("*.pp")):
        try:
            archive = PPArchive(path)
        except ValueError:
            continue
        with archive:
            for index in range(archive.count):
                values.append(archive.entry(index).name_bytes)
    for value in values:
        expected = original.basename_offset(value)
        offset = C.c_size_t()
        if lib.dc_pp_basename_offset(value, len(value), C.byref(offset)) or offset.value != expected:
            raise RuntimeError("Original and native basename scanners disagree")
    return {"original_exe_sha256": TARGET_SHA256, "function_entry": "0x423250",
            "function_bytes": 118, "function_sha256": original.code_sha256,
            "cases": len(values), "all_cases_match": True,
            "missing_dot_inputs": "native rejects; original unsafe behavior not executed",
            "comparison_casefold": "not tested by this leaf oracle",
            "ios_execution": "not_tested", "game_playability": "not_verified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.exe, args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))
