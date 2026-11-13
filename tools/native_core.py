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

class XAMorphIndexSet(C.Structure):
    _fields_=[('indices_offset',C.c_size_t),('data_offset',C.c_size_t),('count',C.c_uint32),('data_length',C.c_uint32),('selector',C.c_uint8)]
class XAMorphVectorSet(C.Structure):
    _fields_=[('vectors_offset',C.c_size_t),('data_offset',C.c_size_t),('count',C.c_uint32),('data_length',C.c_uint32)]
class XAMorphTrack(C.Structure):
    _fields_=[('name_offset',C.c_size_t),('target_offset',C.c_size_t),('keys_offset',C.c_size_t),('tail_offset',C.c_size_t),('name_length',C.c_uint32),('target_length',C.c_uint32),('key_count',C.c_uint32)]
class XAMorphKey(C.Structure):
    _fields_=[('value_offset',C.c_size_t),('value_length',C.c_uint32),('raw',C.c_uint8*6)]

class XAEventTrack(C.Structure):
    _fields_=[('name_offset',C.c_size_t),('keys_offset',C.c_size_t),('tail_offset',C.c_size_t),
              ('type',C.c_uint32),('name_length',C.c_uint32),('parameter',C.c_uint32),
              ('key_count',C.c_uint32),('tail_value',C.c_uint32),
              ('flag_a',C.c_uint8),('flag_b',C.c_uint8),('flag_c',C.c_uint8),
              ('flag_d',C.c_uint8),('tail_flag',C.c_uint8)]

class XAEventKey(C.Structure):
    _fields_=[('frame',C.c_uint32),('value',C.c_uint8)]


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


class CameraOrbit(C.Structure):
    _fields_ = [("base", Matrix)]+[(n,C.c_float) for n in ("stored_distance","height","pitch","yaw")]

class CameraPointerInput(C.Structure):
    _fields_=[(n,C.c_int32) for n in ('dx','dy','wheel')]+[(n,C.c_uint8) for n in ('left','right','middle','fast')]
class CameraPointerLimits(C.Structure):
    _fields_=[(n,C.c_float) for n in ('far_distance','near_distance','high','low','wheel_step')]


class CameraLens(C.Structure):
    _fields_ = [(n,C.c_float) for n in ("fov_y","near_z","far_z")]+[(n,C.c_uint32) for n in ("viewport_width","viewport_height")]


class CameraMatrices(C.Structure):
    _fields_ = [(n,Matrix) for n in ("world","view","projection","view_projection")]


class XLSpan(C.Structure):
    _fields_ = [("offset", C.c_size_t), ("length", C.c_uint32)]


class XLInfo(C.Structure):
    _fields_ = [("lights", C.c_uint32), ("parsed_bytes", C.c_size_t)]


class XLLight(C.Structure):
    _fields_ = [("name", XLSpan), ("target", XLSpan),
                ("kind", C.c_uint8), ("enabled", C.c_uint8),
                ("flags", C.c_uint8 * 3),
                ("diffuse", C.c_float * 4), ("ambient", C.c_float * 4),
                ("specular", C.c_float * 4), ("position", C.c_float * 4),
                ("direction", C.c_float * 4), ("parameters", C.c_float * 5),
                ("transform", C.c_float * 16)]


class XLD3DLight(C.Structure):
    _fields_ = [("name", XLSpan), ("target", XLSpan),
                ("mode", C.c_uint8), ("d3d_type", C.c_uint32),
                ("diffuse", C.c_float * 4), ("specular", C.c_float * 4),
                ("ambient", C.c_float * 4), ("position", C.c_float * 3),
                ("direction", C.c_float * 3), ("range", C.c_float),
                ("falloff", C.c_float), ("attenuation", C.c_float * 3),
                ("theta", C.c_float), ("phi", C.c_float),
                ("transform", C.c_float * 16)]


class GlareInfo(C.Structure):
    _fields_ = [("scale", C.c_float), ("flag", C.c_uint8),
                ("threshold", C.c_float), ("intensity", C.c_float),
                ("spread", C.c_float), ("passes", C.c_uint8),
                ("power_a", C.c_float), ("power_b", C.c_float)]


class LightEntry(C.Structure):
    _fields_ = [("d3d_type", C.c_uint32),
                ("diffuse", C.c_float * 3), ("specular", C.c_float * 3),
                ("ambient", C.c_float * 3), ("position", C.c_float * 3),
                ("direction", C.c_float * 3), ("range", C.c_float),
                ("falloff", C.c_float), ("attenuation", C.c_float * 3),
                ("theta", C.c_float), ("phi", C.c_float)]


class LightRig(C.Structure):
    _fields_ = [("count", C.c_uint32),
                ("lights", LightEntry * 8),
                ("global_ambient", C.c_float * 3),
                ("camera_eye", C.c_float * 3),
                ("view_matrix", Matrix),
                ("shading_mode", C.c_uint32),
                ("enable_specular", C.c_uint32),
                ("sheen_tci", C.c_uint32)]


class EyeNeckSpan(C.Structure):
    _fields_ = [("offset", C.c_size_t), ("length", C.c_uint32)]


class EyeNeckInfo(C.Structure):
    _fields_ = [("kind", C.c_uint32), ("targets", C.c_uint32),
                ("records", C.c_uint32), ("body_offset", C.c_size_t),
                ("parsed_bytes", C.c_size_t)]


class EyeNeckSlot(C.Structure):
    _fields_ = [("slot_index", C.c_uint32), ("label", EyeNeckSpan),
                ("behavior_mode", C.c_uint32), ("max_yaw_rad", C.c_float),
                ("max_pitch_rad", C.c_float), ("interp_ms", C.c_uint32),
                ("reserved", C.c_uint32), ("weight", C.c_float),
                ("param_a", C.c_float), ("param_b", C.c_float),
                ("timers_ms", C.c_uint32 * 4)]


class EyeNeckController(C.Structure):
    _fields_ = [("active", EyeNeckSlot), ("q_start", C.c_float * 4),
                ("q_current", C.c_float * 4), ("blend_elapsed_ms", C.c_uint32),
                ("saccade_timer_ms", C.c_uint32), ("saccade_limit_ms", C.c_uint32),
                ("avert_sign", C.c_float)]


class EyeNeckTremorState(C.Structure):
    _fields_ = [("accum_ms", C.c_uint32), ("sign", C.c_float)]


class SpringNodeState(C.Structure):
    _fields_ = [("initialized", C.c_uint8), ("prev_world_pos", C.c_float * 3),
                ("prev_world_vel", C.c_float * 3), ("offset", C.c_float * 3),
                ("velocity", C.c_float * 3)]

class GamePlayer(C.Structure):
    _fields_=[(n,C.c_float) for n in ("x","z","min_x","max_x","min_z","max_z","speed")]+[(n,C.c_uint32) for n in ("interaction_count","map_selector")]
class GameInput(C.Structure):
    _fields_=[("axis_x",C.c_float),("axis_z",C.c_float),("touching",C.c_uint32)]
class GameInteractionState(C.Structure):
    _fields_=[("interaction_count",C.c_uint32),("start_tick",C.c_uint32),("active",C.c_uint32),("completed",C.c_uint32)]
class GameInteractionInput(C.Structure):
    _fields_=[("tick",C.c_uint32),("new_touch",C.c_uint32),("near_target",C.c_uint32)]
class GameInteractionResult(C.Structure):
    _fields_=[("begin",C.c_uint32),("restore",C.c_uint32),("completed",C.c_uint32)]


