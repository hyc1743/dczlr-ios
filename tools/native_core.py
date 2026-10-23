"""Build and exercise PortLab's native C modules on the analysis host.

This helper never loads an original game executable. Original-function oracles
are separate, explicit offline analysis commands.
"""
from functools import lru_cache
import ctypes as C
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
READ_AT = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.c_void_p, C.c_size_t)


class Source(C.Structure):
    _fields_ = [("context", C.c_void_p), ("length", C.c_uint64), ("read_at", READ_AT)]


class Entry(C.Structure):
    _fields_ = [("name", C.c_uint8 * 32), ("offset", C.c_uint64),
                ("size", C.c_uint32), ("name_length", C.c_uint32)]

    @property
    def name_bytes(self):
        return bytes(self.name[:self.name_length])


def compiler_command():
    explicit = os.environ.get("DC_NATIVE_COMPILER")
    if explicit:
        executable = Path(explicit).resolve(strict=True)
        return [str(executable)] + (["cc"] if executable.stem == "zig" else [])
    for name in ("cc", "clang", "gcc"):
        if command := shutil.which(name):
            return [command]
    installed = sorted((ROOT / ".tools/zig").glob("zig-*/zig.exe"))
    if installed:
        return [str(installed[-1]), "cc"]
    raise RuntimeError("A native C compiler is required; set DC_NATIVE_COMPILER")


@lru_cache(maxsize=1)
def library():
    command = compiler_command()
    sources = [ROOT / "native/resource/dc_pp.c"]
    inputs = sources + [ROOT / "native/include/dc_pp.h"]
    digest = hashlib.sha256("\0".join(command).encode())
    for path in inputs:
        digest.update(path.read_bytes())
    directory = ROOT / "out/native-core"
    directory.mkdir(parents=True, exist_ok=True)
    extension = ".dll" if sys.platform == "win32" else ".dylib" if sys.platform == "darwin" else ".so"
    target = directory / ("portlab-native-" + digest.hexdigest()[:16] + extension)
    if not target.exists():
        shared_flags = ["-dynamiclib", "-fPIC"] if sys.platform == "darwin" else ["-shared"]
        if sys.platform not in ("win32", "darwin"):
            shared_flags += ["-fPIC"]
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / ".tools/zig-cache"))
        result = subprocess.run(command + ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-DDC_NATIVE_SHARED", *shared_flags, "-I" + str(ROOT / "native/include"),
            *(str(p) for p in sources), "-o", str(target)], env=env,
            capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError("Native C compilation failed:\n" + result.stderr[-8000:])
    lib = C.CDLL(str(target))
    lib.dc_pp_open.argtypes = [C.POINTER(Source), C.POINTER(C.c_void_p)]
    lib.dc_pp_open.restype = C.c_int
    lib.dc_pp_close.argtypes = [C.c_void_p]
    lib.dc_pp_close.restype = None
    lib.dc_pp_count.argtypes = [C.c_void_p]
    lib.dc_pp_count.restype = C.c_uint32
    lib.dc_pp_entry_at.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(Entry)]
    lib.dc_pp_entry_at.restype = C.c_int
    lib.dc_pp_find_exact.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_uint32)]
    lib.dc_pp_find_exact.restype = C.c_int
    lib.dc_pp_read.argtypes = [C.c_void_p, C.c_uint32, C.c_uint64, C.c_void_p, C.c_size_t]
    lib.dc_pp_read.restype = C.c_int
    lib.dc_pp_decode_bytes.argtypes = [C.c_void_p, C.c_size_t]
    lib.dc_pp_decode_bytes.restype = C.c_int
    lib.dc_pp_basename_offset.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]
    lib.dc_pp_basename_offset.restype = C.c_int
    lib.dc_pp_find_ascii_path.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_uint32)]
    lib.dc_pp_find_ascii_path.restype = C.c_int
    return lib


class PPArchive:
    def __init__(self, source):
        self._lib = library()
        self._file = None if isinstance(source, bytes) else Path(source).open("rb")
        self._bytes = source if isinstance(source, bytes) else None
        length = len(source) if self._file is None else os.fstat(self._file.fileno()).st_size

        def read_at(context, offset, out, size):
            if offset > length or size > length - offset:
                return 0
            try:
                if self._file is None:
                    data = self._bytes[offset:offset + size]
                else:
                    self._file.seek(offset)
                    data = self._file.read(size)
                if len(data) != size:
                    return 0
                C.memmove(out, data, size)
                return 1
            except (OSError, ValueError):
                return 0

        self._callback = READ_AT(read_at)
        self._source = Source(None, length, self._callback)
        self._handle = C.c_void_p()
        status = self._lib.dc_pp_open(C.byref(self._source), C.byref(self._handle))
        if status:
            self.close()
            raise ValueError("Native PP open failed with status " + str(status))

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        if self._handle:
            self._lib.dc_pp_close(self._handle)
            self._handle = C.c_void_p()
        if self._file is not None:
            self._file.close()

    @property
    def count(self):
        return self._lib.dc_pp_count(self._handle)

    def entry(self, index):
        result = Entry()
        status = self._lib.dc_pp_entry_at(self._handle, index, C.byref(result))
        if status:
            raise ValueError("Native PP entry failed with status " + str(status))
        return result

    def read(self, index, offset=0, length=None):
        entry = self.entry(index)
        length = entry.size - offset if length is None else length
        if offset < 0 or length < 0:
            raise ValueError("Negative read range")
        # Check the range before allocating the caller's output buffer.
        if offset > entry.size or length > entry.size - offset:
            raise ValueError("Read extends beyond entry")
        result = C.create_string_buffer(length)
        status = self._lib.dc_pp_read(self._handle, index, offset, result, length)
        if status:
            raise ValueError("Native PP read failed with status " + str(status))
        return result.raw
