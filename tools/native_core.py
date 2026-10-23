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


class PoseKey(C.Structure):
    _fields_ = [("frame", C.c_int32), ("values", C.c_float * 12)]


class PoseSelection(C.Structure):
    _fields_ = [("left", C.c_uint32), ("right", C.c_uint32), ("weight", C.c_float)]


class Matrix(C.Structure):
    _fields_ = [("values", C.c_float * 16)]


class MeshVertex(C.Structure):
    _fields_ = [("position", C.c_float*3), ("normal", C.c_float*3), ("uv", C.c_float*2)]


class Viewport(C.Structure):
    _fields_ = [(n,C.c_float) for n in ("x","y","width","height","min_z","max_z")]


class MenuButton(C.Structure):
    _fields_ = [(n,C.c_float) for n in ("x","y","width","height")]+[(n,C.c_uint32) for n in ("disabled","press_activate","toggle")]


class MenuState(C.Structure):
    _fields_ = [("selected",C.c_int32),("hover",C.c_int32),("active",C.c_uint32),("pressed",C.c_uint32*32),("toggled",C.c_uint32*32)]

    def record(self):
        return {n:list(getattr(self,n)) if n in ("pressed","toggled") else getattr(self,n) for n,_ in self._fields_}


class SaveUnlocks(C.Structure):
    _fields_ = [("edit",C.c_uint32),("extra",C.c_uint32)]


class TitleState(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('action','waiting','hover')]


class TitleInput(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('transition_ready','selection_busy','escape_code')]+[(n,C.c_int32) for n in ('menu_result','menu_row')]


class TitleCommand(C.Structure):
    _fields_ = [('kind',C.c_uint32),('value',C.c_uint32)]


class TitlePlan(C.Structure):
    _fields_ = [('next',TitleState),('count',C.c_uint32),('departed',C.c_uint32),('commands',TitleCommand*6)]

    def record(self):
        return {'state':[self.next.action,self.next.waiting,self.next.hover],
                'departed':self.departed,'commands':[[c.kind,c.value] for c in self.commands[:self.count]]}


class TextState(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('columns','max_lines','visible_lines','body_bytes')]+[(n,C.c_int32) for n in ('current_line','wait_state','wait_glyph','frame','last_frame')]+[(n,C.c_uint32) for n in ('last_fade_row','wait_line','wait_duration','wait_stamp','fade_index','active')]+[(n,C.c_int32) for n in ('x','y','font_size')]+[('scale',C.c_float),('rgb',C.c_uint32),('alpha',C.c_uint32*200),('line_lengths',C.c_uint32*5)]

    def record(self):
        return {n:list(getattr(self,n)) if n in ('alpha','line_lengths') else getattr(self,n) for n,_ in self._fields_}


class TextGlyph(C.Structure):
    _fields_ = [('x',C.c_int32),('y',C.c_int32),('color',C.c_uint32),('bytes',C.c_uint8*2),('reserved',C.c_uint8*2)]


class TextPlan(C.Structure):
    _fields_ = [('next',TextState),('count',C.c_uint32),('glyphs',TextGlyph*200)]


class TextAdvancePlan(C.Structure):
    _fields_ = [('next',TextState),('load_record',C.c_uint32),('finished',C.c_uint32)]


class ScriptSpan(C.Structure):
    _fields_ = [("offset",C.c_size_t),("length",C.c_size_t)]


class ScriptRecord(C.Structure):
    _fields_ = [("header",ScriptSpan),("speaker",ScriptSpan),("body",ScriptSpan),
                ("marker_offset",C.c_size_t),("next_offset",C.c_size_t),("frame",C.c_uint32)]


class ScriptControl(C.Structure):
    _fields_ = [('key',C.c_uint8*16),('parameter_bytes',C.c_uint32)]


class ScriptDecoded(C.Structure):
    _fields_ = [('record',ScriptRecord)]+[(n,C.c_uint8*20) for n in ('background','music','sound','message')]+[('controls',(C.c_uint8*37)*11)]


class IntroDescriptor(C.Structure):
    _fields_ = [('script',C.c_int32),('last_frame',C.c_int32)]


class IntroState(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('chapter','action','waiting','progress')]


class IntroCommand(C.Structure):
    _fields_ = [('kind',C.c_uint32),('value',C.c_uint32)]


class IntroPlan(C.Structure):
    _fields_ = [('next',IntroState),('count',C.c_uint32),('departed',C.c_uint32),('commands',IntroCommand*6)]

    def record(self):
        return {'state':[getattr(self.next,n) for n,_ in self.next._fields_],
            'departed':self.departed,'commands':[[v.kind,v.value] for v in self.commands[:self.count]]}