class SceneMotionState(C.Structure):
    _fields_=[("scene_type",C.c_uint32),("stage",C.c_uint32),("progress",C.c_uint32),
              ("clip",C.c_uint32),("phase",C.c_uint32),("pointer_mode",C.c_uint32),
              ("outcome_a",C.c_uint32),("outcome_b",C.c_uint32),
              ("metric",C.c_float),("average_motion",C.c_float),
              ("sample_count",C.c_uint32),("last_tick",C.c_uint32),
              ("release_flag",C.c_uint8),("history_committed",C.c_uint8),
              ("transition_pending",C.c_uint8),("completed",C.c_uint8)]


class SceneMotionInput(C.Structure):
    _fields_=[("tick",C.c_uint32),("audio_ready",C.c_uint32),
              ("dx",C.c_int32),("dy",C.c_int32),("wheel",C.c_int32),
              ("left",C.c_uint32),("right",C.c_uint32),("middle",C.c_uint32),
              ("ctrl",C.c_uint32),("hit_index",C.c_int32)]


class SceneMotionEvent(C.Structure):
    _fields_=[("request_clip",C.c_uint32),("request_chain_from",C.c_uint32),
              ("request_chain_to",C.c_uint32),("transition_action",C.c_uint32),
              ("history_commit",C.c_uint32),("completed",C.c_uint32),
              ("metric_ready",C.c_uint32),("metric",C.c_float),
              ("average_motion",C.c_float)]

class SceneActionCommand(C.Structure):
    _fields_=[('kind',C.c_uint32),('target',C.c_uint32)]
class SceneActionPlan(C.Structure):
    _fields_=[('camera_mode',C.c_uint32),('secondary_camera_mode',C.c_uint32),('count',C.c_uint32),('commands',SceneActionCommand*2)]
    def record(self):
        return {'modes':[self.camera_mode,self.secondary_camera_mode],
                'commands':[[c.kind,c.target] for c in self.commands[:self.count]]}


class StoryChapter(C.Structure):
    _fields_=[("script",C.c_int32),("last_frame",C.c_int32),("map",C.c_int32),("stage",C.c_int32),("scene",C.c_uint32),("scene_type",C.c_uint32)]


class StoryStage(C.Structure):
    _fields_=[("flag_a",C.c_uint32),("flag_b",C.c_uint32),("progress",C.c_uint32)]


class StoryState(C.Structure):
    _fields_=[("chapter",C.c_uint32),("map",C.c_uint32),("stage",C.c_uint32),("stages",StoryStage*3),("unlocked",C.c_uint32)]


class StoryOutcomes(C.Structure):
    _fields_=[("a",C.c_int32*3),("b",C.c_int32*3)]


class StoryCommand(C.Structure):
    _fields_=[("kind",C.c_uint32),("value",C.c_uint32)]


class StoryPlan(C.Structure):
    _fields_=[("next",StoryState),("commands",StoryCommand*8),("count",C.c_uint32),("departed",C.c_uint32)]

    def record(self):
        return {'state':[self.next.chapter,self.next.map,self.next.stage,
                         [[self.next.stages[i].flag_a,self.next.stages[i].flag_b,self.next.stages[i].progress] for i in range(3)],
                         self.next.unlocked],
                'commands':[[c.kind,c.value] for c in self.commands[:self.count]],
                'departed':self.departed}


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

class SaveSlotMeta(C.Structure):
    _fields_=[(n,C.c_uint8) for n in ('chapter','scene_type','previous_type','map','stage','selector0','selector1','script_frame')]


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

class XXMeshRenderState(C.Structure):
    _fields_ = [(n,C.c_uint8) for n in ('hidden','blend_mode','point_filter','two_sided','order','transparent_queue','priority','reserved')]

class SceneCharacterState(C.Structure):
    _fields_ = [('activation_count',C.c_uint32),('delay_ms',C.c_uint32)]+[(n,C.c_uint8) for n in ('delay_pending','exit_pending','transition_pending','reserved')]

class SceneCharacterEvent(C.Structure):
    _fields_ = [(n,C.c_uint32) for n in ('configure_animation','request_clip','play_slot','request_transition')]


class XXSkin(C.Structure):
    _fields_ = [('shared_vertices',XXSpan)]+[(n,C.c_uint32) for n in ('node','shared_count','first_bone','bones','vertex_format')]


class XXBone(C.Structure):
    _fields_ = [('name',XXSpan),('matrix_offset',C.c_size_t),('node',C.c_uint32),('index',C.c_uint32)]


class XXWeights(C.Structure):
    _fields_ = [('weights',C.c_float*3),('indices',C.c_uint8*4)]


class SkinBone(C.Structure):
    _fields_=[('index',C.c_uint32),('target',C.c_uint32),('offset',Matrix)]


class SkinPalette(C.Structure):
    _fields_=[('world',Matrix*256)]


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


class Type7Assets(C.Structure):
    _fields_ = [
        ("body_archive", C.c_char * 32),
        ("body_count", C.c_uint8),
        ("body_xx", (C.c_char * 32) * 4),
        ("body_plst", (C.c_char * 32) * 4),
        ("body_xa", (C.c_char * 32) * 4),
        ("head_count", C.c_uint8),
        ("head_heroine", C.c_uint8 * 3),
        ("head_body_index", C.c_uint8 * 3),
        ("head_xx", (C.c_char * 32) * 3),
        ("head_xa", (C.c_char * 32) * 3),
        ("head_eyes", (C.c_char * 32) * 3),
        ("head_neck", (C.c_char * 32) * 3),
        ("char_light_xl", C.c_char * 32),
        ("cam_file", C.c_char * 32),
        ("anchor_primary", C.c_char * 32),
        ("anchor_fallback", C.c_char * 32),
        ("bgm_name", C.c_char * 32),
    ]


class Type7MenuItem(C.Structure):
    _fields_ = [
        ("stem", C.c_char * 16),
        ("radial_pos", C.c_uint8),
        ("selected", C.c_uint8),
        ("action_id", C.c_uint8),
        ("aux", C.c_uint8),
    ]


class Type7Menu(C.Structure):
    _fields_ = [
        ("hub", C.c_uint8),
        ("count", C.c_uint8),
        ("target_heroine", C.c_uint8),
        ("page", C.c_uint8),
        ("items", Type7MenuItem * 7),
    ]


class Type7HeroineMetrics(C.Structure):
    _fields_ = [
        ("vaginal_in_ejac", C.c_uint16),
        ("anal_in_ejac", C.c_uint16),
        ("out_ejac", C.c_uint16),
        ("oral_in_ejac", C.c_uint16),
        ("oral_out_ejac", C.c_uint16),
        ("anal_penetrations", C.c_uint16),
        ("heroine_climaxes", C.c_uint16),
        ("posture_a_used", C.c_uint8),
        ("posture_b_used", C.c_uint8),
        ("caress_used", C.c_uint8),
        ("stripped_flags", C.c_uint8),
        ("swallowed", C.c_uint8),
        ("anal_used", C.c_uint8),
        ("special_event", C.c_uint8),
        ("reserved", C.c_uint8),
    ]


