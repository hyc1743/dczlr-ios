"""Isolated numeric original-code probes. Never launches the original process.

Runs only pinned original 0050f220 (and its CRT conversion helper 0061e344),
plus a synthetic Reset branch in 0050f6f0. All audio/render/scene consumers are
host stubs. No original graphics, scripts, or resources are loaded.
"""
import argparse
from pathlib import Path
import hashlib
import json
import struct
import sys

import pefile
import unicorn
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_EIP, UC_X86_REG_ESP, UC_X86_REG_EBP, UC_X86_REG_EAX, UC_X86_REG_FPCW

ARGS = argparse.ArgumentParser(description=__doc__)
ARGS.add_argument("--exe",type=Path,required=True)
ARGS.add_argument("--output",type=Path,required=True)
ARGS=ARGS.parse_args()
EXE=ARGS.exe
EXPECTED_SHA256 = "70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07"
MAIN = 0x20000000
CONTEXT = 0x21000000
STACK = 0x10000000
STOP = 0x30000000
GROUP_BASES = [CONTEXT + 0x10 + i * 0x790 for i in range(6)]
CFG = MAIN + 0x21FCC

def u32(v): return struct.pack("<I", v & 0xFFFFFFFF)
def f32(v): return struct.pack("<f", v)
def bits(v): return struct.unpack("<I", f32(v))[0]
def read_u32(uc, addr): return struct.unpack("<I", uc.mem_read(addr, 4))[0]
def read_f32(uc, addr): return struct.unpack("<f", uc.mem_read(addr, 4))[0]

def default_config(pads=b"\x00\x00"):
    return struct.pack("<iii3f6B", -1200, -1200, -1200, 1, 1, 1, 1, 1, 1, 1, 1, 1) + pads + struct.pack("<4f", 0, 0, 0, 4)

DATA = EXE.read_bytes()
assert hashlib.sha256(DATA).hexdigest() == EXPECTED_SHA256
PE = pefile.PE(data=DATA)
IMAGE_BASE = PE.OPTIONAL_HEADER.ImageBase
IMAGE = PE.get_memory_mapped_image()
ASYNC_IMPORT = next(i.address for d in PE.DIRECTORY_ENTRY_IMPORT for i in d.imports if i.name == b"GetAsyncKeyState")

def make_machine(precision=0x027F, reset=False):
    uc = Uc(UC_ARCH_X86, UC_MODE_32)
    image_size = (PE.OPTIONAL_HEADER.SizeOfImage + 0xFFF) & ~0xFFF
    uc.mem_map(IMAGE_BASE, image_size)
    uc.mem_write(IMAGE_BASE, IMAGE)
    for base, size in [(MAIN, 0x30000), (CONTEXT, 0x4000), (STACK, 0x200000), (STOP, 0x1000)]:
        uc.mem_map(base, size)
    uc.mem_write(CFG, default_config())
    uc.mem_write(MAIN + 0x228, f32(1))
    uc.mem_write(0x835C38, u32(MAIN + 0x28000))
    uc.reg_write(UC_X86_REG_FPCW, precision)
    calls = []
    consumers = {0x402530: 2, 0x47C4A0: 2, 0x47C500: 2, 0x47C680: 2, 0x47C990: 1}
    if reset:
        consumers.update({0x52AEF0: 2, 0x4024B0: 2, 0x464A60: 1, 0x47B4B0: 1, 0x47C170: 1})
        uc.mem_write(ASYNC_IMPORT, u32(STOP + 0x100))
        uc.mem_write(0x835C81, b"\x00")
    def return_from_call(value=0, pop=0):
        esp = uc.reg_read(UC_X86_REG_ESP)
        uc.reg_write(UC_X86_REG_EAX, value & 0xFFFFFFFF)
        uc.reg_write(UC_X86_REG_ESP, esp + 4 + pop)
        uc.reg_write(UC_X86_REG_EIP, read_u32(uc, esp))
    def hook(machine, address, size, userdata):
        if address == STOP:
            machine.emu_stop()
            return
        if address in consumers:
            esp = machine.reg_read(UC_X86_REG_ESP)
            args = [read_u32(machine, esp + 4 + 4 * i) for i in range(consumers[address])]
            calls.append({"function": f"{address:08x}", "args": args})
            return_from_call()
        elif reset and address == 0x467B90:
            return_from_call()
        elif reset and address == 0x45F7C0:
            esp = machine.reg_read(UC_X86_REG_ESP)
            group = read_u32(machine, esp + 4)
            # Report a stable hover + click on group5 item0 (Reset).
            if group == 0x835480:
                machine.mem_write(group + 0x504, u32(0))
                return_from_call(1)
            else:
                return_from_call(0xFFFFFFFF)
        elif reset and address == STOP + 0x100:
            return_from_call(0, pop=4)
    uc.hook_add(UC_HOOK_CODE, hook)
    return uc, calls

def invoke(uc, address, args):
    esp = STACK + 0x1F0000
    uc.mem_write(esp, u32(STOP) + b"".join(u32(v) for v in args))
    uc.reg_write(UC_X86_REG_ESP, esp)
    uc.reg_write(UC_X86_REG_EBP, 0)
    uc.emu_start(address, STOP + 1, count=100000)
    assert uc.reg_read(UC_X86_REG_EIP) == STOP

