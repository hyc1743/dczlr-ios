"""Execute Wine's cmd.exe through the actual interpreter, with a hard deadline.

Only a complete guest-output line counts as the marker. Logging the command
line or compiling the host cannot satisfy this test. No game input is used.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time

MARKER = "PORTLAB_WINE32_OK"
WIN32_MARKER = "PORTLAB_WIN32_OK"
SUBSYSTEM_MARKERS = {
    "PORTLAB_FILE_OK": "file_roundtrip",
    "PORTLAB_THREAD_OK": "thread_event_join",
    "PORTLAB_GDI_PIXELS_OK": "offscreen_gdi_pixel_readback",
    "PORTLAB_WAVE_BUFFER_OK": "waveout_buffer_completion",
}


def clean_guest_line(line):
    return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", line).strip()


def run(host, rootfs, output, seconds, guest_exe=None):
    if sys.platform != "darwin":
        raise ValueError("This probe runs on the macOS build runner")
    import pty
    output.mkdir(parents=True, exist_ok=True)
    prefix = output / "prefix"
    prefix.mkdir(exist_ok=True)
    args = [str(host.resolve()), "-root", str(prefix.resolve()), "-zip", str(rootfs.resolve()),
            "-nozip", "-novideo", "-env", "WINEDEBUG=err+all,warn+all,+seh",
            "-env", "WINEDLLOVERRIDES=mscoree,mshtml=;winemenubuilder.exe=d",
            ]
    expected = WIN32_MARKER if guest_exe else MARKER
    if guest_exe:
        guest_exe = guest_exe.resolve(strict=True)
        args += ["-mount", str(guest_exe.parent), "/mnt/portlab-probe",
                 "-w", "/mnt/portlab-probe",
                 "/bin/wine", "/mnt/portlab-probe/" + guest_exe.name]
    else:
        args += ["-nosound", "/bin/wine", "cmd.exe", "/d", "/c", "echo", MARKER]
    master, slave = pty.openpty()
    process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                               env=dict(os.environ, SDL_AUDIODRIVER="dummy", TERM="dumb"),
                               start_new_session=True)
    os.close(slave)
    lines = queue.Queue()

    def read_output():
        try:
            with os.fdopen(master, "r", encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    lines.put(line)
        except OSError:
            pass
        finally:
            lines.put(None)

    threading.Thread(target=read_output, daemon=True).start()
    started = time.monotonic()
    observed = False
    natural_exit = False
    output_limit = False
    logged_bytes = 0
    subsystem_results = {name: False for name in SUBSYSTEM_MARKERS.values()}
    try:
        with (output / "wine-console.log").open("w", encoding="utf-8") as log:
            while time.monotonic() - started < seconds:
                try:
                    line = lines.get(timeout=1)
                except queue.Empty:
                    if process.poll() is not None:
                        break
                    continue
                if line is None:
                    break
                logged_bytes += len(line.encode("utf-8"))
                if logged_bytes > 16 * 1024 * 1024:
                    log.write("OUTPUT_LIMIT_REACHED\n")
                    output_limit = True
                    break
                log.write(line)
                log.flush()
                clean = clean_guest_line(line)
                if clean in SUBSYSTEM_MARKERS:
                    subsystem_results[SUBSYSTEM_MARKERS[clean]] = True
                if clean == expected and (not guest_exe or all(subsystem_results.values())):
                    observed = True
                    break
            if observed:
                try:
                    process.wait(timeout=5)
                    natural_exit = True
                except subprocess.TimeoutExpired:
                    pass
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    report = {
        "probe": ("Self-authored Win32 PE32 under the actual no-JIT x86 interpreter"
                  if guest_exe else "Wine cmd.exe under the actual no-JIT x86 interpreter"),
        "guest_output_marker_observed": observed,
        "elapsed_seconds": round(time.monotonic() - started, 2),
        "host_shutdown": "returned_normally" if natural_exit else "stopped_by_bounded_harness",
        "host_exit_code": process.returncode,
        "boot_profile": "console only; optional HTML/.NET installers disabled",
        "diagnostic_output_limit_reached": output_limit,
        "subsystem_markers": subsystem_results,
        "graphics": "offscreen GDI only" if subsystem_results["offscreen_gdi_pixel_readback"] else "not_tested",
        "audio": "dummy SDL device; buffer completion only" if subsystem_results["waveout_buffer_completion"] else "not_tested",
        "onscreen_presentation": "not_tested", "d3d9": "not_tested",
        "ios_execution": "not_tested", "game_playability": "not_verified",
    }
    (output / "wine-boot-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    if not observed:
        raise SystemExit("Wine did not produce the required guest output marker")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", type=Path)
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=240)
    parser.add_argument("--guest-exe", type=Path,
                        help="Self-authored Win32 smoke probe; uses a separate scratch prefix")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 600:
        parser.error("--seconds must be between 1 and 600")
    run(args.host, args.rootfs, args.output, args.seconds, args.guest_exe)