class Type7State(C.Structure):
    _fields_ = [
        ("sub_mode", C.c_uint8),
        ("initial_sub_mode", C.c_uint8),
        ("rig_mode", C.c_uint8),
        ("map_id", C.c_uint8),
        ("heroine_count", C.c_uint8),
        ("slots", C.c_uint8 * 3),
        ("conquered_mask", C.c_uint8),
        ("active_slot", C.c_int8),
        ("primary_heroine", C.c_uint8),
        ("hole", C.c_uint8),
        ("phase", C.c_uint8),
        ("oral_pos", C.c_uint8),
        ("oral_fast", C.c_uint8),
        ("chara_page", C.c_uint8),
        ("fuku_slot_cursor", C.c_uint8),
        ("cam_slot_cursor", C.c_uint8),
        ("gaze_mode", C.c_uint8 * 3),
        ("cam_pivot_mode", C.c_uint8),
        ("cam_target_heroine", C.c_uint8),
        ("vibe_mask", C.c_uint8),
        ("vibe_fast", C.c_uint8),
        ("fuku_state", (C.c_uint8 * 6) * 3),
        ("fade_pending", C.c_uint8),
        ("fade_kind", C.c_uint8),
        ("pending_sub_mode", C.c_uint8),
        ("pending_rig_mode", C.c_uint8),
        ("pending_slot", C.c_int8),
        ("pending_hole", C.c_uint8),
        ("sub_style", C.c_uint8),
        ("cummed_piston", C.c_uint8),
        ("edge_resumed", C.c_uint8),
        ("breath_tier", C.c_uint8),
        ("oral_afterglow_irrumatio", C.c_uint8),
        ("hold_timer_ms", C.c_uint32),
        ("moan_timer_ms", C.c_uint32),
        ("se_cycle_clip", C.c_uint32),
        ("se_fired_in_stroke", C.c_uint8),
        ("idle_anim_speed", C.c_float),
        ("speed", C.c_float),
        ("arousal", C.c_float * 3),
        ("voice_serial", C.c_uint32),
        ("metrics", Type7HeroineMetrics * 3),
    ]


class Type7Plan(C.Structure):
    _fields_ = [
        ("body_count", C.c_uint8),
        ("body_clip", C.c_int32 * 4),
        ("body_next_clip", C.c_int32 * 4),
        ("chain_count", C.c_uint8),
        ("chain_body", C.c_uint8 * 16),
        ("chain_from", C.c_uint16 * 16),
        ("chain_to", C.c_int16 * 16),
        ("loop_count", C.c_uint8),
        ("loop_body", C.c_uint8 * 8),
        ("loop_clip", C.c_uint16 * 8),
        ("loop_limit", C.c_int16 * 8),
        ("reset_cam_preset", C.c_uint8),
        ("update_cam_pivot", C.c_uint8),
        ("start_fade", C.c_uint8),
        ("fade_kind", C.c_uint8),
        ("voice_heroine", C.c_uint8),
        ("voice_stem", C.c_char * 32),
        ("se_name", C.c_char * 32),
    ]


class Type7ExitOutcome(C.Structure):
    _fields_ = [
        ("destination_type", C.c_uint8),
        ("destination_chapter", C.c_uint8),
        ("destination_stage", C.c_uint8),
        ("badge_awarded", C.c_uint8),
        ("badge_heroine", C.c_uint8),
        ("badge_index", C.c_uint8),
        ("promoted_conquest_mask", C.c_uint8),
        ("exit_voice", C.c_char * 32),
    ]


class EditStep(C.Structure):
    _fields_ = [
        ("cat_idx", C.c_int32),
        ("motion_id", C.c_int32),
        ("param1", C.c_int32),
        ("param2", C.c_int32),
    ]


class EditCharaUI(C.Structure):
    _fields_ = [
        ("active_mask", C.c_uint8),
        ("edit_mode", C.c_uint8),
        ("chara_heroine", C.c_uint8),
        ("map_enabled_mask", C.c_uint8),
        ("pers_enabled_mask", C.c_uint8),
        ("preg_enabled_mask", C.c_uint8),
        ("virgin_enabled_mask", C.c_uint8),
        ("pubic_enabled", C.c_uint8),
        ("badges_enabled_mask", C.c_uint16),
        ("badges_locked_mask", C.c_uint16),
    ]


class EditMotionUI(C.Structure):
    _fields_ = [
        ("cand_count", C.c_uint8),
        ("cand_page", C.c_uint8),
        ("cand_page_count", C.c_uint8),
        ("cand_cat_idx", C.c_int32 * 57),
        ("cand_motion_id", C.c_int32 * 57),
        ("p1_kind", C.c_int8),
        ("p2_kind", C.c_int8),
        ("speed_enabled_mask", C.c_uint8),
        ("keypad_enabled", C.c_uint8),
        ("heroine_enabled_mask", C.c_uint8),
        ("hole_enabled_mask", C.c_uint8),
        ("strip_enabled_mask", C.c_uint8),
        ("can_play_or_save", C.c_uint8),
    ]


class EditState(C.Structure):
    _fields_ = [
        ("combo_idx", C.c_int32),
        ("map_idx", C.c_int32),
        ("personality", C.c_int32 * 3),
        ("pregnancy", C.c_int32 * 3),
        ("init_cloth", (C.c_int32 * 6) * 3),
        ("non_virgin", C.c_uint8 * 3),
        ("pubic_hair", C.c_uint8 * 3),
        ("badges", (C.c_uint8 * 9) * 3),
        ("step_count", C.c_int32),
        ("steps", EditStep * 999),
        ("tab", C.c_uint8),
        ("edit_mode", C.c_uint8),
        ("active_mask", C.c_uint8),
        ("chara_heroine", C.c_uint8),
        ("selected_step", C.c_int32),
        ("list_scroll", C.c_int32),
        ("cand_page", C.c_uint8),
        ("keypad_overwrite", C.c_uint8),
        ("cur_cloth", (C.c_int32 * 6) * 3),
        ("cur_acc", (C.c_uint8 * 2) * 3),
        ("hole_occ", (C.c_uint8 * 2) * 3),
        ("vibe_fast", C.c_uint8),
        ("pose_state", C.c_uint8),
        ("last_pos_motion", C.c_int32),
        ("caution_pending", C.c_uint8),
        ("caution_kind", C.c_uint8),
        ("caution_arg1", C.c_int32),
        ("caution_arg2", C.c_int32),
        ("current_filename", C.c_char * 64),
    ]


class EditAssets(C.Structure):
    _fields_ = [
        ("map_id", C.c_uint8),
        ("edit_mode", C.c_uint8),
        ("map_archive", C.c_char * 32),
        ("map_xx", C.c_char * 32),
        ("map_xl", C.c_char * 32),
        ("map_xa", C.c_char * 32),
        ("map_glare", C.c_char * 32),
        ("bgm_name", C.c_char * 32),
        ("body_archive", C.c_char * 32),
        ("body_count", C.c_uint8),
        ("body_xx", (C.c_char * 32) * 4),
        ("body_plst", (C.c_char * 32) * 4),
        ("body_xa", (C.c_char * 32) * 4),
        ("body_oral_xa", C.c_char * 32),
        ("body_oral_xa_multi", (C.c_char * 32) * 4),
        ("head_count", C.c_uint8),
        ("head_heroine", C.c_uint8 * 3),
        ("head_body_index", C.c_uint8 * 3),
        ("head_preg_belly", C.c_uint8 * 3),
        ("head_pubic_tex", C.c_uint8 * 3),
        ("head_xx", (C.c_char * 32) * 3),
        ("head_xa", (C.c_char * 32) * 3),
        ("head_eyes", (C.c_char * 32) * 3),
        ("head_neck", (C.c_char * 32) * 3),
        ("char_light_xl", C.c_char * 32),
        ("cam_file", C.c_char * 32),
        ("oral_cam_file", C.c_char * 32),
        ("anchor_primary", C.c_char * 32),
        ("anchor_fallback", C.c_char * 32),
        ("oral_anchor_primary", C.c_char * 32),
        ("oral_anchor_fallback", C.c_char * 32),
    ]