SPECS = [
    {"name": "voice", "group": 0, "index": 0, "cfg": 0, "track": [260, 103, 650, 17], "kind": "i32"},
    {"name": "bgm", "group": 0, "index": 1, "cfg": 8, "track": [260, 156, 650, 17], "kind": "i32"},
    {"name": "se", "group": 0, "index": 2, "cfg": 4, "track": [260, 209, 650, 17], "kind": "i32"},
    {"name": "hand_alpha", "group": 1, "index": 0, "cfg": 12, "track": [260, 289, 230, 17], "kind": "f32"},
    {"name": "body_alpha", "group": 1, "index": 1, "cfg": 16, "track": [260, 349, 230, 17], "kind": "f32"},
    {"name": "underwear_alpha", "group": 1, "index": 2, "cfg": 20, "track": [260, 409, 230, 17], "kind": "f32"},
    {"name": "wheel_speed", "group": 1, "index": 3, "cfg": 44, "track": [260, 573, 230, 17], "kind": "f32"},
    {"name": "background_r", "group": 2, "index": 0, "cfg": 32, "track": [610, 434, 295, 22], "kind": "f32"},
    {"name": "background_g", "group": 2, "index": 1, "cfg": 36, "track": [610, 458, 295, 22], "kind": "f32"},
    {"name": "background_b", "group": 2, "index": 2, "cfg": 40, "track": [610, 482, 295, 22], "kind": "f32"},
]

def slider_case(spec, requested_center, hit_track=False, precision=0x027F):
    uc, calls = make_machine(precision)
    group, index = spec["group"], spec["index"]
    count = 4 if group == 1 else 3
    gbase = GROUP_BASES[group]
    track_index = index + count
    x, y, width, height = spec["track"]
    for addr, value in [(gbase + 0x200 + index * 4, requested_center - 12), (gbase + 0x400 + index * 4, 24), (gbase + 0x200 + track_index * 4, x), (gbase + 0x400 + track_index * 4, width)]:
        uc.mem_write(addr, f32(value))
    uc.mem_write(CONTEXT + 0x2DE4, u32(index + count if hit_track else index))
    uc.mem_write(CONTEXT + 0x2DE8, u32(group))
    for off, value in [(0x2DD0, 0x4113B13B), (0x2DD4, 0x3B8E7835), (0x2DD8, 0x3D20473C), (0x2DDC, 0x3F5D49C3)]:
        uc.mem_write(CONTEXT + off, u32(value))
    for i, value in enumerate([0x11110000, 0x22220000, 0x33330000, 0x44440000]):
        uc.mem_write(CONTEXT + i * 4, u32(value))
    initial = bytes(uc.mem_read(CFG, 48))
    invoke(uc, 0x50F220, [MAIN, CONTEXT])
    actual = bytes(uc.mem_read(CFG, 48))
    offset = spec["cfg"]
    assert initial[:offset] == actual[:offset] and initial[offset + 4:] == actual[offset + 4:]
    value = struct.unpack_from("<i" if spec["kind"] == "i32" else "<f", actual, offset)[0]
    return {"name": spec["name"], "group": group, "hit_index": index + count if hit_track else index, "cfg_offset": offset, "requested_center_f32": struct.unpack("<f", f32(requested_center))[0], "requested_center_bits": f"{bits(requested_center):08x}", "value": value, "value_bits": actual[offset:offset + 4].hex(), "knob_left": read_f32(uc, gbase + 0x200 + index * 4), "knob_center": read_f32(uc, gbase + 0x300 + index * 4), "calls": calls}

def reset_case():
    uc, calls = make_machine(reset=True)
    # Synthetic nondefaults and deliberately nonzero structure padding.
    initial = struct.pack("<iii3f6B", -80, -90, -100, 0.2, 0.3, 0.4, 0, 0, 0, 0, 0, 0) + b"\xA5\x5A" + struct.pack("<4f", 77, 88, 99, 9)
    uc.mem_write(CFG, initial)
    invoke(uc, 0x50F6F0, [MAIN])
    actual = bytes(uc.mem_read(CFG, 48))
    expected = default_config(b"\xA5\x5A")
    assert actual == expected, (actual.hex(), expected.hex())
    return {"entry": "0050f6f0", "trigger": "stub hit tester returns group5 item0 click", "initial_hex": initial.hex(), "actual_hex": actual.hex(), "expected_hex": expected.hex(), "padding_preserved": actual[30:32].hex() == "a55a", "calls": calls}

def main():
    rows = []
    for spec in SPECS:
        x, y, width, height = spec["track"]
        centers = [x - 100, x, x + 0.001, x + width * 0.123456, x + width / 2, x + width * 0.9988, x + width * 0.999, x + width * 0.9991, x + width, x + width + 100]
        for center in centers:
            row = slider_case(spec, center)
            rows.append(row)
            other = slider_case(spec, center, precision=0x037F)
            assert row == other, (row, other)
        # Track-hit index and knob-hit index share the same modulo mapping.
        track_row = slider_case(spec, x + width * 0.333333, hit_track=True)
        rows.append(track_row)
        knob_row = slider_case(spec, x + width * 0.333333)
        assert track_row["value_bits"] == knob_row["value_bits"]
    result = {"method": "Unicorn x86 isolated original code with synthetic contexts; no original process/resources", "artifact_sha256": EXPECTED_SHA256, "unicorn_version": unicorn.__version__, "slider_entry": "0050f220", "numeric_helper": "0061e344", "x87_control_word": "027f", "cross_checked_control_word": "037f", "all_float_outputs_identical_between_precision_modes": True, "limits": ["static/emulated evidence, not original process runtime", "only numeric function and Reset branch exercised", "audio, scene application, hit tester, keyboard and transition calls are stubs"], "specs": SPECS, "vectors": rows, "reset": reset_case()}
    output = ARGS.output
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(output), "slider_vectors": len(rows), "precision_crosscheck": True, "reset_padding_preserved": result["reset"]["padding_preserved"]}))

if __name__ == "__main__":
    main()
