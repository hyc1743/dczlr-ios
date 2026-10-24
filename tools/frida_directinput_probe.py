"""Run a bounded local DirectInput probe against the supplied PE32 title."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import frida


ROOT = Path(__file__).resolve().parents[1]
AGENT = Path(__file__).with_name("frida_directinput_agent.js")
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
BM_CLICK = 0x00F5
START_BUTTON_ID = 1012


class WindowApi:
    HWND = ctypes.c_void_p
    LPARAM = ctypes.c_ssize_t
    BOOL = ctypes.c_int
    DWORD = ctypes.c_uint32
    WNDENUMPROC = ctypes.WINFUNCTYPE(BOOL, HWND, LPARAM)

    def __init__(self) -> None:
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.user32.EnumWindows.argtypes = [self.WNDENUMPROC, self.LPARAM]
        self.user32.EnumWindows.restype = self.BOOL
        self.user32.GetWindowThreadProcessId.argtypes = [self.HWND, ctypes.POINTER(self.DWORD)]
        self.user32.GetWindowThreadProcessId.restype = self.DWORD
        self.user32.GetWindowTextW.argtypes = [self.HWND, ctypes.c_wchar_p, ctypes.c_int]
        self.user32.GetWindowTextW.restype = ctypes.c_int
        self.user32.GetDlgItem.argtypes = [self.HWND, ctypes.c_int]
        self.user32.GetDlgItem.restype = self.HWND
        self.user32.SendMessageW.argtypes = [self.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
        self.user32.SendMessageW.restype = ctypes.c_ssize_t
        self.user32.SetForegroundWindow.argtypes = [self.HWND]
        self.user32.SetForegroundWindow.restype = self.BOOL
        self.user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
        self.user32.SetCursorPos.restype = self.BOOL
        class Rect(ctypes.Structure):
            _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                        ("right", ctypes.c_long), ("bottom", ctypes.c_long)]
        self.Rect = Rect
        self.user32.GetClientRect.argtypes = [self.HWND, ctypes.POINTER(self.Rect)]
        self.user32.GetClientRect.restype = self.BOOL
        self.user32.ClientToScreen.argtypes = [self.HWND, ctypes.POINTER(self.Rect)]
        self.user32.ClientToScreen.restype = self.BOOL

    def windows_for_pid(self, pid: int) -> list[int]:
        found: list[int] = []

        @self.WNDENUMPROC
        def callback(hwnd, _lparam):
            owner = self.DWORD()
            self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value == pid:
                found.append(int(hwnd))
            return 1

        self.user32.EnumWindows(callback, 0)
        return found

    def click_start(self, pid: int) -> int | None:
        for hwnd in self.windows_for_pid(pid):
            button = self.user32.GetDlgItem(self.HWND(hwnd), START_BUTTON_ID)
            if button:
                self.user32.SendMessageW(button, BM_CLICK, 0, 0)
                return int(button)
        return None

    def focus_and_move_client(self, pid: int, x: int, y: int) -> int | None:
        for hwnd in self.windows_for_pid(pid):
            self.user32.SetForegroundWindow(self.HWND(hwnd))
            point = self.Rect(x, y, 0, 0)
            if self.user32.ClientToScreen(self.HWND(hwnd), ctypes.byref(point)):
                if self.user32.SetCursorPos(point.left, point.top):
                    return int(hwnd)
        return None


def parse_press(value: str) -> dict:
    parts = value.split(":")
    if len(parts) not in (3, 4):
        raise argparse.ArgumentTypeError("press must be AT:CODE:DURATION[:LABEL]")
    try:
        at = float(parts[0])
        code = int(parts[1], 0)
        duration = float(parts[2])
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if at < 0 or code < 0 or duration <= 0:
        raise argparse.ArgumentTypeError("press values must be non-negative and duration > 0")
    return {"kind": "keyboard", "at": at, "code": code, "duration": duration,
            "label": parts[3] if len(parts) == 4 else ""}


def parse_mouse(value: str) -> dict:
    parts = value.split(":")
    if len(parts) not in (3, 4, 5, 6):
        raise argparse.ArgumentTypeError("mouse must be AT:BUTTON:DURATION[:DX:DY[:LABEL]]")
    try:
        at = float(parts[0])
        button = int(parts[1], 0)
        duration = float(parts[2])
        dx = int(parts[3], 0) if len(parts) >= 4 else 0
        dy = int(parts[4], 0) if len(parts) >= 5 else 0
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if at < 0 or button < 0 or button > 3 or duration <= 0:
        raise argparse.ArgumentTypeError("invalid mouse pulse")
    return {"kind": "mouse", "at": at, "button": button, "duration": duration,
            "dx": dx, "dy": dy, "label": parts[5] if len(parts) == 6 else ""}


def parse_cursor(value: str) -> dict:
    parts = value.split(":")
    if len(parts) not in (3, 4):
        raise argparse.ArgumentTypeError("cursor must be AT:X:Y[:LABEL]")
    try:
        at = float(parts[0])
        x = int(parts[1], 0)
        y = int(parts[2], 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if at < 0:
        raise argparse.ArgumentTypeError("cursor time must be non-negative")
    return {"at": at, "x": x, "y": y, "label": parts[3] if len(parts) == 4 else ""}


def parse_force_menu(value: str) -> dict:
    parts = value.split(":")
    if len(parts) not in (2, 3, 4):
        raise argparse.ArgumentTypeError("force-menu must be X:Y[:INPUT[:FRAMES]]")
    try:
        x = int(parts[0], 0)
        y = int(parts[1], 0)
        input_code = int(parts[2], 0) if len(parts) == 3 else 3
        frames = int(parts[3], 0) if len(parts) == 4 else 5
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if input_code < 0 or input_code > 255:
        raise argparse.ArgumentTypeError("force-menu input must be 0..255")
    if frames <= 0:
        raise argparse.ArgumentTypeError("force-menu frames must be > 0")
    return {"x": x, "y": y, "input": input_code, "frames": frames}


def parse_force_chapter(value: str) -> dict:
    parts = value.split(":")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("force-chapter must be AT:CHAPTER")
    try:
        at = float(parts[0])
        chapter = int(parts[1], 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if at < 0 or chapter < 0 or chapter > 255:
        raise argparse.ArgumentTypeError("force-chapter values are out of range")
    return {"at": at, "chapter": chapter}


def parse_force_actions(value: str) -> dict:
    parts = value.split(":")
    if len(parts) not in (1, 2):
        raise argparse.ArgumentTypeError("force-actions must be AT[:FRAMES]")
    try:
        at = float(parts[0])
        frames = int(parts[1], 0) if len(parts) == 2 else 3
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if at < 0 or frames <= 0:
        raise argparse.ArgumentTypeError("force-actions values are out of range")
    return {"at": at, "frames": frames}


def parse_force_dispatch(value: str) -> dict:
    parts = value.split(":")
    if len(parts) not in (1, 2):
        raise argparse.ArgumentTypeError("force-dispatch must be AT[:FRAMES]")
    try:
        at = float(parts[0])
        frames = int(parts[1], 0) if len(parts) == 2 else 3
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if at < 0 or frames <= 0:
        raise argparse.ArgumentTypeError("force-dispatch values are out of range")
    return {"at": at, "frames": frames}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=ROOT / "tmp" / "directx" / "gameprobe.exe")
    parser.add_argument("--duration", type=float, default=35.0)
    parser.add_argument("--start-after", type=float, default=5.0)
    parser.add_argument("--press", action="append", type=parse_press, default=[])
    parser.add_argument("--mouse", action="append", type=parse_mouse, default=[])
    parser.add_argument("--cursor", action="append", type=parse_cursor, default=[])
    parser.add_argument("--force-menu", type=parse_force_menu)
    parser.add_argument("--force-chapter", type=parse_force_chapter)
    parser.add_argument("--force-actions", type=parse_force_actions)
    parser.add_argument("--force-dispatch", type=parse_force_dispatch)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if os.name != "nt":
        parser.error("this probe requires Windows")
    exe = args.exe.resolve()
    if not exe.is_file():
        parser.error(f"missing executable: {exe}")
    if args.duration <= 0 or args.start_after < 0:
        parser.error("duration must be > 0 and start-after must be >= 0")
    presses = args.press + args.mouse
    agent_template = AGENT.read_text(encoding="utf-8")
    agent_source = agent_template.replace("__PRESSES__", json.dumps(presses, separators=(",", ":")))
    agent_source = agent_source.replace("__FORCE_MENU__", json.dumps(args.force_menu, separators=(",", ":")))
    agent_source = agent_source.replace("__FORCE_CHAPTER__", json.dumps(args.force_chapter, separators=(",", ":")))
    agent_source = agent_source.replace("__FORCE_ACTIONS__", json.dumps(args.force_actions, separators=(",", ":")))
    agent_source = agent_source.replace("__FORCE_DISPATCH__", json.dumps(args.force_dispatch, separators=(",", ":")))

    os.chdir(ROOT)
    device = frida.get_local_device()
    pid = device.spawn([str(exe)])
    session = device.attach(pid)
    messages: list[dict] = []

    def on_message(message, _data):
        if message.get("type") == "send":
            payload = message.get("payload")
            if isinstance(payload, dict):
                messages.append(payload)
        elif message.get("type") == "error":
            messages.append({"kind": "frida_error", "description": message.get("description", "")})

    script = session.create_script(agent_source)
    script.on("message", on_message)
    script.load()
    device.resume(pid)
    api = WindowApi()
    start_clicked = None
    cursor_done = [False] * len(args.cursor)
    deadline = time.monotonic() + args.duration
    try:
        while time.monotonic() < deadline:
            elapsed = args.duration - max(0.0, deadline - time.monotonic())
            if start_clicked is None and elapsed >= args.start_after:
                start_clicked = api.click_start(pid)
                if start_clicked is not None:
                    messages.append({"time": round(elapsed, 3), "kind": "host_start_click",
                                     "button": START_BUTTON_ID, "handle": hex(start_clicked)})
            for index, cursor in enumerate(args.cursor):
                if not cursor_done[index] and elapsed >= cursor["at"]:
                    hwnd = api.focus_and_move_client(pid, cursor["x"], cursor["y"])
                    cursor_done[index] = True
                    messages.append({"time": round(elapsed, 3), "kind": "host_cursor_move",
                                     "x": cursor["x"], "y": cursor["y"],
                                     "label": cursor.get("label", ""),
                                     "window": hex(hwnd) if hwnd else None})
            time.sleep(0.05)
    finally:
        try:
            session.detach()
        except frida.InvalidOperationError:
            pass
        try:
            os.kill(pid, 9)
        except OSError:
            pass

    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = {
        "schema": 1,
        "method": "Frida COM vtable GetDeviceState buffer injection plus ReadFile correlation",
        "executable": str(exe),
        "duration_seconds": round(args.duration, 3),
        "start_after_seconds": args.start_after,
        "presses": presses,
        "force_menu": args.force_menu,
        "force_chapter": args.force_chapter,
        "force_actions": args.force_actions,
        "force_dispatch": args.force_dispatch,
        "process_interaction": "startup dialog BM_CLICK plus bounded DirectInput buffer probe",
        "start_clicked": start_clicked is not None,
        "events": messages,
    }
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "output": str(args.output),
        "start_clicked": result["start_clicked"],
        "events": len(messages),
        "injected": sum(len(e.get("injected", [])) for e in messages if e.get("kind") == "GetDeviceState"),
        "pp_reads": sum(1 for e in messages if e.get("kind") == "read"),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
