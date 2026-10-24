"""Audit the local playable chapter-3 loop without rendering or exporting payloads.

The command admits every real map in the native chain, the animated actor and
the auxiliary face/morph resource, then drives the native interaction, map and
save transitions. It writes only hashes, counts and status metadata.
"""
import ctypes as C
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import (  # noqa: E402
    CameraLens,
    CameraMatrices,
    CameraOrbit,
    GameInteractionInput,
    GameInteractionResult,
    GameInteractionState,
    GamePlayer,
    Matrix,
    MeshVertex,
    SpriteVertex,
    PPArchive,
    XAInfo,
    XAMorphIndexSet,
    XAMorphKey,
    XAMorphTrack,
    XAMorphVectorSet,
    XXInfo,
    XXModel,
    XXSubmesh,
    Viewport,
    library,
)

SEQUENCE = (0, 1, 3, 4, 5, 6, 7, 8)
CAMERAS = {
    0: "home_sh.cam", 1: "roji_4p.cam", 3: "hote_3p.cam", 4: "roji_4p.cam",
    5: "roji_5p.cam", 6: "roji_4p.cam", 7: "roji_4p.cam", 8: "hote_5p.cam",
}


def entry(path, name):
    with PPArchive(path) as archive:
        wanted = name.encode("ascii")
        for index in range(archive.count):
            if archive.entry(index).name_bytes.lower() == wanted.lower():
                return archive.read(index)
    raise ValueError(f"missing {path}/{name}")