class SceneNode(C.Structure):
    _fields_ = [("parent", C.c_uint32), ("modifier", C.c_uint32),
                ("hidden", C.c_uint8), ("billboard", C.c_uint8), ("reserved", C.c_uint8 * 2),
                ("local", Matrix), ("extra", Matrix)]


class XAPoseTrack(C.Structure):
    _fields_ = [("name_offset", C.c_size_t), ("keys_offset", C.c_size_t),
                ("name_length", C.c_uint32), ("key_count", C.c_uint32), ("mode", C.c_uint32)]


class XAMaterialTrack(C.Structure):
    _fields_ = [("name_offset", C.c_size_t), ("keys_offset", C.c_size_t),
                ("name_length", C.c_uint32), ("key_count", C.c_uint32)]


class XXSpan(C.Structure):
    _fields_ = [("offset", C.c_size_t), ("length", C.c_size_t)]


class XXInfo(C.Structure):
    _fields_ = [(n, C.c_uint32) for n in ("nodes", "submeshes", "materials", "textures", "bones", "version_bits")] + [("parsed_bytes", C.c_size_t), ("opaque_tail", XXSpan)]

    def record(self):
        return {**{name: getattr(self, name) for name, _ in self._fields_ if name != "opaque_tail"},
                "opaque_tail": {"offset": self.opaque_tail.offset, "length": self.opaque_tail.length}}


class XXNode(C.Structure):
    _fields_ = [("name", XXSpan), ("matrix_offset", C.c_size_t)] + [(n, C.c_uint32) for n in ("parent", "children", "first_submesh", "submeshes")]


class XXSubmesh(C.Structure):
    _fields_ = [("indices", XXSpan), ("vertices", XXSpan), ("extra_uv", XXSpan * 3)] + [(n, C.c_uint32) for n in ("node", "material", "index_count", "vertex_count", "uv_sets")]


class XXMaterial(C.Structure):
    _fields_ = [("name", XXSpan), ("texture_names", XXSpan * 8), ("value_offset", C.c_size_t)]