class EditStepPlan(C.Structure):
    _fields_ = [
        ("finished", C.c_uint8),
        ("immediate_only", C.c_uint8),
        ("use_oral_rig", C.c_uint8),
        ("body_count", C.c_uint8),
        ("body_clip", C.c_int32 * 4),
        ("body_next_clip", C.c_int32 * 4),
        ("chain_count", C.c_uint8),
        ("chain_body", C.c_uint8 * 16),
        ("chain_from", C.c_uint16 * 16),
        ("chain_to", C.c_int16 * 16),
        ("loop_count", C.c_uint8),
        ("loop_body", C.c_uint8 * 8),
        ("loop_clip", C.c_uint16 * 8),
        ("loop_limit", C.c_int16 * 8),
        ("is_looping", C.c_uint8),
        ("loop_target", C.c_uint32),
        ("base_speed", C.c_float),
        ("effective_speed", C.c_float),
        ("cloth_changed", C.c_uint8),
        ("cur_cloth", (C.c_int32 * 6) * 3),
        ("cur_acc", (C.c_uint8 * 2) * 3),
        ("update_cam_pivot", C.c_uint8),
        ("cam_target_heroine", C.c_uint8),
        ("voice_heroine", C.c_uint8),
        ("voice_stem", C.c_char * 32),
        ("se_name", C.c_char * 32),
    ]


