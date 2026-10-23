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


class ImageInfo(C.Structure):
    _fields_ = [("width", C.c_uint32), ("height", C.c_uint32), ("rgba_bytes", C.c_size_t)]


class SpriteDraw(C.Structure):
    _fields_ = [("vertex_buffer", C.c_size_t), ("texture", C.c_size_t),
                ("blend_mode", C.c_uint8), ("hidden", C.c_uint8),
                ("point_filter", C.c_uint8), ("software_vertex", C.c_uint8)]


class StartupState(C.Structure):
    _fields_ = [("card", C.c_uint32), ("waiting", C.c_uint32),
                ("advanced", C.c_uint32), ("elapsed", C.c_uint32)]


class StartupInput(C.Structure):
    _fields_ = [("delta", C.c_int32), ("transition_state", C.c_int32),
                ("transition_complete", C.c_uint32), ("skip_code", C.c_uint8)]


class StartupAction(C.Structure):
    _fields_ = [("kind", C.c_uint32), ("value", C.c_uint32)]


class StartupPlan(C.Structure):
    _fields_ = [("next", StartupState), ("count", C.c_uint32), ("actions", StartupAction * 3)]

    def record(self):
        return {"state": [self.next.card, self.next.waiting, self.next.advanced, self.next.elapsed],
                "actions": [[a.kind, a.value] for a in self.actions[:self.count]]}


class AnimationClip(C.Structure):
    _fields_ = [("first_frame", C.c_float), ("last_frame", C.c_float),
                ("blend_duration", C.c_uint32), ("loop", C.c_uint8),
                ("iterations", C.c_uint8), ("reverse", C.c_uint8), ("reserved", C.c_uint8)]


class AnimationState(C.Structure):
    _fields_ = [("previous", C.c_uint32), ("current", C.c_uint32), ("pending", C.c_uint32),
                ("blend_start", C.c_uint32), ("blend_end", C.c_uint32),
                ("blend", C.c_float), ("frame", C.c_float), ("pending_frame", C.c_float),
                ("fixed_frame", C.c_uint8)]

    def record(self):
        return {name: getattr(self, name) for name, _ in self._fields_}


class AnimationTiming(C.Structure):
    _fields_ = [("duration_seconds", C.c_float), ("next_clip", C.c_uint32),
                ("loop_limit", C.c_uint8), ("chain", C.c_uint8), ("reserved", C.c_uint8 * 2)]


class AnimationTickResult(C.Structure):
    _fields_ = [("previous_frame", C.c_float), ("samples", C.c_float * 2), ("sample_count", C.c_uint32)]


class XAInfo(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ("material_tracks", "event_tracks",
        "morph_index_sets", "morph_vector_sets", "morph_tracks", "bone_tracks",
        "has_clip_table", "clip_count")] + [("clip_table_offset", C.c_size_t), ("parsed_bytes", C.c_size_t)]

    def record(self):
        return {name: getattr(self, name) for name, _ in self._fields_}


class MaterialValue(C.Structure):
    _fields_ = [("components", C.c_float * 17)]


class MaterialKey(C.Structure):
    _fields_ = [("value", MaterialValue), ("frame", C.c_int32)]


class XAMaterialTrack(C.Structure):
    _fields_ = [("name_offset", C.c_size_t), ("keys_offset", C.c_size_t),
                ("name_length", C.c_uint32), ("key_count", C.c_uint32)]


class SpritePose(C.Structure):
    _fields_ = [(name, C.c_float) for name in (
        "width", "height", "x", "y", "z", "origin_x", "origin_y", "scale_x", "scale_y",
        "alpha", "rotation", "red", "green", "blue", "u0", "u1", "v0", "v1")]


class SpriteVertex(C.Structure):
    _fields_ = [("x", C.c_float), ("y", C.c_float), ("z", C.c_float), ("rhw", C.c_float),
                ("diffuse", C.c_uint32), ("specular", C.c_uint32), ("u", C.c_float), ("v", C.c_float)]


class SpriteCommand(C.Structure):
    _fields_ = [("kind", C.c_uint32), ("argument_count", C.c_uint32),
                ("arguments", C.c_size_t * 4)]


