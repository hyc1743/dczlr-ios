"""Interactive local chapter-3 session using the native gameplay state machine.

This is a Windows-side development runner. It reads the real local Data
directory, admits each map before entering it, and drives the same player,
interaction, map-sequence, and save/load APIs used by the Apple scene. It does
not render or export original resources.
"""
from __future__ import annotations

import argparse
import ctypes as C
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from native_core import (  # noqa: E402
    GameInput, GameInteractionInput, GameInteractionResult,
    GameInteractionState, GamePlayer, PPArchive, library,
)

SEQUENCE = (0, 1, 3, 4, 5, 6, 7, 8)


def entry(root: Path, name: str, archive_name: str = "RPP_10.pp") -> bytes:
    with PPArchive(root / archive_name) as archive:
        wanted = name.encode("ascii")
        for i in range(archive.count):
            if archive.entry(i).name_bytes.lower() == wanted.lower():
                return archive.read(i)
    raise ValueError(f"missing resource {name}")


def admit(root: Path, selector: int) -> None:
    data = entry(root, f"mm00_{selector:02d}.xx")
    if not data:
        raise RuntimeError(f"empty map {selector}")


def admit_shared_gameplay_resources(root: Path) -> None:
    for archive, name in (
        ("RPP_08.pp", "am00_01.xx"), ("RPP_08.pp", "an00_02.xa"),
        ("RPP_09.pp", "ak00_00.xx"), ("RPP_09.pp", "an00_01.xa"),
        ("RPP_04.pp", "ak00_00.eyes"), ("RPP_04.pp", "am00_01.neck"),
    ):
        if not entry(root, name, archive):
            raise RuntimeError(f"empty resource {archive}/{name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=ROOT / "Data")
    parser.add_argument("--load", action="store_true", help="restore Data/save/player.state before starting")
    args = parser.parse_args()
    root = args.data.resolve()
    if not root.is_dir():
        parser.error(f"missing Data directory: {root}")
    lib = library()
    admit_shared_gameplay_resources(root)
    save_dir = root / "save"
    save_path = save_dir / "player.state"
    state = GamePlayer(0, 0, -100, 100, -100, 100, 8, 0, 0)
    interaction = GameInteractionState()
    if args.load:
        if not save_path.is_file():
            parser.error(f"missing save file: {save_path}")
        raw = C.create_string_buffer(save_path.read_bytes()[:32], 32)
        restored = GamePlayer()
        status = lib.dc_game_player_load(raw, 32, C.byref(restored))
        if status != 0:
            parser.error(f"invalid save file: status {status}")
        restored.min_x, restored.max_x = state.min_x, state.max_x
        restored.min_z, restored.max_z = state.min_z, state.max_z
        state = restored
        admit(root, state.map_selector)
        interaction = GameInteractionState(state.interaction_count, 0, 0, 0)
        print(f"loaded map {state.map_selector}")
    print("native session ready; commands: m dx dz | i | s | l | q")
    if not args.load:
        print("map 0 admitted")
    while True:
        try:
            command = input(f"map={state.map_selector} pos=({state.x:.1f},{state.z:.1f})> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if command in {"q", "quit", "exit"}:
            return 0
        if command == "s":
            raw = C.create_string_buffer(32)
            status = lib.dc_game_player_save(C.byref(state), raw, 32)
            if status == 0:
                save_dir.mkdir(parents=True, exist_ok=True)
                save_path.write_bytes(raw.raw)
                print(f"saved {save_path}")
            else:
                print(f"save failed: {status}")
            continue
        if command == "l":
            if not save_path.is_file():
                print("no save available")
                continue
            raw = C.create_string_buffer(save_path.read_bytes()[:32], 32)
            restored = GamePlayer()
            status = lib.dc_game_player_load(raw, 32, C.byref(restored))
            if status == 0:
                restored.min_x, restored.max_x = state.min_x, state.max_x
                restored.min_z, restored.max_z = state.min_z, state.max_z
                state = restored
                print("loaded")
            else:
                print(f"load failed: {status}")
            continue
        if command.startswith("m "):
            try:
                dx, dz = (float(x) for x in command.split()[1:3])
            except (ValueError, IndexError):
                print("usage: m dx dz")
                continue
            moved = GamePlayer()
            status = lib.dc_game_player_step(C.byref(state), C.byref(GameInput(dx, dz, 1)), .1, C.byref(moved))
            if status == 0:
                state = moved
            else:
                print(f"move failed: {status}")
            continue
        if command == "i":
            started = GameInteractionState()
            event = GameInteractionResult()
            status = lib.dc_game_interaction_step(C.byref(interaction), C.byref(GameInteractionInput(0, 1, 1)), C.byref(started), C.byref(event))
            if status != 0:
                print(f"interaction start failed: {status}")
                continue
            finished = GameInteractionState()
            status = lib.dc_game_interaction_step(C.byref(started), C.byref(GameInteractionInput(901, 0, 1)), C.byref(finished), C.byref(event))
            if status != 0:
                print(f"interaction finish failed: {status}")
                continue
            interaction = finished
            state.interaction_count = finished.interaction_count
            next_selector = C.c_uint32()
            terminal = C.c_uint32()
            lib.dc_game_next_map_selector(state.map_selector, C.byref(next_selector), C.byref(terminal))
            if terminal.value:
                print("chapter complete")
                continue
            admit(root, next_selector.value)
            state.map_selector = next_selector.value
            interaction = GameInteractionState(state.interaction_count, 0, 0, 0)
            print(f"map {state.map_selector} admitted")
            continue
        print("unknown command; use m dx dz | i | s | l | q")


if __name__ == "__main__":
    raise SystemExit(main())
