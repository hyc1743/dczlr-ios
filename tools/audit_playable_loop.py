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
    0: "home_sh.cam", 1: "home_2f.cam", 3: "home_3f.cam", 4: "home_4f.cam",
    5: "home_5p.cam", 6: "home_5p.cam", 7: "home_5p.cam", 8: "home_5p.cam",
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
    map_rows = []
    for selector in SEQUENCE:
        data = entry(ROOT / "Data/RPP_10.pp", f"mm00_{selector:02d}.xx")
        camera_data = entry(ROOT / "Data/RPP_03.pp", CAMERAS[selector])
        camera = CameraOrbit()
        if lib.dc_camera_read_preset(camera_data, len(camera_data), 0, C.byref(camera)):
            raise RuntimeError(f"camera {selector} admission failed")
        handle = C.c_void_p()
        status = lib.dc_model_open_static(data, len(data), C.byref(handle))
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