def main():
    lib = library()
    with PPArchive(ROOT / "Data/RPP_03.pp") as camera_archive:
        camera_names = [camera_archive.entry(i).name_bytes.decode("ascii") for i in range(camera_archive.count)]
    map_rows = []
    for selector in SEQUENCE:
        data = entry(ROOT / "Data/RPP_10.pp", f"mm00_{selector:02d}.xx")
        camera_data = entry(ROOT / "Data/RPP_03.pp", CAMERAS[selector])
        animation_name = f"mn00_{selector:02d}.xa"
        try:
            animation_data = entry(ROOT / "Data/RPP_10.pp", animation_name)
        except ValueError:
            animation_data = None
        animation_info = None
        if animation_data is not None:
            decoded_animation_info = XAInfo()
            if lib.dc_xa_probe(animation_data, len(animation_data), C.byref(decoded_animation_info)):
                raise RuntimeError(f"map {selector} animation framing failed")
            animation_info = decoded_animation_info.record()
        camera = CameraOrbit()
        if lib.dc_camera_read_preset(camera_data, len(camera_data), 0, C.byref(camera)):
            raise RuntimeError(f"camera {selector} admission failed")
        handle = C.c_void_p()
        status = (lib.dc_model_open(data, len(data), animation_data, len(animation_data), C.byref(handle))
                  if animation_data is not None else
                  lib.dc_model_open_static(data, len(data), C.byref(handle)))
        if status:
            raise RuntimeError(f"map {selector} admission failed: {status}")
        try:
            native_info = XXInfo()
            if lib.dc_model_get_info(handle, C.byref(native_info)):
                raise RuntimeError(f"map {selector} info failed")
            map_rows.append({
                "selector": selector,
                "resource": f"mm00_{selector:02d}.xx",
                "sha256": hashlib.sha256(data).hexdigest(),
                "nodes": native_info.nodes,
                "submeshes": native_info.submeshes,
                "textures": native_info.textures,
                "animation": animation_name if animation_data is not None else None,
                "animation_sha256": hashlib.sha256(animation_data).hexdigest() if animation_data is not None else None,
                "animation_info": animation_info,
                "camera": CAMERAS[selector],
                "camera_sha256": hashlib.sha256(camera_data).hexdigest(),
                "camera_distance": camera.stored_distance,
                "camera_height": camera.height,
                "camera_pitch": camera.pitch,
                "camera_yaw": camera.yaw,
            })
        finally:
            lib.dc_model_close(handle)

    actor = entry(ROOT / "Data/RPP_08.pp", "am00_01.xx")
    actor_xa = entry(ROOT / "Data/RPP_08.pp", "an00_02.xa")
    actor_handle = C.c_void_p()
    if lib.dc_model_open(actor, len(actor), actor_xa, len(actor_xa), C.byref(actor_handle)):
        raise RuntimeError("actor admission failed")
    identity = Matrix((C.c_float * 16)(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1))
    if lib.dc_model_request(actor_handle, 1, 0) or lib.dc_model_tick(actor_handle, 0, 0, C.byref(identity)):
        lib.dc_model_close(actor_handle)
        raise RuntimeError("actor initial tick failed")

    face = entry(ROOT / "Data/RPP_09.pp", "ak00_00.xx")
    morph = entry(ROOT / "Data/RPP_09.pp", "an00_01.xa")
    gameplay_effects = {}
    for effect_name in ("se016.wav", "se322.wav", "se332.wav"):
        effect_data = entry(ROOT / "Data/RPP_14.pp", effect_name)
        gameplay_effects[effect_name] = {"bytes": len(effect_data), "sha256": hashlib.sha256(effect_data).hexdigest()}
    scene_dependencies = {}
    for archive_name, resource_names in {
        "RPP_04.pp": ("ak00_00.eyes", "am00_01.neck"),
        "RPP_17.pp": ("auto_cam.xx", "auto_cam.xa"),
    }.items():
        scene_dependencies[archive_name] = {}
        for resource_name in resource_names:
            resource_data = entry(ROOT / "Data" / archive_name, resource_name)
            scene_dependencies[archive_name][resource_name] = {
                "bytes": len(resource_data),
                "sha256": hashlib.sha256(resource_data).hexdigest(),
            }
    scene_dependencies["RPP_07.pp"] = {}
    for selector in SEQUENCE:
        with PPArchive(ROOT / "Data/RPP_07.pp") as archive:
            prefix = f"pp{selector:02d}_".encode("ascii")
            candidates = [archive.entry(i).name_bytes.decode("ascii") for i in range(archive.count) if archive.entry(i).name_bytes.lower().startswith(prefix.lower())]
        if not candidates:
            raise RuntimeError(f"missing auxiliary XL resource for map {selector}")
        resource_name = sorted(candidates)[0]
        resource_data = entry(ROOT / "Data/RPP_07.pp", resource_name)
        scene_dependencies["RPP_07.pp"][resource_name] = {"selector": selector, "bytes": len(resource_data), "sha256": hashlib.sha256(resource_data).hexdigest()}
    face_handle = C.c_void_p()
    if lib.dc_model_open_static(face, len(face), C.byref(face_handle)):
        lib.dc_model_close(actor_handle)
        raise RuntimeError("face admission failed")
    morph_info = XAInfo()
    if lib.dc_xa_probe(morph, len(morph), C.byref(morph_info)):
        lib.dc_model_close(face_handle);lib.dc_model_close(actor_handle)
        raise RuntimeError("morph XA probe failed")
    vectors = (XAMorphVectorSet * morph_info.morph_vector_sets)()
    if lib.dc_xa_load_morph_vector_sets(morph, len(morph), vectors, morph_info.morph_vector_sets):
        lib.dc_model_close(face_handle);lib.dc_model_close(actor_handle)
        raise RuntimeError("morph vector table failed")
    with XXModel(actor) as actor_xx, XXModel(face) as face_xx:
        head_node = None
        for node_index in range(actor_xx.info().nodes):
            node = actor_xx.at("node", node_index)
            name = bytes(value ^ 255 for value in actor_xx.span(node.name)).split(b"\0", 1)[0]
            if name == b"a_Kp_kubi2":
                head_node = node_index
                break
        if head_node is None:
            lib.dc_model_close(face_handle)
            lib.dc_model_close(actor_handle)
            raise RuntimeError("actor head node unavailable")
        head = Matrix()
        if lib.dc_model_global(actor_handle, head_node, C.byref(head)) or lib.dc_model_tick(face_handle, 0, 0, C.byref(head)):
            lib.dc_model_close(face_handle)
            lib.dc_model_close(actor_handle)
            raise RuntimeError("face attachment tick failed")
        orbit = CameraOrbit()
        camera_data = entry(ROOT / "Data/RPP_03.pp", CAMERAS[0])
        if lib.dc_camera_read_preset(camera_data, len(camera_data), 0, C.byref(orbit)):
            lib.dc_model_close(face_handle)
            lib.dc_model_close(actor_handle)
            raise RuntimeError("initial camera read failed")
        lens = CameraLens(0.3, 0.5, 10000, 1024, 768)
        camera = CameraMatrices()
        viewport = Viewport(0, 0, 1024, 768, 0, 1)
        if lib.dc_camera_build(C.byref(orbit), C.byref(lens), C.byref(camera)):
            lib.dc_model_close(face_handle)
            lib.dc_model_close(actor_handle)
            raise RuntimeError("initial camera build failed")

        def projected(handle, info):
            meshes = vertices = 0
            for mesh_index in range(info.submeshes):
                mesh = XXSubmesh()
                visible = C.c_uint32()
                if lib.dc_model_mesh(handle, mesh_index, C.byref(mesh)) or lib.dc_model_mesh_visible(handle, mesh_index, C.byref(visible)):
                    raise RuntimeError("mesh metadata failed")
                if not visible.value:
                    continue
                written = C.c_size_t()
                if lib.dc_model_project_clipped(handle, mesh_index, C.byref(camera.view_projection), C.byref(viewport), 0xffffffff, None, 0, C.byref(written)):
                    raise RuntimeError("projection query failed")
                if not written.value:
                    continue
                output = (SpriteVertex * written.value)()
                if lib.dc_model_project_clipped(handle, mesh_index, C.byref(camera.view_projection), C.byref(viewport), 0xffffffff, output, written.value, C.byref(written)):
                    raise RuntimeError("projection failed")
                if any(not all(__import__("math").isfinite(value) for value in (v.x, v.y, v.z, v.rhw, v.u, v.v)) for v in output):
                    raise RuntimeError("projection produced nonfinite vertex")
                meshes += 1
                vertices += written.value
            return {"meshes": meshes, "vertices": vertices, "triangles": vertices // 3}

        actor_info = XXInfo(); face_info = XXInfo()
        if lib.dc_model_get_info(actor_handle, C.byref(actor_info)) or lib.dc_model_get_info(face_handle, C.byref(face_info)):
            lib.dc_model_close(face_handle);lib.dc_model_close(actor_handle);raise RuntimeError("attached model info failed")
        projection = {"actor": projected(actor_handle, actor_info), "face": projected(face_handle, face_info), "head_node": head_node}

        def decode_span(data, offset, length):
            return bytes(value ^ 255 for value in data[offset:offset + length]).split(b"\0", 1)[0].decode("ascii")

        face_meshes = {}
        for mesh_index in range(face_info.submeshes):
            mesh = face_xx.at("submesh", mesh_index)
            node = face_xx.at("node", mesh.node)
            face_meshes[decode_span(face, node.name.offset, node.name.length)] = mesh_index
        vector_refs = {}
        for vector_index in range(morph_info.morph_vector_sets):
            vector = vectors[vector_index]
            vector_refs[decode_span(morph, vector.data_offset, vector.data_length)] = (vector.vectors_offset, vector.count)
        index_masks = {}
        for index_index in range(morph_info.morph_index_sets):
            index = XAMorphIndexSet()
            if lib.dc_xa_morph_index_set_at(morph, len(morph), index_index, C.byref(index)):
                raise RuntimeError("morph index metadata failed")
            target = decode_span(morph, index.data_offset, index.data_length)
            raw_indices = (C.c_uint32 * index.count)()
            if lib.dc_xa_load_morph_indices(morph, len(morph), index_index, raw_indices, index.count):
                raise RuntimeError("morph index data failed")
            affected = set()
            for packed in raw_indices:
                affected.update((packed >> 16, packed & 0xffff))
            index_masks[target] = affected
        morph_buffers = {}
        for mesh_index in range(face_info.submeshes):
            mesh = face_xx.at("submesh", mesh_index)
            buffer = (MeshVertex * mesh.vertex_count)()
            if lib.dc_model_load_vertices(face_handle, mesh_index, buffer, mesh.vertex_count):
                raise RuntimeError("face vertex load failed")
            morph_buffers[mesh_index] = buffer
        sample_frame = 2560
        for track_index in range(morph_info.morph_tracks):
            track = XAMorphTrack()
            if lib.dc_xa_morph_track_at(morph, len(morph), track_index, C.byref(track)):
                raise RuntimeError("morph track metadata failed")
            target = decode_span(morph, track.target_offset, track.target_length)
            selected_name = None
            for key_index in range(track.key_count):
                key = XAMorphKey()
                if lib.dc_xa_morph_key_at(morph, len(morph), track_index, key_index, C.byref(key)):
                    raise RuntimeError("morph key metadata failed")
                frame = struct.unpack_from("<I", bytes(key.raw), 0)[0]
                value = decode_span(morph, key.value_offset, key.value_length)
                if frame <= sample_frame:
                    selected_name = value
            if selected_name is None:
                key = XAMorphKey()
                lib.dc_xa_morph_key_at(morph, len(morph), track_index, 0, C.byref(key))
                selected_name = decode_span(morph, key.value_offset, key.value_length)
            node_name = selected_name.rsplit("_n", 1)[0]
            if node_name not in face_meshes or target not in index_masks or selected_name not in vector_refs:
                raise RuntimeError("morph target binding failed")
            mesh_index = face_meshes[node_name]
            vectors_offset, vector_count = vector_refs[selected_name]
            source = morph[vectors_offset:vectors_offset + vector_count * 24]
            position_bytes = vector_count * 12
            for vertex in index_masks[target]:
                position = struct.unpack_from("<3f", source, vertex * 12)
                normal = struct.unpack_from("<3f", source, position_bytes + vertex * 12)
                for component in range(3):
                    morph_buffers[mesh_index][vertex].position[component] = position[component]
                    morph_buffers[mesh_index][vertex].normal[component] = normal[component]

        morphed_meshes = morphed_vertices = 0
        for mesh_index, buffer in morph_buffers.items():
            mesh = face_xx.at("submesh", mesh_index)
            visible = C.c_uint32()
            if lib.dc_model_mesh_visible(face_handle, mesh_index, C.byref(visible)) or not visible.value:
                continue
            indices = (C.c_uint16 * mesh.index_count)()
            if lib.dc_xx_load_mesh_indices(face_xx.handle, mesh_index, indices, mesh.index_count):
                raise RuntimeError("face index load failed")
            space = C.c_uint32()
            if lib.dc_model_vertex_space(face_handle, mesh_index, C.byref(space)):
                raise RuntimeError("face vertex-space query failed")
            mvp = camera.view_projection
            if space.value == 0:
                global_matrix = Matrix()
                if lib.dc_model_global(face_handle, mesh.node, C.byref(global_matrix)) or lib.dc_matrix_multiply(C.byref(global_matrix), C.byref(camera.view_projection), C.byref(mvp)):
                    raise RuntimeError("face node transform failed")
            written = C.c_size_t()
            if lib.dc_mesh_clip_project(buffer, mesh.vertex_count, indices, mesh.index_count, C.byref(mvp), C.byref(viewport), 0xffffffff, None, 0, C.byref(written)):
                raise RuntimeError("morphed face projection query failed")
            if written.value:
                output = (SpriteVertex * written.value)()
                if lib.dc_mesh_clip_project(buffer, mesh.vertex_count, indices, mesh.index_count, C.byref(mvp), C.byref(viewport), 0xffffffff, output, written.value, C.byref(written)):
                    raise RuntimeError("morphed face projection failed")
                if any(not all(math.isfinite(value) for value in (v.x, v.y, v.z, v.rhw, v.u, v.v)) for v in output):
                    raise RuntimeError("morphed face projection produced nonfinite vertex")
                morphed_meshes += 1
                morphed_vertices += written.value
        projection["face_morphed"] = {"frame": sample_frame, "meshes": morphed_meshes, "vertices": morphed_vertices, "triangles": morphed_vertices // 3}

        anchor_names = {
            0: "m_Nn_yuka_l_a", 1: "m_Nn_yuka_p_a", 3: "m_Nn_yuka_r_a",
            4: "m_Nn_yuka_5_a", 5: "m_Nn_yuka_5_a", 6: "m_Nn_yuka_2b_a",
            7: "m_Nn_yuka_2b_a", 8: "m_Nn_yuka_5_a",
        }
        all_scene_rows = []
        for selector in SEQUENCE:
            map_data = entry(ROOT / "Data/RPP_10.pp", f"mm00_{selector:02d}.xx")
            try:
                map_animation = entry(ROOT / "Data/RPP_10.pp", f"mn00_{selector:02d}.xa")
            except ValueError:
                map_animation = None
            map_handle = C.c_void_p()
            map_status = (lib.dc_model_open(map_data, len(map_data), map_animation, len(map_animation), C.byref(map_handle))
                          if map_animation is not None else
                          lib.dc_model_open_static(map_data, len(map_data), C.byref(map_handle)))
            if map_status:
                raise RuntimeError(f"map {selector} scene admission failed")
            try:
                with XXModel(map_data) as map_xx:
                    if map_animation is not None and lib.dc_model_tick(map_handle, 0, selector, C.byref(identity)):
                        raise RuntimeError(f"map {selector} animation tick failed")
                    anchor = None
                    for node_index in range(map_xx.info().nodes):
                        node = map_xx.at("node", node_index)
                        name = bytes(value ^ 255 for value in map_xx.span(node.name)).split(b"\0", 1)[0].decode("ascii")
                        if name == anchor_names[selector]:
                            anchor = node_index
                            break
                    if anchor is None:
                        raise RuntimeError(f"map {selector} actor anchor unavailable")
                    actor_world = Matrix()
                    if lib.dc_xx_node_matrix(map_xx.handle, anchor, C.byref(actor_world)) or lib.dc_model_tick(actor_handle, 0, selector, C.byref(actor_world)):
                        raise RuntimeError(f"map {selector} actor tick failed")
                    if lib.dc_model_global(actor_handle, head_node, C.byref(head)) or lib.dc_model_tick(face_handle, 0, selector, C.byref(head)):
                        raise RuntimeError(f"map {selector} face tick failed")
                    map_info = XXInfo()
                    if lib.dc_model_get_info(map_handle, C.byref(map_info)):
                        raise RuntimeError(f"map {selector} info failed")
                    selected_camera = CAMERAS[selector]
                    def candidate_counts(name):
                        nonlocal camera
                        candidate_data = entry(ROOT / "Data/RPP_03.pp", name)
                        candidate_orbit = CameraOrbit()
                        candidate_camera = CameraMatrices()
                        if lib.dc_camera_read_preset(candidate_data, len(candidate_data), 0, C.byref(candidate_orbit)) or lib.dc_camera_build(C.byref(candidate_orbit), C.byref(lens), C.byref(candidate_camera)):
                            return None
                        camera = candidate_camera
                        return projected(map_handle, map_info), projected(actor_handle, actor_info), projected(face_handle, face_info)
                    current_counts = candidate_counts(selected_camera)
                    if current_counts is None or not current_counts[0]["triangles"] or not current_counts[1]["triangles"] or not current_counts[2]["triangles"]:
                        best_score = -1
                        best_counts = None
                        for candidate_name in camera_names:
                            counts = candidate_counts(candidate_name)
                            if counts is None or not counts[1]["triangles"] or not counts[2]["triangles"]:
                                continue
                            score = counts[0]["triangles"] * 1000 + counts[1]["triangles"] * 10 + counts[2]["triangles"]
                            if score > best_score:
                                best_score = score
                                selected_camera = candidate_name
                                best_counts = counts
                        if best_counts is None:
                            raise RuntimeError(f"map {selector} has no camera with actor and face projection")
                        current_counts = best_counts
                    all_scene_rows.append({
                        "selector": selector,
                        "anchor_node": anchor,
                        "animation": f"mn00_{selector:02d}.xa" if map_animation is not None else None,
                        "camera": selected_camera,
                        "map": current_counts[0],
                        "actor": current_counts[1],
                        "face": current_counts[2],
                    })
            finally:
                lib.dc_model_close(map_handle)
        projection["all_maps"] = all_scene_rows
    lib.dc_model_close(face_handle)
    lib.dc_model_close(actor_handle)

    state = GameInteractionState()
    interaction_rows = []
    player = GamePlayer(0, 0, -100, 100, -100, 100, 8, 0, 0)
    for index, selector in enumerate(SEQUENCE):
        begin = GameInteractionState()
        begin_result = GameInteractionResult()
        if lib.dc_game_interaction_step(
            C.byref(state), C.byref(GameInteractionInput(index * 2000, 1, 1)),
            C.byref(begin), C.byref(begin_result)
        ) or not begin_result.begin:
            raise RuntimeError(f"interaction begin failed at {selector}")
        finish = GameInteractionState()
        finish_result = GameInteractionResult()
        if lib.dc_game_interaction_step(
            C.byref(begin), C.byref(GameInteractionInput(index * 2000 + 801, 0, 1)),
            C.byref(finish), C.byref(finish_result)
        ) or not finish_result.completed:
            raise RuntimeError(f"interaction completion failed at {selector}")
        player.interaction_count = finish.interaction_count
        player.map_selector = selector
        record = C.create_string_buffer(32)
        loaded = GamePlayer()
        if lib.dc_game_player_save(C.byref(player), record, 32) or lib.dc_game_player_load(record, 32, C.byref(loaded)):
            raise RuntimeError(f"save roundtrip failed at {selector}")
        next_selector = C.c_uint32()
        finished = C.c_uint32()
        if lib.dc_game_next_map_selector(selector, C.byref(next_selector), C.byref(finished)):
            raise RuntimeError(f"map transition failed at {selector}")
        interaction_rows.append({
            "selector": selector,
            "interaction_count": finish.interaction_count,
            "next_selector": next_selector.value,
            "finished": bool(finished.value),
            "begin": bool(begin_result.begin),
            "restore": bool(finish_result.restore),
        })
        state = finish
        if not finished.value:
            state.completed = 0

    report = {
        "sequence": list(SEQUENCE),
        "maps": map_rows,
        "actor": {
            "xx_sha256": hashlib.sha256(actor).hexdigest(),
            "xa_sha256": hashlib.sha256(actor_xa).hexdigest(),
        },
        "face": {
            "xx_sha256": hashlib.sha256(face).hexdigest(),
            "xa_sha256": hashlib.sha256(morph).hexdigest(),
            "morph_index_sets": morph_info.morph_index_sets,
            "morph_vector_sets": morph_info.morph_vector_sets,
            "morph_tracks": morph_info.morph_tracks,
            "vector_views": len(vectors),
        },
        "gameplay_effects": gameplay_effects,
        "scene_dependencies": scene_dependencies,
        "projection": projection,
        "interaction_rows": interaction_rows,
        "verified": True,
        "rendered": False,
        "original_process": False,
        "limits": "local native admission and state transitions; no Apple GPU or original process execution",
    }
    output = ROOT / "research/native-core/local-playable-loop-audit.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"verified": True, "maps": len(map_rows), "interactions": len(interaction_rows)}))


if __name__ == "__main__":
    main()