class EditPlayer(C.Structure):
    _fields_ = [
        ("cur_step", C.c_int32),
        ("edit_mode", C.c_uint8),
        ("map_id", C.c_uint8),
        ("pose_state", C.c_uint8),
        ("active_heroine", C.c_uint8),
        ("active_slot", C.c_int8),
        ("hole", C.c_uint8),
        ("vibe_mask", C.c_uint8),
        ("vibe_fast", C.c_uint8),
        ("use_oral_rig", C.c_uint8),
        ("afterglow", C.c_uint8),
        ("oral_pos", C.c_uint8),
        ("paused", C.c_uint8),
        ("ff_mode", C.c_uint8),
        ("hud_hidden", C.c_uint8),
        ("finished", C.c_uint8),
        ("in_loop_clip", C.c_uint8),
        ("is_looping", C.c_uint8),
        ("loop_target", C.c_uint32),
        ("loops_done", C.c_uint32),
        ("base_speed", C.c_float),
        ("cur_cloth", (C.c_int32 * 6) * 3),
        ("cur_acc", (C.c_uint8 * 2) * 3),
        ("voice_serial", C.c_uint32),
    ]


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
    sources = [ROOT / "native/resource/dc_pp.c", ROOT / "native/resource/dc_image.c", ROOT / "native/resource/dc_xa.c", ROOT / "native/resource/dc_xx.c", ROOT / "native/resource/dc_script.c", ROOT / "native/resource/dc_xl.c", ROOT / "native/resource/dc_eyeneck.c",
               ROOT / "native/render/dc_mesh.c", ROOT / "native/render/dc_mesh_clip.c", ROOT / "native/render/dc_sprite.c", ROOT / "native/render/dc_sprite_vertices.c",
               ROOT / "native/game/dc_startup.c", ROOT / "native/game/dc_animation.c", ROOT / "native/game/dc_material.c", ROOT / "native/game/dc_pose.c", ROOT / "native/game/dc_scene.c", ROOT / "native/game/dc_model.c", ROOT / "native/game/dc_menu.c", ROOT / "native/game/dc_save.c", ROOT / "native/game/dc_text.c", ROOT / "native/game/dc_skin.c", ROOT / "native/game/dc_camera.c", ROOT / "native/game/dc_gameplay.c", ROOT / "native/game/dc_gamepad.c", ROOT / "native/game/dc_story.c"]
    sources.append(ROOT / "native/game/dc_pc_input.c")
    sources.append(ROOT / "native/game/dc_touch_controls.c")
    sources.append(ROOT / "native/game/dc_pc_touch.c")
    sources.append(ROOT / "native/game/dc_scene_ui.c")
    sources.append(ROOT / "native/game/dc_scene_motion.c")
    sources.append(ROOT / "native/game/dc_config.c")
    sources.append(ROOT / "native/game/dc_flow.c")
    sources.append(ROOT / "native/game/dc_morph.c")
    sources.append(ROOT / "native/game/dc_type7.c")
    sources.append(ROOT / "native/game/dc_edit.c")
    inputs = sources + [ROOT / "native/include/dc_config.h", ROOT / "native/include/dc_flow.h", ROOT / "native/include/dc_morph.h", ROOT / "native/include/dc_type7.h", ROOT / "native/include/dc_edit.h", ROOT / "native/include/dc_pc_input.h", ROOT / "native/include/dc_pp.h", ROOT / "native/include/dc_image.h",
                        ROOT / "native/include/dc_sprite.h", ROOT / "native/include/dc_startup.h",
                        ROOT / "native/include/dc_animation.h", ROOT / "native/include/dc_xa.h", ROOT / "native/include/dc_material.h", ROOT / "native/include/dc_xx.h", ROOT / "native/include/dc_pose.h", ROOT / "native/include/dc_scene.h", ROOT / "native/include/dc_mesh.h", ROOT / "native/include/dc_model.h", ROOT / "native/include/dc_menu.h", ROOT / "native/include/dc_save.h", ROOT / "native/include/dc_script.h", ROOT / "native/include/dc_text.h", ROOT / "native/include/dc_skin.h", ROOT / "native/include/dc_camera.h", ROOT / "native/include/dc_gameplay.h", ROOT / "native/include/dc_xl.h", ROOT / "native/include/dc_eyeneck.h", ROOT / "native/include/dc_gamepad.h", ROOT / "native/include/dc_story.h", ROOT / "native/include/dc_scene_motion.h"]
    digest = hashlib.sha256("\0".join(command).encode())
    inputs.append(ROOT / "native/include/dc_touch_controls.h")
    inputs.append(ROOT / "native/include/dc_pc_touch.h")
    inputs.append(ROOT / "native/include/dc_scene_ui.h")
    inputs.append(ROOT / "native/include/dc_pc_input.h")
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
        result = subprocess.run(command + ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-misleading-indentation",
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
    lib.dc_xl_probe.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(XLInfo)]
    lib.dc_xl_probe.restype = C.c_int
    lib.dc_xl_light_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(XLLight)]
    lib.dc_xl_light_at.restype = C.c_int
    lib.dc_xl_d3d_light_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(XLD3DLight)]
    lib.dc_xl_d3d_light_at.restype = C.c_int
    lib.dc_xl_ambient.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(C.c_float)]
    lib.dc_xl_ambient.restype = C.c_int
    lib.dc_glare_probe.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(GlareInfo)]
    lib.dc_glare_probe.restype = C.c_int
    lib.dc_glare_apply_rgba.argtypes = [C.POINTER(GlareInfo), C.c_void_p, C.c_uint32, C.c_uint32]
    lib.dc_glare_apply_rgba.restype = C.c_int
    lib.dc_eyeneck_probe.argtypes = [C.c_void_p, C.c_size_t, C.POINTER(EyeNeckInfo)]
    lib.dc_eyeneck_probe.restype = C.c_int
    lib.dc_eyeneck_target_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(EyeNeckSpan)]
    lib.dc_eyeneck_target_at.restype = C.c_int
    lib.dc_eyeneck_slot_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(EyeNeckSlot)]
    lib.dc_eyeneck_slot_at.restype = C.c_int
    lib.dc_eyeneck_controller_init.argtypes = [C.POINTER(EyeNeckController)]
    lib.dc_eyeneck_controller_init.restype = None
    lib.dc_eyeneck_controller_set_slot.argtypes = [C.POINTER(EyeNeckController), C.POINTER(EyeNeckSlot)]
    lib.dc_eyeneck_controller_set_slot.restype = None
    lib.dc_eyeneck_controller_step.argtypes = [C.POINTER(EyeNeckController), C.POINTER(Matrix),
                                               C.POINTER(C.c_float), C.c_float, C.c_uint32, C.POINTER(Matrix)]
    lib.dc_eyeneck_controller_step.restype = C.c_int
    lib.dc_eyeneck_tremor_init.argtypes = [C.POINTER(EyeNeckTremorState)]
    lib.dc_eyeneck_tremor_init.restype = None
    lib.dc_eyeneck_tremor_step.argtypes = [C.POINTER(EyeNeckTremorState), C.c_uint32, C.c_float,
                                           C.c_uint32, C.POINTER(Matrix)]
    lib.dc_eyeneck_tremor_step.restype = C.c_int
    lib.dc_spring_node_init.argtypes = [C.POINTER(SpringNodeState)]
    lib.dc_spring_node_init.restype = None
    lib.dc_spring_breast_step.argtypes = [C.POINTER(SpringNodeState), C.POINTER(Matrix),
                                          C.c_uint32, C.c_uint32, C.c_uint32, C.POINTER(Matrix)]
    lib.dc_spring_breast_step.restype = C.c_int
    lib.dc_spring_hair_step.argtypes = [C.POINTER(SpringNodeState), C.POINTER(Matrix),
                                        C.c_uint32, C.POINTER(Matrix)]
    lib.dc_spring_hair_step.restype = C.c_int
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
    lib.dc_animation_set_chain.argtypes=[C.POINTER(AnimationTiming),C.c_size_t,C.c_uint32,C.c_int32]
    lib.dc_animation_set_loop.argtypes=[C.POINTER(AnimationClip),C.POINTER(AnimationTiming),C.c_size_t,C.c_uint32,C.c_int32]
    lib.dc_scene_character_select.argtypes=[C.POINTER(SceneCharacterState),C.c_uint32,C.c_uint32,C.c_uint32,C.POINTER(SceneCharacterEvent)]
    lib.dc_scene_character_step.argtypes=[C.POINTER(SceneCharacterState),C.c_uint32,C.c_uint32,C.POINTER(SceneCharacterEvent)]
    lib.dc_scene_effect_name.argtypes=[C.c_uint32,C.c_void_p,C.c_size_t]
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
    lib.dc_xa_event_track_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(XAEventTrack)]
    lib.dc_xa_event_track_at.restype = C.c_int
    lib.dc_xa_event_key_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32, C.POINTER(XAEventKey)]
    lib.dc_xa_event_key_at.restype = C.c_int
    lib.dc_xx_load_mesh_vertices.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t]
    lib.dc_xx_load_mesh_vertices.restype = C.c_int
    lib.dc_xx_load_mesh_indices.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(C.c_uint16),C.c_size_t]
    lib.dc_xx_load_mesh_indices.restype = C.c_int
    lib.dc_mesh_project.argtypes = [C.POINTER(MeshVertex),C.c_size_t,C.POINTER(C.c_uint16),C.c_size_t,C.POINTER(Matrix),C.POINTER(Viewport),C.c_uint32,C.POINTER(SpriteVertex),C.c_size_t]
    lib.dc_mesh_project.restype = C.c_int
    lib.dc_model_open.argtypes = [C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_void_p)]
    lib.dc_model_open.restype = C.c_int
    lib.dc_model_open_static.argtypes = [C.c_void_p,C.c_size_t,C.POINTER(C.c_void_p)]
    lib.dc_model_open_static.restype = C.c_int
    lib.dc_model_vertex_space.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(C.c_uint32)]
    lib.dc_model_vertex_space.restype=C.c_int
    lib.dc_model_load_vertices.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t]
    lib.dc_model_load_vertices.restype=C.c_int
    lib.dc_model_mesh_visible.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(C.c_uint32)]
    lib.dc_model_mesh_visible.restype=C.c_int
    lib.dc_model_node_visible.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(C.c_uint32)]
    lib.dc_model_node_visible.restype=C.c_int
    lib.dc_model_hide_node.argtypes=[C.c_void_p,C.c_uint32,C.c_uint32]
    lib.dc_model_hide_node.restype=C.c_int
    lib.dc_model_set_node_extra.argtypes=[C.c_void_p,C.c_uint32,C.c_uint32,C.POINTER(Matrix)]
    lib.dc_model_set_node_extra.restype=C.c_int
    lib.dc_model_refresh_pose.argtypes=[C.c_void_p,C.POINTER(Matrix)]
    lib.dc_model_refresh_pose.restype=C.c_int
    lib.dc_model_scrub_clip.argtypes=[C.c_void_p,C.c_uint32,C.c_float,C.c_float,C.POINTER(Matrix)]
    lib.dc_model_scrub_clip.restype=C.c_int
    lib.dc_matrix_inverse_affine.argtypes=[C.POINTER(Matrix),C.POINTER(Matrix)]
    lib.dc_matrix_inverse_affine.restype=C.c_int
    lib.dc_model_get_animation.argtypes=[C.c_void_p,C.POINTER(AnimationState)]
    lib.dc_model_get_animation.restype=C.c_int
    lib.dc_model_close.argtypes = [C.c_void_p]
    lib.dc_model_close.restype = None
    lib.dc_model_request.argtypes = [C.c_void_p,C.c_uint32,C.c_uint32]
    lib.dc_model_request.restype = C.c_int
    lib.dc_model_set_chain.argtypes=[C.c_void_p,C.c_uint32,C.c_int32]
    lib.dc_model_set_loop.argtypes=[C.c_void_p,C.c_uint32,C.c_int32]
    lib.dc_model_query.argtypes = [C.c_void_p,C.POINTER(C.c_uint32),C.POINTER(C.c_uint32)]
    lib.dc_model_query.restype = C.c_int
    lib.dc_model_tick.argtypes = [C.c_void_p,C.c_uint32,C.c_uint32,C.POINTER(Matrix)]
    lib.dc_model_tick.restype = C.c_int
    for name,record in (("get_info",XXInfo),("material",MaterialValue),("global",Matrix),("mesh",XXSubmesh)):
        function=getattr(lib,"dc_model_"+name)
        function.argtypes=[C.c_void_p]+([] if name=="get_info" else [C.c_uint32])+[C.POINTER(record)]
        function.restype=C.c_int
    lib.dc_model_project.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(Matrix),C.POINTER(Viewport),C.c_uint32,C.POINTER(SpriteVertex),C.c_size_t]
    lib.dc_model_project_clipped.argtypes = lib.dc_model_project.argtypes+[C.POINTER(C.c_size_t)]
    lib.dc_model_project_clipped.restype=C.c_int
    lib.dc_model_project_vertices_clipped.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t,
        C.POINTER(Matrix),C.POINTER(Viewport),C.c_uint32,C.POINTER(SpriteVertex),C.c_size_t,C.POINTER(C.c_size_t)]
    lib.dc_model_project_vertices_clipped.restype=C.c_int
    lib.dc_model_project_lit_clipped.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(Matrix),C.POINTER(Viewport),
        C.POINTER(MaterialValue),C.POINTER(LightRig),C.POINTER(SpriteVertex),C.POINTER(SpriteVertex),
        C.POINTER(SpriteVertex),C.c_size_t,C.POINTER(C.c_size_t),C.POINTER(C.c_uint32)]
    lib.dc_model_project_lit_clipped.restype = C.c_int
    lib.dc_model_project_vertices_lit_clipped.argtypes = [C.c_void_p,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t,
        C.POINTER(Matrix),C.POINTER(Viewport),C.POINTER(MaterialValue),C.POINTER(LightRig),
        C.POINTER(SpriteVertex),C.POINTER(SpriteVertex),C.POINTER(SpriteVertex),C.c_size_t,
        C.POINTER(C.c_size_t),C.POINTER(C.c_uint32)]
    lib.dc_model_project_vertices_lit_clipped.restype = C.c_int
    lib.dc_model_project.restype = C.c_int
    lib.dc_model_load_source_vertices.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t]
    lib.dc_model_load_source_vertices.restype=C.c_int
    lib.dc_script_find.argtypes = [C.c_void_p,C.c_size_t,C.c_size_t,C.c_uint32,C.POINTER(ScriptRecord)]
    lib.dc_script_find.restype = C.c_int
    lib.dc_game_state_init.argtypes = [C.c_void_p,C.c_size_t]
    lib.dc_game_state_init.restype = C.c_int
    lib.dc_save_transform.argtypes = [C.c_void_p,C.c_size_t]
    lib.dc_save_transform.restype = C.c_int
    lib.dc_save_slot_encode.argtypes=[C.c_void_p,C.c_size_t,C.POINTER(SaveSlotMeta),C.c_void_p,C.c_size_t]
    lib.dc_save_slot_decode.argtypes=[C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(SaveSlotMeta)]
    lib.dc_save_slot_name.argtypes=[C.c_uint32,C.c_void_p,C.c_size_t]
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
    lib.dc_mesh_clip_project.argtypes=[C.POINTER(MeshVertex),C.c_size_t,C.POINTER(C.c_uint16),C.c_size_t,C.POINTER(Matrix),C.POINTER(Viewport),C.c_uint32,C.POINTER(SpriteVertex),C.c_size_t,C.POINTER(C.c_size_t)]
    lib.dc_mesh_clip_project.restype=C.c_int
    lib.dc_mesh_clip_project_lit.argtypes=[C.POINTER(MeshVertex),C.c_size_t,C.POINTER(C.c_uint16),C.c_size_t,
        C.POINTER(Matrix),C.POINTER(Matrix),C.POINTER(Viewport),C.POINTER(MaterialValue),C.POINTER(LightRig),
        C.POINTER(SpriteVertex),C.POINTER(SpriteVertex),C.POINTER(SpriteVertex),C.c_size_t,
        C.POINTER(C.c_size_t),C.POINTER(C.c_uint32)]
    lib.dc_mesh_clip_project_lit.restype=C.c_int
    lib.dc_camera_build.argtypes = [C.POINTER(CameraOrbit), C.POINTER(CameraLens), C.POINTER(CameraMatrices)]
    lib.dc_camera_build.restype = C.c_int
    lib.dc_camera_read_preset.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(CameraOrbit)]
    lib.dc_camera_read_preset.restype = C.c_int
    lib.dc_camera_scene_resource.argtypes = [C.c_uint32,C.c_uint32,C.c_uint32,C.c_void_p,C.c_size_t]
    lib.dc_camera_retarget.argtypes = [C.POINTER(CameraOrbit),C.POINTER(Matrix),C.c_uint32,C.POINTER(CameraOrbit)]
    lib.dc_camera_retarget.restype = C.c_int
    lib.dc_camera_scene_node.argtypes=[C.c_uint32,C.c_uint32,C.c_void_p,C.c_size_t]
    lib.dc_camera_look_at.argtypes=[C.POINTER(Matrix),C.POINTER(Matrix),C.POINTER(Matrix)]
    lib.dc_camera_secondary_viewport.argtypes=[C.POINTER(Viewport),C.POINTER(Viewport)]
    lib.dc_camera_secondary_pointer.argtypes=[C.POINTER(CameraOrbit),C.POINTER(CameraPointerLimits),C.POINTER(CameraPointerInput),C.POINTER(CameraOrbit)]
    lib.dc_camera_primary_pointer.argtypes=[C.POINTER(CameraOrbit),C.POINTER(C.c_float),C.POINTER(CameraPointerLimits),C.POINTER(CameraPointerInput),C.POINTER(CameraOrbit)]
    lib.dc_camera_primary_pointer.restype=C.c_int
    lib.dc_scene_action_build.argtypes = [C.c_uint32]*5+[C.POINTER(SceneActionPlan)]
    lib.dc_scene_action_build.restype = C.c_int
    lib.dc_scene_motion_init.argtypes=[C.POINTER(SceneMotionState),C.c_uint32,C.c_uint32,C.c_uint32,C.c_uint32]
    lib.dc_scene_motion_init.restype=C.c_int
    lib.dc_scene_motion_context.argtypes=[C.POINTER(SceneMotionState),C.c_uint32,C.POINTER(SceneMotionEvent)]
    lib.dc_scene_motion_context.restype=C.c_int
    lib.dc_scene_motion_step.argtypes=[C.POINTER(SceneMotionState),C.POINTER(SceneMotionInput),C.POINTER(SceneMotionState),C.POINTER(SceneMotionEvent)]
    lib.dc_scene_motion_step.restype=C.c_int
    lib.dc_game_player_step.argtypes=[C.POINTER(GamePlayer),C.POINTER(GameInput),C.c_float,C.POINTER(GamePlayer)]
    lib.dc_game_player_step.restype=C.c_int
    lib.dc_game_player_save.argtypes=[C.POINTER(GamePlayer),C.c_void_p,C.c_size_t]
    lib.dc_game_player_save.restype=C.c_int
    lib.dc_game_player_load.argtypes=[C.c_void_p,C.c_size_t,C.POINTER(GamePlayer)]
    lib.dc_game_player_load.restype=C.c_int
    lib.dc_game_next_map_selector.argtypes=[C.c_uint32,C.POINTER(C.c_uint32),C.POINTER(C.c_uint32)]
    lib.dc_game_next_map_selector.restype=C.c_int
    lib.dc_game_story_map_selector.argtypes=[C.c_uint32,C.POINTER(C.c_uint32)]
    lib.dc_game_story_map_selector.restype=C.c_int
    lib.dc_game_menu_profile.argtypes=[C.POINTER(MenuButton),C.c_size_t]
    lib.dc_game_menu_profile.restype=C.c_int
    lib.dc_game_interaction_step.argtypes=[C.POINTER(GameInteractionState),C.POINTER(GameInteractionInput),C.POINTER(GameInteractionState),C.POINTER(GameInteractionResult)]
    lib.dc_game_interaction_step.restype=C.c_int
    lib.dc_story_chapter_profile.argtypes=[C.c_uint32,C.POINTER(StoryChapter)]
    lib.dc_story_chapter_profile.restype=C.c_int
    lib.dc_story_advance.argtypes=[C.POINTER(StoryState),C.POINTER(StoryOutcomes),C.POINTER(StoryPlan)]
    lib.dc_story_advance.restype=C.c_int
    lib.dc_story_menu_action.argtypes=[C.POINTER(StoryState),C.c_uint32,C.POINTER(StoryPlan)]
    lib.dc_story_menu_action.restype=C.c_int
    lib.dc_story_script_finish.argtypes=[C.POINTER(StoryState),C.POINTER(StoryPlan)]
    lib.dc_story_script_finish.restype=C.c_int
    lib.dc_story_save.argtypes=[C.POINTER(StoryState),C.c_void_p,C.c_size_t]
    lib.dc_story_save.restype=C.c_int
    lib.dc_story_load.argtypes=[C.c_void_p,C.c_size_t,C.POINTER(StoryState)]
    lib.dc_story_load.restype=C.c_int
    lib.dc_xa_pose_track_at.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(XAPoseTrack)]
    lib.dc_xa_pose_track_at.restype = C.c_int
    lib.dc_xa_load_pose_keys.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(PoseKey), C.c_size_t]
    lib.dc_xa_load_pose_keys.restype = C.c_int
    lib.dc_xa_morph_index_set_at.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(XAMorphIndexSet)]
    lib.dc_xa_morph_index_set_at.restype=C.c_int
    lib.dc_xa_morph_vector_set_at.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(XAMorphVectorSet)]
    lib.dc_xa_morph_vector_set_at.restype=C.c_int
    lib.dc_xa_load_morph_vector_sets.argtypes=[C.c_void_p,C.c_size_t,C.POINTER(XAMorphVectorSet),C.c_size_t]
    lib.dc_xa_load_morph_vector_sets.restype=C.c_int
    lib.dc_xa_morph_track_at.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(XAMorphTrack)]
    lib.dc_xa_morph_track_at.restype=C.c_int
    lib.dc_xa_morph_key_at.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32,C.POINTER(XAMorphKey)]
    lib.dc_xa_morph_key_at.restype=C.c_int
    lib.dc_xa_load_morph_indices.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32),C.c_size_t]
    lib.dc_xa_load_morph_indices.restype=C.c_int
    lib.dc_xa_load_morph_vectors.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_float),C.c_size_t]
    lib.dc_xa_load_morph_vectors.restype=C.c_int
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
    lib.dc_xx_mesh_render_state_at.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(XXMeshRenderState)]
    for method, structure in (("node", XXNode), ("submesh", XXSubmesh), ("material", XXMaterial), ("texture", XXTexture),('skin',XXSkin),('bone',XXBone)):
        function = getattr(lib, "dc_xx_" + method + "_at")
        function.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(structure)]
        function.restype = C.c_int
    lib.dc_xx_bone_matrix.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(Matrix)]
    lib.dc_xx_bone_matrix.restype=C.c_int
    lib.dc_xx_bind_bones.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(C.c_uint32),C.c_size_t]
    lib.dc_xx_bind_bones.restype=C.c_int
    lib.dc_xx_load_mesh_weights.argtypes=[C.c_void_p,C.c_uint32,C.POINTER(XXWeights),C.c_size_t]
    lib.dc_xx_load_mesh_weights.restype=C.c_int
    lib.dc_skin_palette_init.argtypes=[C.POINTER(SkinPalette)]
    lib.dc_skin_palette_init.restype=C.c_int
    lib.dc_skin_palette_update.argtypes=[C.POINTER(SkinPalette),C.POINTER(SkinBone),C.c_size_t,C.POINTER(Matrix),C.c_size_t]
    lib.dc_skin_palette_update.restype=C.c_int
    lib.dc_skin_apply.argtypes=[C.POINTER(SkinPalette),C.POINTER(MeshVertex),C.POINTER(XXWeights),C.c_size_t,C.c_uint32,C.POINTER(MeshVertex),C.c_size_t]
    lib.dc_skin_apply.restype=C.c_int
    lib.dc_xx_find_material_encoded.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_uint32)]
    lib.dc_xx_find_material_encoded.restype = C.c_int
    lib.dc_xx_find_node_encoded.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_uint32)]
    lib.dc_xx_find_node_encoded.restype = C.c_int
    lib.dc_xx_morph_mesh.argtypes = [C.c_void_p,C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    lib.dc_xx_morph_mesh.restype = C.c_int
    lib.dc_morph_open.argtypes = [C.c_void_p,C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_void_p)]
    lib.dc_morph_open.restype = C.c_int
    lib.dc_morph_close.argtypes = [C.c_void_p]
    lib.dc_morph_close.restype = None
    lib.dc_morph_get_info.argtypes = [C.c_void_p,C.c_void_p]
    lib.dc_morph_get_info.restype = C.c_int
    lib.dc_morph_apply.argtypes = [C.c_void_p,C.c_float,C.c_void_p,C.c_size_t]
    lib.dc_morph_apply.restype = C.c_int
    lib.dc_xx_node_matrix.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(Matrix)]
    lib.dc_xx_node_matrix.restype = C.c_int
    lib.dc_xx_material_baseline.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(MaterialValue)]
    lib.dc_xx_material_baseline.restype = C.c_int
    lib.dc_xx_material_stage_tci.argtypes = [C.c_void_p, C.c_uint32, C.c_uint32,
                                             C.POINTER(C.c_uint8), C.POINTER(C.c_uint8)]
    lib.dc_xx_material_stage_tci.restype = C.c_int
    lib.dc_xx_image_probe.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(ImageInfo)]
    lib.dc_xx_image_probe.restype = C.c_int
    lib.dc_xx_image_decode.argtypes = [C.c_void_p, C.c_uint32, C.c_void_p, C.c_size_t, C.POINTER(ImageInfo)]
    lib.dc_xx_image_decode.restype = C.c_int
    lib.dc_type7_heroine_prefix.argtypes = [C.c_uint8]
    lib.dc_type7_heroine_prefix.restype = C.c_char
    for fn in ("dc_type7_clip_2p_sex", "dc_type7_clip_2p_oral", "dc_type7_clip_3p_sex",
               "dc_type7_clip_3p_vibe", "dc_type7_clip_3p_oral", "dc_type7_clip_4p_sex",
               "dc_type7_clip_4p_switch", "dc_type7_clip_4p_oral"):
        getattr(lib, fn).argtypes = [C.c_uint32, C.c_uint32]
        getattr(lib, fn).restype = C.c_int32
    lib.dc_type7_init.argtypes = [C.POINTER(Type7State), C.c_uint8, C.c_uint8,
                                  C.c_uint8, C.c_uint8, C.c_uint8, C.c_uint8, C.POINTER(Type7Plan)]
    lib.dc_type7_init.restype = C.c_int
    lib.dc_type7_resolve_assets.argtypes = [C.POINTER(Type7State), C.POINTER(Type7Assets)]
    lib.dc_type7_resolve_assets.restype = C.c_int
    lib.dc_type7_observe_clip.argtypes = [C.POINTER(Type7State), C.c_uint32]
    lib.dc_type7_observe_clip.restype = C.c_int
    lib.dc_type7_tick.argtypes = [C.POINTER(Type7State), C.c_uint32, C.c_uint32, C.c_float, C.POINTER(Type7Plan)]
    lib.dc_type7_tick.restype = C.c_int
    lib.dc_type7_adjust_speed.argtypes = [C.POINTER(Type7State), C.c_float]
    lib.dc_type7_adjust_speed.restype = C.c_int
    lib.dc_type7_build_menu.argtypes = [C.POINTER(Type7State), C.c_uint8, C.POINTER(Type7Menu)]
    lib.dc_type7_build_menu.restype = C.c_int
    lib.dc_type7_right_click_menu.argtypes = [C.POINTER(Type7State), C.c_uint8, C.POINTER(C.c_uint8)]
    lib.dc_type7_right_click_menu.restype = C.c_int
    lib.dc_type7_select_menu_item.argtypes = [C.POINTER(Type7State), C.c_uint8, C.c_uint8, C.POINTER(Type7Plan)]
    lib.dc_type7_select_menu_item.restype = C.c_int
    lib.dc_type7_complete_fade.argtypes = [C.POINTER(Type7State), C.POINTER(Type7Plan)]
    lib.dc_type7_complete_fade.restype = C.c_int
    lib.dc_type7_voice_stem.argtypes = [C.POINTER(Type7State), C.POINTER(C.c_uint8), C.c_char_p]
    lib.dc_type7_voice_stem.restype = C.c_int
    lib.dc_type7_commit_exit.argtypes = [C.POINTER(Type7State), C.c_void_p, C.POINTER(Type7ExitOutcome)]
    lib.dc_type7_commit_exit.restype = C.c_int
    lib.dc_edit_heroine_prefix.argtypes = [C.c_uint8]
    lib.dc_edit_heroine_prefix.restype = C.c_char
    lib.dc_edit_map_id_from_index.argtypes = [C.c_int32]
    lib.dc_edit_map_id_from_index.restype = C.c_uint8
    lib.dc_edit_map_index_from_id.argtypes = [C.c_uint8]
    lib.dc_edit_map_index_from_id.restype = C.c_int32
    lib.dc_edit_motion_sprite_name.argtypes = [C.c_int32, C.c_uint8, C.c_char_p]
    lib.dc_edit_motion_sprite_name.restype = C.c_int
    lib.dc_edit_motion_param_kinds.argtypes = [C.c_int32, C.POINTER(C.c_int8), C.POINTER(C.c_int8)]
    lib.dc_edit_motion_param_kinds.restype = C.c_int
    lib.dc_edit_catalog_count.argtypes = [C.c_uint8]
    lib.dc_edit_catalog_count.restype = C.c_uint8
    lib.dc_edit_catalog_motion.argtypes = [C.c_uint8, C.c_int32]
    lib.dc_edit_catalog_motion.restype = C.c_int32
    lib.dc_edit_catalog_index_of.argtypes = [C.c_uint8, C.c_int32]
    lib.dc_edit_catalog_index_of.restype = C.c_int32
    lib.dc_edit_format_autoname.argtypes = [C.c_int32, C.c_int32, C.c_uint32, C.c_char_p]
    lib.dc_edit_format_autoname.restype = C.c_int
    lib.dc_edit_init.argtypes = [C.POINTER(EditState)]
    lib.dc_edit_init.restype = C.c_int
    lib.dc_edit_serialized_size.argtypes = [C.POINTER(EditState)]
    lib.dc_edit_serialized_size.restype = C.c_size_t
    lib.dc_edit_serialize.argtypes = [C.POINTER(EditState), C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]
    lib.dc_edit_serialize.restype = C.c_int
    lib.dc_edit_deserialize.argtypes = [C.POINTER(EditState), C.c_void_p, C.c_size_t, C.c_char_p]
    lib.dc_edit_deserialize.restype = C.c_int
    lib.dc_edit_build_chara_ui.argtypes = [C.POINTER(EditState), C.POINTER(EditCharaUI)]
    lib.dc_edit_build_chara_ui.restype = C.c_int
    lib.dc_edit_select_chara_heroine.argtypes = [C.POINTER(EditState), C.c_uint8]
    lib.dc_edit_select_chara_heroine.restype = C.c_int
    lib.dc_edit_set_combo.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_set_combo.restype = C.c_int
    lib.dc_edit_set_map.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_set_map.restype = C.c_int
    lib.dc_edit_set_personality.argtypes = [C.POINTER(EditState), C.c_uint8, C.c_int32]
    lib.dc_edit_set_personality.restype = C.c_int
    lib.dc_edit_set_pregnancy.argtypes = [C.POINTER(EditState), C.c_uint8, C.c_int32]
    lib.dc_edit_set_pregnancy.restype = C.c_int
    lib.dc_edit_set_virgin.argtypes = [C.POINTER(EditState), C.c_uint8, C.c_uint8]
    lib.dc_edit_set_virgin.restype = C.c_int
    lib.dc_edit_set_pubic_hair.argtypes = [C.POINTER(EditState), C.c_uint8, C.c_uint8]
    lib.dc_edit_set_pubic_hair.restype = C.c_int
    lib.dc_edit_toggle_badge.argtypes = [C.POINTER(EditState), C.c_uint8, C.c_uint8]
    lib.dc_edit_toggle_badge.restype = C.c_int
    lib.dc_edit_resolve_caution.argtypes = [C.POINTER(EditState), C.c_uint8]
    lib.dc_edit_resolve_caution.restype = C.c_int
    lib.dc_edit_replay_state.argtypes = [C.POINTER(EditState)]
    lib.dc_edit_replay_state.restype = C.c_int
    lib.dc_edit_build_motion_ui.argtypes = [C.POINTER(EditState), C.POINTER(EditMotionUI)]
    lib.dc_edit_build_motion_ui.restype = C.c_int
    lib.dc_edit_set_cand_page.argtypes = [C.POINTER(EditState), C.c_uint8]
    lib.dc_edit_set_cand_page.restype = C.c_int
    lib.dc_edit_append_candidate.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_append_candidate.restype = C.c_int
    lib.dc_edit_pop_last_step.argtypes = [C.POINTER(EditState)]
    lib.dc_edit_pop_last_step.restype = C.c_int
    lib.dc_edit_select_step.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_select_step.restype = C.c_int
    lib.dc_edit_scroll_list.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_scroll_list.restype = C.c_int
    lib.dc_edit_set_speed_param.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_set_speed_param.restype = C.c_int
    lib.dc_edit_keypad_press.argtypes = [C.POINTER(EditState), C.c_int32]
    lib.dc_edit_keypad_press.restype = C.c_int
    lib.dc_edit_set_heroine_param.argtypes = [C.POINTER(EditState), C.c_uint8]
    lib.dc_edit_set_heroine_param.restype = C.c_int
    lib.dc_edit_set_hole_param.argtypes = [C.POINTER(EditState), C.c_uint8]
    lib.dc_edit_set_hole_param.restype = C.c_int
    lib.dc_edit_set_strip_param.argtypes = [C.POINTER(EditState), C.c_uint8]
    lib.dc_edit_set_strip_param.restype = C.c_int
    lib.dc_edit_resolve_assets.argtypes = [C.POINTER(EditState), C.POINTER(EditAssets)]
    lib.dc_edit_resolve_assets.restype = C.c_int
    lib.dc_edit_ff_multiplier.argtypes = [C.c_uint8]
    lib.dc_edit_ff_multiplier.restype = C.c_float
    lib.dc_edit_player_init.argtypes = [C.POINTER(EditPlayer), C.POINTER(EditState), C.POINTER(EditStepPlan)]
    lib.dc_edit_player_init.restype = C.c_int
    lib.dc_edit_player_on_clip_end.argtypes = [C.POINTER(EditPlayer), C.POINTER(EditState), C.POINTER(EditStepPlan), C.POINTER(C.c_uint8)]
    lib.dc_edit_player_on_clip_end.restype = C.c_int
    lib.dc_edit_player_skip_step.argtypes = [C.POINTER(EditPlayer), C.POINTER(EditState), C.POINTER(EditStepPlan)]
    lib.dc_edit_player_skip_step.restype = C.c_int
    lib.dc_edit_player_toggle_pause.argtypes = [C.POINTER(EditPlayer)]
    lib.dc_edit_player_toggle_pause.restype = C.c_int
    lib.dc_edit_player_set_ff.argtypes = [C.POINTER(EditPlayer), C.c_uint8]
    lib.dc_edit_player_set_ff.restype = C.c_int
    lib.dc_edit_player_cycle_ff.argtypes = [C.POINTER(EditPlayer)]
    lib.dc_edit_player_cycle_ff.restype = C.c_int
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
        structure = {"node": XXNode, "submesh": XXSubmesh, "material": XXMaterial, "texture": XXTexture,'skin':XXSkin,'bone':XXBone}[kind]
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