class XXTexture(C.Structure):
    _fields_ = [("name", XXSpan), ("image", XXSpan), ("descriptor_offset", C.c_size_t)]


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
    sources = [ROOT / "native/resource/dc_pp.c", ROOT / "native/resource/dc_image.c", ROOT / "native/resource/dc_xa.c", ROOT / "native/resource/dc_xx.c", ROOT / "native/resource/dc_script.c",
               ROOT / "native/render/dc_mesh.c", ROOT / "native/render/dc_sprite.c", ROOT / "native/render/dc_sprite_vertices.c",
               ROOT / "native/game/dc_startup.c", ROOT / "native/game/dc_animation.c", ROOT / "native/game/dc_material.c", ROOT / "native/game/dc_pose.c", ROOT / "native/game/dc_scene.c", ROOT / "native/game/dc_model.c", ROOT / "native/game/dc_menu.c", ROOT / "native/game/dc_save.c", ROOT / "native/game/dc_text.c"]
    inputs = sources + [ROOT / "native/include/dc_pp.h", ROOT / "native/include/dc_image.h",
                        ROOT / "native/include/dc_sprite.h", ROOT / "native/include/dc_startup.h",
                        ROOT / "native/include/dc_animation.h", ROOT / "native/include/dc_xa.h", ROOT / "native/include/dc_material.h", ROOT / "native/include/dc_xx.h", ROOT / "native/include/dc_pose.h", ROOT / "native/include/dc_scene.h", ROOT / "native/include/dc_mesh.h", ROOT / "native/include/dc_model.h", ROOT / "native/include/dc_menu.h", ROOT / "native/include/dc_save.h", ROOT / "native/include/dc_script.h", ROOT / "native/include/dc_text.h"]
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
    lib.dc_xx_load_mesh_vertices.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t]
    lib.dc_xx_load_mesh_vertices.restype = C.c_int
    lib.dc_xx_load_mesh_indices.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(C.c_uint16),C.c_size_t]
    lib.dc_xx_load_mesh_indices.restype = C.c_int
    lib.dc_mesh_project.argtypes = [C.POINTER(MeshVertex),C.c_size_t,C.POINTER(C.c_uint16),C.c_size_t,C.POINTER(Matrix),C.POINTER(Viewport),C.c_uint32,C.POINTER(SpriteVertex),C.c_size_t]
    lib.dc_mesh_project.restype = C.c_int
    lib.dc_model_open.argtypes = [C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_void_p)]
    lib.dc_model_open.restype = C.c_int
    lib.dc_model_close.argtypes = [C.c_void_p]
    lib.dc_model_close.restype = None
    lib.dc_model_request.argtypes = [C.c_void_p,C.c_uint32,C.c_uint32]
    lib.dc_model_request.restype = C.c_int
    lib.dc_model_query.argtypes = [C.c_void_p,C.POINTER(C.c_uint32),C.POINTER(C.c_uint32)]
    lib.dc_model_query.restype = C.c_int
    lib.dc_model_tick.argtypes = [C.c_void_p,C.c_uint32,C.c_uint32,C.POINTER(Matrix)]
    lib.dc_model_tick.restype = C.c_int
    for name,record in (("get_info",XXInfo),("material",MaterialValue),("global",Matrix),("mesh",XXSubmesh)):
        function=getattr(lib,"dc_model_"+name)
        function.argtypes=[C.c_void_p]+([] if name=="get_info" else [C.c_uint32])+[C.POINTER(record)]
        function.restype=C.c_int
    lib.dc_model_project.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(Matrix),C.POINTER(Viewport),C.c_uint32,C.POINTER(SpriteVertex),C.c_size_t]
    lib.dc_model_project.restype = C.c_int
    lib.dc_script_find.argtypes = [C.c_void_p,C.c_size_t,C.c_size_t,C.c_uint32,C.POINTER(ScriptRecord)]
    lib.dc_script_find.restype = C.c_int
    lib.dc_game_state_init.argtypes = [C.c_void_p,C.c_size_t]
    lib.dc_game_state_init.restype = C.c_int
    lib.dc_save_transform.argtypes = [C.c_void_p,C.c_size_t]
    lib.dc_save_transform.restype = C.c_int
    lib.dc_save_get_unlocks.argtypes = [C.c_void_p,C.c_size_t,C.POINTER(SaveUnlocks)]
    lib.dc_save_get_unlocks.restype = C.c_int
    lib.dc_menu_step.argtypes = [C.POINTER(MenuState),C.POINTER(MenuButton),C.c_size_t,C.c_int32,C.c_int32,C.c_float,C.c_uint8,C.POINTER(C.c_int32)]
    lib.dc_menu_step.restype = C.c_int
    lib.dc_title_build_plan.argtypes = [C.POINTER(TitleState),C.POINTER(TitleInput),C.POINTER(TitlePlan)]
    lib.dc_title_build_plan.restype = C.c_int
    lib.dc_text_build_plan.argtypes = [C.POINTER(TextState),C.c_void_p,C.c_size_t,C.c_int32,C.c_uint32,C.c_uint32,C.POINTER(TextPlan)]
    lib.dc_text_build_plan.restype = C.c_int
    lib.dc_text_advance.argtypes = [C.POINTER(TextState),C.c_uint32,C.POINTER(TextAdvancePlan)]
    lib.dc_text_advance.restype = C.c_int
    lib.dc_script_decode.argtypes = [C.c_void_p,C.c_size_t,C.c_size_t,C.c_uint32,C.POINTER(ScriptControl),C.c_size_t,C.POINTER(ScriptDecoded)]
    lib.dc_script_decode.restype = C.c_int
    lib.dc_intro_finish.argtypes = [C.POINTER(IntroState),C.POINTER(IntroDescriptor),C.c_size_t,C.POINTER(IntroPlan)]
    lib.dc_intro_finish.restype = C.c_int
    lib.dc_intro_transition.argtypes = [C.POINTER(IntroState),C.POINTER(IntroDescriptor),C.c_size_t,C.c_uint32,C.POINTER(IntroPlan)]
    lib.dc_intro_transition.restype = C.c_int
    lib.dc_scene_update.argtypes = [C.POINTER(SceneNode), C.c_size_t, C.POINTER(Matrix), C.POINTER(Matrix), C.c_size_t]
    lib.dc_scene_update.restype = C.c_int
    lib.dc_pose_select.argtypes = [C.POINTER(PoseKey), C.c_size_t, C.c_float, C.POINTER(PoseSelection)]
    lib.dc_pose_select.restype = C.c_int
    lib.dc_pose_sample.argtypes = [C.POINTER(PoseKey), C.c_size_t, C.c_uint32, C.c_float, C.POINTER(Matrix)]
    lib.dc_pose_sample.restype = C.c_int
    lib.dc_matrix_multiply.argtypes = [C.POINTER(Matrix), C.POINTER(Matrix), C.POINTER(Matrix)]
    lib.dc_matrix_multiply.restype = C.c_int
    lib.dc_xa_pose_track_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(XAPoseTrack)]
    lib.dc_xa_pose_track_at.restype = C.c_int
    lib.dc_xa_load_pose_keys.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(PoseKey), C.c_size_t]
    lib.dc_xa_load_pose_keys.restype = C.c_int
    lib.dc_material_interpolate.argtypes = [C.POINTER(MaterialKey), C.POINTER(MaterialKey), C.c_float, C.POINTER(MaterialValue)]
    lib.dc_material_interpolate.restype = C.c_int
    lib.dc_material_sample.argtypes = [C.POINTER(MaterialKey), C.c_size_t, C.POINTER(MaterialValue), C.c_float, C.POINTER(MaterialValue)]
    lib.dc_material_sample.restype = C.c_int
    lib.dc_xx_probe.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(XXInfo)]
    lib.dc_xx_probe.restype = C.c_int
    lib.dc_xx_open.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(C.c_void_p)]
    lib.dc_xx_open.restype = C.c_int
    lib.dc_xx_close.argtypes = [C.c_void_p]
    lib.dc_xx_close.restype = None
    lib.dc_xx_get_info.argtypes = [C.c_void_p, C.POINTER(XXInfo)]
    lib.dc_xx_get_info.restype = C.c_int
    for method, structure in (("node", XXNode), ("submesh", XXSubmesh), ("material", XXMaterial), ("texture", XXTexture)):
        function = getattr(lib, "dc_xx_" + method + "_at")
        function.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(structure)]
        function.restype = C.c_int
    lib.dc_xx_find_material_encoded.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_uint32)]
    lib.dc_xx_find_material_encoded.restype = C.c_int
    lib.dc_xx_find_node_encoded.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_uint32)]
    lib.dc_xx_find_node_encoded.restype = C.c_int
    lib.dc_xx_node_matrix.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(Matrix)]
    lib.dc_xx_node_matrix.restype = C.c_int
    lib.dc_xx_material_baseline.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(MaterialValue)]
    lib.dc_xx_material_baseline.restype = C.c_int
    lib.dc_xx_image_probe.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(ImageInfo)]
    lib.dc_xx_image_probe.restype = C.c_int
    lib.dc_xx_image_decode.argtypes = [C.c_void_p, C.c_uint32, C.c_void_p, C.c_size_t, C.POINTER(ImageInfo)]
    lib.dc_xx_image_decode.restype = C.c_int
    return lib


