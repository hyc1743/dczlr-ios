"""Isolate two pinned original startup functions; intercept all host operations.

Only the 247-byte update at 0x00512050 and its 209-byte state helper at
0x0052bc10 execute in Unicorn. Transition query/request, card loading and card
release are synthetic cdecl boundaries, never real graphics/filesystem calls.
Original instructions are read from the separately supplied, hash-pinned EXE;
they are neither embedded in the tool nor written to the public fixture.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

import capstone
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn import UC_PROT_READ, UC_PROT_WRITE, UC_PROT_EXEC
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EAX, UC_X86_REG_EBP
from native_core import library, StartupState, StartupInput, StartupPlan
from startup_cases import cases

TARGET_SHA256 = "70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07"
RANGES = {0x512050: 247, 0x52bc10: 209}
GLOBAL, CONTEXT, STACK, STOP = 0x83738c, 0x20000000, 0x10008000, 0x30000000
STUBS = {0x464ab0: "query", 0x464a60: "request", 0x511db0: "load", 0x512020: "release"}


class OriginalStartup:
    def __init__(self, path):
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != TARGET_SHA256:
            raise ValueError("Original input differs from pinned analyzed PE")
        pe = struct.unpack_from("<I", data, 60)[0]
        optional = pe + 24
        if struct.unpack_from("<H", data, pe + 4)[0] != 0x14c:
            raise ValueError("Expected PE32 x86")
        base = struct.unpack_from("<I", data, optional + 28)[0]
        image_size, headers = struct.unpack_from("<II", data, optional + 56)
        image_size = (image_size + 4095) & ~4095
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.uc.mem_map(base, image_size, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_write(base, data[:headers])
        section_offset = optional + struct.unpack_from("<H", data, pe + 20)[0]
        for i in range(struct.unpack_from("<H", data, pe + 6)[0]):
            _, rva, size, raw = struct.unpack_from("<IIII", data, section_offset + 40 * i + 8)
            self.uc.mem_write(base + rva, data[raw:raw+size])
        self.instructions = set()
        self.hashes = {}
        for start, length in RANGES.items():
            code = bytes(self.uc.mem_read(start, length))
            instructions = list(capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_32).disasm(code,start))
            if sum(i.size for i in instructions) != length or instructions[-1].mnemonic != "ret":
                raise ValueError("Function boundaries differ from static analysis")
            self.instructions.update(i.address for i in instructions)
            self.hashes[hex(start)] = hashlib.sha256(code).hexdigest()
        for address in STUBS:
            self.uc.mem_write(address, b"\xc3")
        self.uc.mem_protect(base, image_size, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.mem_protect(GLOBAL & ~4095, 4096, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(CONTEXT, 0x30000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(0x10000000, 0x10000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(STOP, 4096, UC_PROT_READ | UC_PROT_EXEC)
        self.uc.hook_add(UC_HOOK_CODE, self.code_guard)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self.write_guard)

    def word(self, address):
        return struct.unpack("<I", bytes(self.uc.mem_read(address,4)))[0]

    def write_guard(self, uc, access, address, size, value, context):
        if 0x10000000 <= address and address + size <= 0x10010000:
            return
        if (address,size) in ((GLOBAL+4,1),(GLOBAL+5,1),(GLOBAL+8,4)):
            return
        if size == 4 and address in [CONTEXT+x for x in (0x21f7c,0x21f80,0x21f84,0x21f88)]:
            return
        raise RuntimeError(f"Original wrote outside admitted state: {address:#x}/{size}")

    def code_guard(self, uc, address, size, context):
        if address in self.instructions:
            return
        if address not in STUBS:
            raise RuntimeError(f"Execution outside admitted functions: {address:#x}")
        stack = uc.reg_read(UC_X86_REG_ESP)
        target = self.word(stack)
        if target not in self.instructions:
            raise RuntimeError("Host stub return leaves admitted functions")
        kind = STUBS[address]
        if kind == "query":
            output = self.word(stack+4)
            if not STACK-4096 <= output <= STACK:
                raise RuntimeError("Unexpected transition output pointer")
            uc.mem_write(output, struct.pack("<i", self.input[1]))
            uc.reg_write(UC_X86_REG_EAX, self.input[2])
        elif kind == "request":
            self.actions.append([1,self.word(stack+4)])
        elif kind == "load":
            if self.word(stack+4) != CONTEXT or self.word(stack+8) != GLOBAL:
                raise RuntimeError("Unexpected card load arguments")
            self.actions.append([2,self.word(stack+12)])
        elif kind == "release":
            if self.word(stack+4) != CONTEXT:
                raise RuntimeError("Unexpected release context")
            self.actions.append([3,0])
        uc.reg_write(UC_X86_REG_ESP, stack+4)
        uc.reg_write(UC_X86_REG_EIP,target)

    def run(self, case):
        card, waiting, advanced, elapsed = case["state"]
        if advanced:
            raise ValueError("Original callback is replaced after advancing")
        self.input = case["input"]
        delta, transition, complete, skip = self.input
        self.actions = []
        self.uc.mem_write(GLOBAL, struct.pack("<IBB2xI",0x12345678,card,waiting,elapsed))
        self.uc.mem_write(CONTEXT+0x224,struct.pack("<i",delta))
        self.uc.mem_write(CONTEXT+0x260,bytes([skip]))
        self.uc.mem_write(CONTEXT+0x21f7c,struct.pack("<4I",0x512020,0x512050,0x1234,0x512150))
        self.uc.mem_write(STACK,struct.pack("<2I",STOP,CONTEXT))
        self.uc.reg_write(UC_X86_REG_ESP,STACK)
        self.uc.reg_write(UC_X86_REG_EBP,0)
        self.uc.emu_start(0x512050,STOP,count=1000)
        if self.uc.reg_read(UC_X86_REG_EIP) != STOP or self.uc.reg_read(UC_X86_REG_ESP) != STACK+4:
            raise RuntimeError("Original did not return within admitted bound")
        state = bytes(self.uc.mem_read(GLOBAL,12))
        next_stage = self.word(CONTEXT+0x21f80) == 0x512370
        if next_stage:
            self.actions.append([4,0])
            if any(self.word(CONTEXT+x) for x in (0x21f7c,0x21f84,0x21f88)):
                raise RuntimeError("Original left stale callbacks after advancing")
        return {"state":[state[4],state[5],int(next_stage),struct.unpack_from("<I",state,8)[0]],"actions":self.actions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--vectors",type=Path,required=True)
    args = parser.parse_args()
    original = OriginalStartup(args.exe)
    lib = library()
    digest = hashlib.sha256()
    count = 0
    examples = []
    for case in cases():
        reference = original.run(case)
        state, input = StartupState(*case["state"]), StartupInput(*case["input"])
        plan = StartupPlan()
        if lib.dc_startup_build_plan(C.byref(state),C.byref(input),C.byref(plan)) or plan.record() != reference:
            raise ValueError(f"Startup mismatch at {case}: original={reference}, native={plan.record()}")
        digest.update((json.dumps({**case,"output":reference},sort_keys=True,separators=(",",":"))+"\n").encode())
        if len(examples) < 16 and reference["actions"]:
            examples.append({**case,"output":reference})
        count += 1
    report = {"schema":1,"target_sha256":TARGET_SHA256,"cases":count,"output_sha256":digest.hexdigest(),
        "original_function_sha256":original.hashes,"execution":"isolated Unicorn x86 functions with synthetic host operations",
        "coverage":"two-card update/state helper; external transitions and resources not executed","examples":examples}
    for path in (args.output,args.vectors):
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"cases":count,"matched":True,"sha256":digest.hexdigest()}))


if __name__ == "__main__":
    main()
