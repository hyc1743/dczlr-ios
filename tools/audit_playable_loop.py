"""Audit the local playable chapter-3 loop without rendering or exporting payloads.

The command admits every real map in the native chain, the animated actor and
the auxiliary face/morph resource, then drives the native interaction, map and
save transitions. It writes only hashes, counts and status metadata.
"""
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import (  # noqa: E402
    GameInteractionInput,
    GameInteractionResult,
    GameInteractionState,
    GamePlayer,
    PPArchive,
    XAInfo,
    XAMorphVectorSet,
    XXInfo,
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
            })
        finally:
            lib.dc_model_close(handle)

    actor = entry(ROOT / "Data/RPP_08.pp", "am00_01.xx")
    actor_xa = entry(ROOT / "Data/RPP_08.pp", "an00_02.xa")
    actor_handle = C.c_void_p()
    if lib.dc_model_open(actor, len(actor), actor_xa, len(actor_xa), C.byref(actor_handle)):
        raise RuntimeError("actor admission failed")
    lib.dc_model_close(actor_handle)

    face = entry(ROOT / "Data/RPP_09.pp", "ak00_00.xx")
    morph = entry(ROOT / "Data/RPP_09.pp", "an00_01.xa")
    face_handle = C.c_void_p()
    if lib.dc_model_open_static(face, len(face), C.byref(face_handle)):
        raise RuntimeError("face admission failed")
    lib.dc_model_close(face_handle)
    morph_info = XAInfo()
    if lib.dc_xa_probe(morph, len(morph), C.byref(morph_info)):
        raise RuntimeError("morph XA probe failed")
    vectors = (XAMorphVectorSet * morph_info.morph_vector_sets)()
    if lib.dc_xa_load_morph_vector_sets(morph, len(morph), vectors, morph_info.morph_vector_sets):
        raise RuntimeError("morph vector table failed")

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