class XXModel:
    """Own the borrowed source buffer for the entire native metadata lifetime."""
    def __init__(self, data):
        self.data = data
        self.source = C.create_string_buffer(data)
        self.lib = library()
        self.handle = C.c_void_p()
        status = self.lib.dc_xx_open(self.source, len(data), C.byref(self.handle))
        if status:
            raise ValueError("Native XX open failed with status " + str(status))

    def __enter__(self): return self

    def __exit__(self, *_): self.close()

    def close(self):
        if self.handle:
            self.lib.dc_xx_close(self.handle)
            self.handle = C.c_void_p()

    def info(self):
        out = XXInfo()
        if self.lib.dc_xx_get_info(self.handle, C.byref(out)):
            raise ValueError("Native XX info failed")
        return out

    def at(self, kind, index):
        structure = {"node": XXNode, "submesh": XXSubmesh, "material": XXMaterial, "texture": XXTexture}[kind]
        out = structure()
        if getattr(self.lib, "dc_xx_" + kind + "_at")(self.handle, index, C.byref(out)):
            raise ValueError("Native XX index failed: " + kind)
        return out

    def span(self, span): return self.data[span.offset:span.offset + span.length]

    def baseline(self, index):
        out = MaterialValue()
        if self.lib.dc_xx_material_baseline(self.handle, index, C.byref(out)):
            raise ValueError("Native XX baseline failed")
        return out

    def image(self, index, max_bytes=64 * 1024 * 1024):
        info = ImageInfo()
        if self.lib.dc_xx_image_probe(self.handle, index, C.byref(info)):
            raise ValueError("Native XX image profile rejected")
        if info.rgba_bytes > max_bytes:
            raise ValueError("Native XX image exceeds caller output cap")
        out = C.create_string_buffer(info.rgba_bytes)
        if self.lib.dc_xx_image_decode(self.handle, index, out, len(out), C.byref(info)):
            raise ValueError("Native XX image decode failed")
        return info, out.raw


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
