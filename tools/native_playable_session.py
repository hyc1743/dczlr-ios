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


def entry(root: Path, name: str) -> bytes:
    with PPArchive(root / "RPP_10.pp") as archive:
        wanted = name.encode("ascii")
        for i in range(archive.count):
            if archive.entry(i).name_bytes.lower() == wanted.lower():
                return archive.read(i)
    raise ValueError(f"missing resource {name}")


def admit(root: Path, selector: int) -> None:
    data = entry(root, f"mm00_{selector:02d}.xx")
    if not data:
        raise RuntimeError(f"empty map {selector}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=ROOT / "Data")
    args = parser.parse_args()
    root = args.data.resolve()
    if not root.is_dir():
        parser.error(f"missing Data directory: {root}")
    lib = library()
    state = GamePlayer(0, 0, -100, 100, -100, 100, 8, 0, 0)
    interaction = GameInteractionState()
    print("native session ready; commands: m dx dz | i | s | l | q")
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
            print("saved" if status == 0 else f"save failed: {status}")
            continue
        if command == "l":
            raw = C.create_string_buffer(32)
            if lib.dc_game_player_save(C.byref(state), raw, 32) != 0:
                print("save failed")
                continue
            restored = GamePlayer()
            status = lib.dc_game_player_load(raw, 32, C.byref(restored))
            if status == 0:
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
