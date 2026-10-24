import ctypes as C
import struct
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import library, XAInfo, AnimationClip, AnimationTiming, AnimationState, AnimationTickResult, XAEventTrack, XAEventKey, XAMorphIndexSet, XAMorphVectorSet, XAMorphTrack, XAMorphKey
from xa_cases import fixture, clip_table, numeric_reference, looping_fixture


class NativeXATests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = library()

    def buffers(self, count=512):
        return (AnimationClip * count)(), (AnimationTiming * count)()

    def test_recorded_original_clip_loader_output(self):
        reference = json.loads((ROOT / "tests/fixtures/xa-clips-original-vectors.json").read_text())
        data, _ = fixture(all_sections=False)
        clips, timing = self.buffers()
        self.assertEqual(self.lib.dc_xa_load_clips(data, len(data), clips, timing, 512), 0)
        self.assertEqual(reference["records"], 512)
        self.assertEqual(hashlib.sha256(bytes(clips) + bytes(timing)).hexdigest(), reference["output_sha256"])

    def test_all_sections_and_exact_serialized_boundaries(self):
        data, offset = fixture()
        info = XAInfo()
        self.assertEqual(self.lib.dc_xa_probe(data, len(data), C.byref(info)), 0)
        self.assertEqual(info.record(), {"material_tracks": 1, "event_tracks": 1,
            "morph_index_sets": 1, "morph_vector_sets": 1, "morph_tracks": 1,
            "bone_tracks": 1, "has_clip_table": 1, "clip_count": 512,
            "clip_table_offset": offset, "parsed_bytes": len(data)})

    def test_morph_views_preserve_encoded_spans_and_key_headers(self):
        data, _ = fixture()
        index, vector, track, key = XAMorphIndexSet(), XAMorphVectorSet(), XAMorphTrack(), XAMorphKey()
        self.assertEqual(self.lib.dc_xa_morph_index_set_at(data,len(data),0,C.byref(index)),0)
        self.assertEqual((index.count,index.selector,index.data_length), (2,1,9))
        self.assertEqual(self.lib.dc_xa_morph_vector_set_at(data,len(data),0,C.byref(vector)),0)
        self.assertEqual((vector.count, vector.data_length),(2,8))
        self.assertEqual(self.lib.dc_xa_morph_track_at(data,len(data),0,C.byref(track)),0)
        self.assertEqual((track.name_length,track.target_length,track.key_count),(6,9,1))
        self.assertEqual(self.lib.dc_xa_morph_key_at(data,len(data),0,0,C.byref(key)),0)
        self.assertEqual((bytes(key.raw),key.value_length),(bytes(range(6)),8))

    def test_event_views_preserve_serialized_fields_and_keys(self):
        data, _ = fixture()
        track, key = XAEventTrack(), XAEventKey()
        self.assertEqual(self.lib.dc_xa_event_track_at(data, len(data), 0, C.byref(track)), 0)
        self.assertEqual((track.type, track.name_length, track.parameter, track.key_count,
                          track.flag_a, track.flag_b, track.flag_c, track.flag_d,
                          track.tail_flag, track.tail_value),
                         (7, 6, 0x05040302, 2, 0, 1, 6, 7, 0, 0x04030201))
        self.assertEqual(self.lib.dc_xa_event_key_at(data, len(data), 0, 0, C.byref(key)), 0)
        self.assertEqual((key.frame, key.value), (0x03020100, 4))
        self.assertEqual(self.lib.dc_xa_event_key_at(data, len(data), 0, 1, C.byref(key)), 0)
        self.assertEqual((key.frame, key.value), (0x08070605, 9))

    def test_event_views_reject_absent_tracks_truncation_and_alias(self):
        data, _ = fixture(all_sections=False)
        track = XAEventTrack()
        self.assertEqual(self.lib.dc_xa_event_track_at(data, len(data), 0, C.byref(track)), 6)
        full, _ = fixture()
        source = C.create_string_buffer(full)
        before = bytes(track)
        for size in range(len(full)):
            self.assertEqual(self.lib.dc_xa_event_track_at(source, size, 0, C.byref(track)), 3)
            self.assertEqual(bytes(track), before)
        self.assertEqual(self.lib.dc_xa_event_track_at(source, len(full), 0,
            C.cast(source, C.POINTER(XAEventTrack))), 1)

    def test_morph_views_reject_truncation_and_overlap(self):
        data, _ = fixture(); source=C.create_string_buffer(data); out=XAMorphTrack();before=bytes(out)
        for size in range(len(data)):
            self.assertIn(self.lib.dc_xa_morph_track_at(source,size,0,C.byref(out)),(3,6),size)
            self.assertEqual(bytes(out),before,size)
        self.assertEqual(self.lib.dc_xa_morph_track_at(source,len(data),0,C.cast(source,C.POINTER(XAMorphTrack))),1)

    def test_morph_arrays_copy_raw_indices_and_six_float_vectors(self):
        data, _ = fixture()
        indices=(C.c_uint32*2)();vectors=(C.c_float*12)()
        self.assertEqual(self.lib.dc_xa_load_morph_indices(data,len(data),0,indices,2),0)
        self.assertEqual(list(indices),[0x03020100,0x07060504])
        self.assertEqual(self.lib.dc_xa_load_morph_vectors(data,len(data),0,vectors,2),0)
        self.assertEqual(bytes(vectors)[:24], bytes(range(24)))
        self.assertEqual(self.lib.dc_xa_load_morph_indices(data,len(data),0,indices,1),4)
        self.assertEqual(self.lib.dc_xa_load_morph_vectors(data,len(data),0,vectors,1),4)

    def test_morph_vector_table_loads_views_atomically(self):
        data, _ = fixture()
        table=(XAMorphVectorSet*1)()
        self.assertEqual(self.lib.dc_xa_load_morph_vector_sets(data,len(data),table,1),0)
        self.assertEqual((table[0].count,table[0].data_length),(2,8))
        self.assertEqual(self.lib.dc_xa_load_morph_vector_sets(data,len(data),table,0),4)

    def test_all_slots_float_bits_and_output_canaries(self):
        data, _ = fixture()
        clips, timing = self.buffers(513)
        C.memset(clips, 0xa5, C.sizeof(clips))
        C.memset(timing, 0x5a, C.sizeof(timing))
        extra_clip, extra_timing = bytes(clips[512]), bytes(timing[512])
        self.assertEqual(self.lib.dc_xa_load_clips(data, len(data), clips, timing, 513), 0)
        expected_clips, expected_timing = numeric_reference(clip_table())
        self.assertEqual(bytes(clips)[:len(expected_clips)], expected_clips)
        self.assertEqual(bytes(timing)[:len(expected_timing)], expected_timing)
        self.assertEqual((bytes(clips[512]), bytes(timing[512])), (extra_clip, extra_timing))

    def test_every_truncation_preserves_probe_output(self):
        data, _ = fixture()
        source = C.create_string_buffer(data)
        info = XAInfo()
        C.memset(C.byref(info), 0xa5, C.sizeof(info))
        before = bytes(info)
        for size in range(len(data)):
            self.assertEqual(self.lib.dc_xa_probe(source, size, C.byref(info)), 3, size)
            self.assertEqual(bytes(info), before, size)

    def test_unknown_flags_counts_trailing_data_and_bad_tails_preserve_arrays(self):
        valid, _ = fixture()
        corrupt = [valid[:-1], valid + b"\0", b"\1\xff\xff\xff\xff",
                   b"\0\1\xff\xff\xff\xff", b"\0\0\1\xff\xff\xff\xff"]
        for index in range(4):
            flags = bytearray(4)
            flags[index] = 2
            corrupt.append(bytes(flags))
        clips, timing = self.buffers()
        C.memset(clips, 0xa5, C.sizeof(clips))
        C.memset(timing, 0x5a, C.sizeof(timing))
        before = bytes(clips), bytes(timing)
        for data in corrupt:
            self.assertEqual(self.lib.dc_xa_load_clips(data, len(data), clips, timing, 512), 3)
            self.assertEqual((bytes(clips), bytes(timing)), before)

    def test_empty_profile_has_no_synthesized_table(self):
        data, _ = fixture(all_sections=False, has_clips=False)
        info = XAInfo()
        self.assertEqual(self.lib.dc_xa_probe(data, len(data), C.byref(info)), 0)
        self.assertEqual((info.has_clip_table, info.clip_count, info.parsed_bytes), (0, 0, 4))
        clips, timing = self.buffers()
        before = bytes(clips), bytes(timing)
        self.assertEqual(self.lib.dc_xa_load_clips(data, len(data), clips, timing, 512), 6)
        self.assertEqual((bytes(clips), bytes(timing)), before)

    def test_arguments_capacity_and_overlapping_spans_are_rejected(self):
        data, _ = fixture()
        source = C.create_string_buffer(data)
        clips, timing = self.buffers()
        self.assertEqual(self.lib.dc_xa_probe(None, 0, C.byref(XAInfo())), 1)
        self.assertEqual(self.lib.dc_xa_probe(source, len(data), None), 1)
        self.assertEqual(self.lib.dc_xa_probe(source, len(data), C.cast(source, C.POINTER(XAInfo))), 1)
        self.assertEqual(self.lib.dc_xa_load_clips(source, len(data), clips, timing, 511), 4)
        self.assertEqual(self.lib.dc_xa_load_clips(None, 0, clips, timing, 512), 1)
        self.assertEqual(self.lib.dc_xa_load_clips(source, len(data), None, timing, 512), 1)
        self.assertEqual(self.lib.dc_xa_load_clips(source, len(data), clips, None, 512), 1)
        before = source.raw, bytes(clips), bytes(timing)
        self.assertEqual(self.lib.dc_xa_load_clips(source, len(data),
            C.cast(source, C.POINTER(AnimationClip)), timing, 512), 1)
        self.assertEqual(self.lib.dc_xa_load_clips(source, len(data), clips,
            C.cast(clips, C.POINTER(AnimationTiming)), 512), 1)
        self.assertEqual((source.raw, bytes(clips), bytes(timing)), before)

    def test_decoded_self_authored_clip_drives_verified_controller(self):
        data = looping_fixture()
        clips, timing = self.buffers()
        self.assertEqual(self.lib.dc_xa_load_clips(data, len(data), clips, timing, 512), 0)
        state, result = AnimationState(blend=1), AnimationTickResult()
        for delta, expected in ((125, 1), (1000, 1)):
            self.assertEqual(self.lib.dc_animation_tick(C.byref(state), clips, timing, 512,
                delta, 1, 0, C.byref(result)), 0)
            self.assertEqual((result.sample_count, result.samples[0], state.frame), (1, expected, expected))


if __name__ == "__main__":
    unittest.main()
