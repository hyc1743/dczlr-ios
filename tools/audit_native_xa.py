"""Audit local XA metadata and decoded clip bytes without exporting payloads."""
import argparse
import ctypes as C
import hashlib
import json
import struct
from pathlib import Path
from native_core import library, XAInfo, AnimationClip, AnimationTiming, PPArchive, XAMaterialTrack, MaterialKey, XAPoseTrack, PoseKey
from xa_cases import numeric_reference


def audit(directory, reference=None):
    lib = library()
    references = {(row["archive"], row["index"]): row for row in reference["entries"]} if reference else None
    rows, unrecognized = [], []
    for path in sorted(directory.glob("*.pp")):
        try:
            archive = PPArchive(path)
        except ValueError:
            unrecognized.append(path.name)
            continue
        with archive:
            for index in range(archive.count):
                entry = archive.entry(index)
                if not entry.name_bytes.lower().endswith(b".xa"):
                    continue
                if entry.size > 128 * 1024 * 1024:
                    raise ValueError("XA input exceeds audit allocation limit")
                data = archive.read(index)
                digest = hashlib.sha256(data).hexdigest()
                info = XAInfo()
                if lib.dc_xa_probe(data, len(data), C.byref(info)):
                    raise ValueError(f"Native XA framing rejected {path.name}:{index}")
                if references is not None:
                    ref = references[(path.name, index)]
                    if ref["source_sha256"] != digest or ref["status"] != "framing_consumes_entire_entry":
                        raise ValueError("Independent reference input/profile does not match")
                    for name in ("material_tracks", "event_tracks", "morph_index_sets", "morph_vector_sets", "morph_tracks", "bone_tracks"):
                        if getattr(info, name) != ref["section_counts"].get(name, 0):
                            raise ValueError("Native/reference section count mismatch: " + name)
                    if (info.clip_table_offset if info.has_clip_table else None) != ref["clip_table_offset"]:
                        raise ValueError("Native/reference clip-table offset mismatch")
                clips, timing = (AnimationClip * 512)(), (AnimationTiming * 512)()
                status = lib.dc_xa_load_clips(data, len(data), clips, timing, 512)
                if info.has_clip_table:
                    if status:
                        raise ValueError("Native clip-table decode failed")
                    raw = data[info.clip_table_offset:info.clip_table_offset + 512 * 108]
                    expected = numeric_reference(raw)
                    if (bytes(clips), bytes(timing)) != expected:
                        raise ValueError("Native numeric fields differ from serialized bytes")
                    decoded_digest = hashlib.sha256(bytes(clips) + bytes(timing)).hexdigest()
                else:
                    if status != 6:
                        raise ValueError("Missing table was synthesized")
                    decoded_digest = None
                material_digest = hashlib.sha256()
                material_keys = 0
                offset = 5 if data[0] == 1 else 0
                for track_index in range(info.material_tracks):
                    name_length = struct.unpack_from("<I", data, offset)[0]
                    name_offset = offset + 4
                    count = struct.unpack_from("<I", data, name_offset + name_length)[0]
                    keys_offset = name_offset + name_length + 4
                    view = XAMaterialTrack()
                    if lib.dc_xa_material_track_at(data, len(data), track_index, C.byref(view)):
                        raise ValueError("Native material track lookup failed")
                    if (view.name_offset, view.name_length, view.keys_offset, view.key_count) != (name_offset, name_length, keys_offset, count):
                        raise ValueError("Material track view differs from independent serialized cursor")
                    keys = (MaterialKey * count)()
                    if lib.dc_xa_load_material_keys(data, len(data), track_index, keys, count):
                        raise ValueError("Native material key decode failed")
                    serialized = data[keys_offset:keys_offset + count * 72]
                    if bytes(keys) != serialized:
                        raise ValueError("Native material keys differ from serialized bytes")
                    material_keys += count
                    material_digest.update(bytes(keys))
                    offset = keys_offset + count * 72
                pose_digest, pose_keys, pose_modes = hashlib.sha256(), 0, {}
                offset = info.clip_table_offset + 512 * 108 + 4
                for track_index in range(info.bone_tracks):
                    name_length = struct.unpack_from('<I', data, offset)[0]
                    name_offset = offset + 4
                    count, mode = struct.unpack_from('<2I', data, name_offset + name_length)
                    keys_offset = name_offset + name_length + 8
                    view = XAPoseTrack()
                    if lib.dc_xa_pose_track_at(data, len(data), track_index, C.byref(view)):
                        raise ValueError('Native pose track lookup failed')
                    if (view.name_offset,view.name_length,view.keys_offset,view.key_count,view.mode) != (name_offset,name_length,keys_offset,count,mode):
                        raise ValueError('Pose metadata differs from serialized cursor')
                    keys = (PoseKey * count)()
                    if lib.dc_xa_load_pose_keys(data, len(data), track_index, keys, count):
                        raise ValueError('Native pose key decode failed')
                    if bytes(keys) != data[keys_offset:keys_offset + count*52]:
                        raise ValueError('Pose key bytes differ')
                    pose_digest.update(bytes(keys)); pose_keys += count
                    pose_modes[str(mode)] = pose_modes.get(str(mode), 0) + 1
                    offset = keys_offset + count * 52
                rows.append({"archive": path.name, "index": index, "bytes": entry.size,
                             "source_sha256": digest, "info": info.record(),
                             "numeric_table_sha256": decoded_digest, "material_keys": material_keys,
                             "material_keys_sha256": material_digest.hexdigest(), "pose_keys": pose_keys,
                             "pose_modes": pose_modes, "pose_keys_sha256": pose_digest.hexdigest(), "status": "metadata_and_numeric_bytes_match"})
    if references is not None and set(references) != {(r["archive"], r["index"]) for r in rows}:
        raise ValueError("Independent reference entry coverage differs")
    return {"schema": 1, "method": "native XA framing plus serialized-field byte comparison",
            "independent_framing_reference": references is not None,
            "entries": rows, "verified_xa": len(rows), "decoded_clip_records": sum(r["info"]["clip_count"] for r in rows),
            "material_tracks": sum(r["info"]["material_tracks"] for r in rows),
            "material_key_records": sum(r["material_keys"] for r in rows),
            "pose_tracks": sum(r['info']['bone_tracks'] for r in rows),
            "pose_key_records": sum(r['pose_keys'] for r in rows),
            "unrecognized_archives_not_inspected": unrecognized,
            "payload_exported": False, "names_or_pose_values_exported": False,
            "pose_material_sampling": "not verified by this audit; key bytes only", "game_playability": "not_verified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reference = json.loads(args.reference.read_text(encoding="utf-8")) if args.reference else None
    result = audit(args.data, reference)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "entries"}))
