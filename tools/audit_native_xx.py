"""Audit native XX metadata and optional embedded pixels; export hashes only."""
import argparse
import ctypes as C
import hashlib
import io
import json
from pathlib import Path
import struct
from native_core import PPArchive, XXModel, library, XAInfo, XAMaterialTrack


def audit(data_directory, archive_filter=None, entry_filter=None, reference=None, images=False):
    rows, excluded, lib = [], [], library()
    for path in sorted(data_directory.glob("*.pp")):
        if archive_filter and path.name.lower() != archive_filter.lower(): continue
        try:
            archive = PPArchive(path)
        except ValueError:
            excluded.append(path.name)
            continue
        with archive:
            for index in range(archive.count):
                entry = archive.entry(index)
                if not entry.name_bytes.lower().endswith(b".xx"): continue
                if entry_filter and entry.name_bytes.lower() != entry_filter.encode("ascii").lower(): continue
                row = {"archive": path.name, "entry_index": index, "bytes": entry.size}
                if entry.size > 512 * 1024 * 1024:
                    rows.append({**row, "status": "input_limit"})
                    continue
                data = archive.read(index)
                row["source_sha256"] = hashlib.sha256(data).hexdigest()
                try:
                    with XXModel(data) as model:
                        info = model.info()
                        row["info"] = info.record()
                        nodes = [model.at("node", i) for i in range(info.nodes)]
                        meshes = [model.at("submesh", i) for i in range(info.submeshes)]
                        materials = [model.at("material", i) for i in range(info.materials)]
                        textures = [model.at("texture", i) for i in range(info.textures)]
                        if reference:
                            if reference["source_sha256"] != row["source_sha256"]: raise ValueError("Independent reference input differs")
                            if (info.nodes, info.submeshes, info.materials, info.textures, info.bones) != (reference["node_count"], len(reference["submeshes"]), reference["material_count"], reference["texture_count"], reference["bones"]):
                                raise ValueError("Reference counts differ")
                            for node, ref in zip(nodes, reference["nodes"]):
                                if (node.children, node.submeshes) != (ref["children"], ref["submeshes"]): raise ValueError("Node reference differs")
                                if hashlib.sha256(bytes(b ^ 255 for b in model.span(node.name))).hexdigest() != ref["name_sha256"]: raise ValueError("Node name hash differs")
                            for mesh, ref in zip(meshes, reference["submeshes"]):
                                if (mesh.material, mesh.index_count, mesh.vertex_count, mesh.uv_sets, mesh.indices.offset, mesh.vertices.offset) != (ref["material_index"], ref["indices"], ref["vertices"], ref["uv_sets"], ref["index_offset"], ref["vertex_offset"]): raise ValueError("Mesh spans differ")
                            for material, ref in zip(materials, reference["materials"]):
                                if material.value_offset != ref["value_offset"]: raise ValueError("Material spans differ")
                            for texture, ref in zip(textures, reference["textures"]):
                                if (texture.image.offset, texture.image.length) != (ref["encoded_image_offset"], ref["encoded_image_bytes"]): raise ValueError("Texture spans differ")
                            row["independent_framing_reference_matched"] = True
                        digest = hashlib.sha256()
                        for i, material in enumerate(materials):
                            raw = data[material.value_offset:material.value_offset + 68]
                            expected = struct.pack("<16I", *(v ^ 0x80000000 for v in struct.unpack("<16I", raw[:64]))) + raw[64:]
                            baseline = bytes(model.baseline(i))
                            if baseline != expected: raise ValueError("Material baseline numeric bytes differ")
                            digest.update(baseline)
                        row["baseline_sha256"] = digest.hexdigest()
                        stem = entry.name_bytes[:-3]
                        xa_indexes = [i for i in range(archive.count) if archive.entry(i).name_bytes.lower() == (stem + b".xa").lower()]
                        if len(xa_indexes) == 1:
                            xa_entry = archive.entry(xa_indexes[0])
                            if xa_entry.size > 128 * 1024 * 1024: raise ValueError("XA audit input cap exceeded")
                            xa = archive.read(xa_indexes[0]); xa_info = XAInfo()
                            if lib.dc_xa_probe(xa, len(xa), C.byref(xa_info)): raise ValueError("Companion XA rejected")
                            matched, missing = 0, 0
                            for i in range(xa_info.material_tracks):
                                track = XAMaterialTrack()
                                if lib.dc_xa_material_track_at(xa, len(xa), i, C.byref(track)): raise ValueError("XA view rejected")
                                name = xa[track.name_offset:track.name_offset + track.name_length]
                                selected = C.c_uint32(0xffffffff)
                                status = lib.dc_xx_find_material_encoded(model.handle, name, len(name), C.byref(selected))
                                if status == 6: missing += 1; continue
                                if status: raise ValueError("Material encoded-name matching failed")
                                decoded = bytes(b ^ 255 for b in name).split(b"\0", 1)[0]
                                matches = [j for j, mat in enumerate(materials) if bytes(b ^ 255 for b in model.span(mat.name)).split(b"\0", 1)[0] == decoded]
                                if not matches or selected.value != matches[0]: raise ValueError("First material match differs")
                                matched += 1
                            row["companion_xa_material_targets"] = {"matched": matched, "missing": missing}
                        row["embedded_images"] = []
                        if images:
                            from PIL import Image
                            for i, texture in enumerate(textures):
                                image_info, actual = model.image(i)
                                encoded = model.span(texture.image)
                                suffix = bytes(b ^ 255 for b in model.span(texture.name)).split(b"\0", 1)[0][-4:]
                                if suffix == b".bmp" and encoded[:2] == b"\0\0": encoded = b"BM" + encoded[2:]
                                with Image.open(io.BytesIO(encoded)) as image:
                                    expected = image.convert("RGBA").tobytes()
                                    if image.size != (image_info.width, image_info.height) or expected != actual: raise ValueError("Embedded pixels differ from Pillow")
                                row["embedded_images"].append({"index": i, "width": image_info.width, "height": image_info.height,
                                    "rgba_sha256": hashlib.sha256(actual).hexdigest(), "status": "all_pixels_match"})
                        row["status"] = "native_metadata_and_baselines_verified"
                except ValueError as error:
                    row.update(status="rejected_or_mismatched", reason=str(error))
                rows.append(row)
    return {"method": "native admitted XX reader; optional independent local framing and Pillow embedded-image comparison",
            "models": rows, "examined": len(rows), "verified": sum(r["status"] == "native_metadata_and_baselines_verified" for r in rows),
            "rejected_or_mismatched": sum(r["status"] != "native_metadata_and_baselines_verified" for r in rows),
            "unrecognized_pp_excluded": excluded, "images_requested": images,
            "original_full_loader_or_gpu": "not executed", "payload_or_values_exported": False, "game_playability": "not_verified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--archive")
    parser.add_argument("--entry")
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--images", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reference = json.loads(args.reference.read_text(encoding="utf-8")) if args.reference else None
    report = audit(args.data, args.archive, args.entry, reference, args.images)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "models"}))