class SpritePlan(C.Structure):
    _fields_ = [("count", C.c_uint32), ("next_mode", C.c_uint32),
                ("commands", SpriteCommand * 17)]

    def records(self):
        if self.count > 17:
            raise ValueError("Sprite command count exceeds plan capacity")
        return [[command.kind, list(command.arguments[:command.argument_count])]
                for command in self.commands[:self.count]]


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
    sources = [ROOT / "native/resource/dc_pp.c", ROOT / "native/resource/dc_image.c", ROOT / "native/resource/dc_xa.c",
               ROOT / "native/render/dc_sprite.c", ROOT / "native/render/dc_sprite_vertices.c",
               ROOT / "native/game/dc_startup.c", ROOT / "native/game/dc_animation.c", ROOT / "native/game/dc_material.c"]
    inputs = sources + [ROOT / "native/include/dc_pp.h", ROOT / "native/include/dc_image.h",
                        ROOT / "native/include/dc_sprite.h", ROOT / "native/include/dc_startup.h",
                        ROOT / "native/include/dc_animation.h", ROOT / "native/include/dc_xa.h", ROOT / "native/include/dc_material.h"]
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
            *(str(p) for p in sources), *(["-lm"] if sys.platform != "win32" else []), "-o", str(target)], env=env,
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
    lib.dc_image_probe.argtypes = [C.c_void_p, C.c_size_t, C.c_int, C.POINTER(ImageInfo)]
    lib.dc_image_probe.restype = C.c_int
    lib.dc_image_decode.argtypes = [C.c_void_p, C.c_size_t, C.c_int, C.c_void_p,
                                    C.c_size_t, C.POINTER(ImageInfo)]
    lib.dc_image_decode.restype = C.c_int
    lib.dc_sprite_build_plan.argtypes = [C.POINTER(SpriteDraw), C.c_uint32, C.POINTER(SpritePlan)]
    lib.dc_sprite_build_plan.restype = C.c_int
    lib.dc_sprite_begin_plan.argtypes = [C.POINTER(SpritePlan)]
    lib.dc_sprite_begin_plan.restype = C.c_int
    lib.dc_sprite_build_vertices.argtypes = [C.POINTER(SpritePose), C.POINTER(SpriteVertex)]
    lib.dc_sprite_build_vertices.restype = C.c_int
    lib.dc_startup_begin_plan.argtypes = [C.POINTER(StartupPlan)]
    lib.dc_startup_begin_plan.restype = C.c_int
    lib.dc_startup_build_plan.argtypes = [C.POINTER(StartupState), C.POINTER(StartupInput), C.POINTER(StartupPlan)]
    lib.dc_startup_build_plan.restype = C.c_int
    lib.dc_animation_request.argtypes = [C.POINTER(AnimationState), C.POINTER(AnimationClip),
        C.c_size_t, C.c_uint32, C.c_uint8, C.c_uint32]
    lib.dc_animation_request.restype = C.c_int
    lib.dc_animation_query.argtypes = [C.POINTER(AnimationState), C.POINTER(AnimationClip),
        C.c_size_t, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32)]
    lib.dc_animation_query.restype = C.c_int
    lib.dc_animation_advance.argtypes = [C.POINTER(AnimationState), C.POINTER(AnimationClip),
        C.POINTER(AnimationTiming), C.c_size_t, C.c_uint32, C.c_uint32,
        C.c_float, C.c_uint32, C.POINTER(C.c_float)]
    lib.dc_animation_advance.restype = C.c_int
    lib.dc_animation_tick.argtypes = [C.POINTER(AnimationState), C.POINTER(AnimationClip),
        C.POINTER(AnimationTiming), C.c_size_t, C.c_uint32, C.c_float,
        C.c_uint32, C.POINTER(AnimationTickResult)]
    lib.dc_animation_tick.restype = C.c_int
    lib.dc_xa_probe.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(XAInfo)]
    lib.dc_xa_probe.restype = C.c_int
    lib.dc_xa_load_clips.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(AnimationClip),
        C.POINTER(AnimationTiming), C.c_size_t]
    lib.dc_xa_load_clips.restype = C.c_int
    lib.dc_xa_material_track_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(XAMaterialTrack)]
    lib.dc_xa_material_track_at.restype = C.c_int
    lib.dc_xa_load_material_keys.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(MaterialKey), C.c_size_t]
    lib.dc_xa_load_material_keys.restype = C.c_int
    lib.dc_material_interpolate.argtypes = [C.POINTER(MaterialKey), C.POINTER(MaterialKey), C.c_float, C.POINTER(MaterialValue)]
    lib.dc_material_interpolate.restype = C.c_int
    lib.dc_material_sample.argtypes = [C.POINTER(MaterialKey), C.c_size_t, C.POINTER(MaterialValue), C.c_float, C.POINTER(MaterialValue)]
    lib.dc_material_sample.restype = C.c_int
    return lib


def decode_image(data, format, max_bytes=64 * 1024 * 1024):
    """Decode via native C, bounding the allocation using a validated probe."""
    lib = library()
    info = ImageInfo()
    status = lib.dc_image_probe(data, len(data), format, C.byref(info))
    if status:
        raise ValueError("Native image probe failed with status " + str(status))
    if info.rgba_bytes > max_bytes:
        raise ValueError("Native image exceeds caller's output limit")
    output = C.create_string_buffer(info.rgba_bytes)
    status = lib.dc_image_decode(data, len(data), format, output, len(output), C.byref(info))
    if status:
        raise ValueError("Native image decode failed with status " + str(status))
    return info, output.raw


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
