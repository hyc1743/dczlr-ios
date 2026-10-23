"""Launch the self-authored sprite integration scene on an iOS simulator."""
import argparse
import json
import plistlib
import re
from pathlib import Path
import subprocess
import time


SCENES = {"checker": "self-authored checker sprite", "startup": "original startup-card sprite",
          "title": "original title-screen background and menu layers"}


def presented_scenes(log):
    # LabModel prefixes every app-authored record with its timestamp. Require
    # the exact marker at the start of that message, not an echoed command or
    # prose saying an asset was merely loaded.
    return re.findall(r"(?m)^\S+ PORTLAB_SCENE_PRESENTED=(checker|startup|title)(?= |$)", log)


def animation_advanced(log):
    return bool(re.search(r"(?m)^\S+ PORTLAB_NATIVE_ANIMATION_ADVANCED(?= |$)", log))


def xa_fixture_loaded(log):
    return bool(re.search(r"(?m)^\S+ PORTLAB_NATIVE_XA_FIXTURE_LOADED(?= |$)", log))


def material_advanced(log):
    return bool(re.search(r"(?m)^\S+ PORTLAB_NATIVE_MATERIAL_ADVANCED(?= |$)", log))


def xx_fixture_loaded(log):
    return bool(re.search(r"(?m)^\S+ PORTLAB_NATIVE_XX_FIXTURE_LOADED(?= |$)", log))


def pose_advanced(log):
    return bool(re.search(r"(?m)^\S+ PORTLAB_NATIVE_POSE_ADVANCED(?= |$)", log))


def scene_ready(log, expected, require_animation=False, require_xa=False, require_material=False, require_xx=False, require_pose=False):
    return (expected in presented_scenes(log) and (not require_animation or animation_advanced(log))
            and (not require_xa or xa_fixture_loaded(log)) and (not require_material or material_advanced(log))
            and (not require_xx or xx_fixture_loaded(log)) and (not require_pose or pose_advanced(log)))


def scene_evidence(log, expected, require_animation=False, require_xa=False, require_material=False, require_xx=False, require_pose=False):
    if expected not in SCENES:
        raise ValueError("Unknown expected scene: " + expected)
    observed = presented_scenes(log)
    if not scene_ready(log, expected, require_animation, require_xa, require_material, require_xx, require_pose):
        raise ValueError("Expected scene/animation/XA/material/XX/pose pipeline was not reported: " + expected)
    return {"scene": SCENES[expected], "required_scene": expected, "observed_scenes": observed,
            "resource_content": "not inspected by this presentation check",
            "native_animation_tick": "positive-delta advancement and presentation reported" if animation_advanced(log) else "not verified by this log",
            "native_xa_fixture": "self-authored XA decode and animation pipeline reported" if xa_fixture_loaded(log) else "not verified by this log",
            "native_material_sampling": "changed alpha sample and presentation reported" if material_advanced(log) else "not verified by this log",
            "native_xx_fixture": "self-authored XX embedded texture and XA material binding presented" if xx_fixture_loaded(log) else "not verified by this log",
            "native_pose_sampling": "changed self-authored XA node transform and presentation reported" if pose_advanced(log) else "not verified by this log",
            "vulkan_first_present": "reported_by_native_view_after_successful_present",
            "physical_iphone": "not tested", "game_playability": "not verified"}


def run(*command, timeout=120):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed: {(result.stdout + result.stderr)[-4000:]}")
    return result.stdout.strip()


def select_device(output, runtime):
    output.mkdir(parents=True, exist_ok=True)
    inventory = run("xcrun", "simctl", "list", "devices", "available", "--json")
    (output / "simulators.json").write_text(inventory + "\n", encoding="utf-8")
    devices = json.loads(inventory)["devices"]
    phones = [{**device, "runtime": key} for key, entries in devices.items()
              if not runtime or key.endswith(runtime)
              for device in entries if device["name"].startswith("iPhone")]
    if not phones:
        raise ValueError("No available iPhone simulator for runtime " + str(runtime))
    phone = next((device for device in phones if device["state"] == "Booted"), phones[0])
    if phone["state"] != "Booted":
        run("xcrun", "simctl", "boot", phone["udid"])
    return phone


def check(app, output, runtime, expected_scene="checker"):
    require_animation = expected_scene == "checker"
    require_xa = expected_scene == "checker"
    require_material = expected_scene == "checker"
    require_xx = expected_scene == "checker"
    require_pose = expected_scene == "checker"
    app = app.resolve(strict=True)
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (app / "Resources").exists() or (app / "Contents").exists():
        raise ValueError("iOS flat bundle contains a reserved macOS-style directory")
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "org.example.portlab" or not info.get("CFBundleExecutable"):
        raise ValueError("App is missing expected bundle identity/executable metadata")
    (output / "bundle.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    if not (app / info["CFBundleExecutable"]).is_file():
        raise ValueError("App bundle executable is missing")
    # The CI build intentionally disables developer signing. Simulator installs
    # use a local ad-hoc signature; no Apple identity or device provisioning.
    for binary in sorted(app.rglob("*.dylib")):
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(binary))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", str(app))
    run("codesign", "--verify", "--strict", str(app))
    phone = select_device(output, runtime)
    device = phone["udid"]
    run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
    run("xcrun", "simctl", "install", device, str(app))
    # Resolve the app container before launch. A graphics-service crash can
    # wedge subsequent simctl queries, but the Documents path remains usable.
    container = None
    try:
        container = Path(run("xcrun", "simctl", "get_app_container", device,
            "org.example.portlab", "data", timeout=30))
        (output / "container.txt").write_text(str(container) + "\n", encoding="utf-8")
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        (output / "container-error.txt").write_text(str(error), encoding="utf-8")
    try:
        launch_process = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
            device, "org.example.portlab"], capture_output=True, text=True, timeout=60)
        launch = launch_process.stdout + launch_process.stderr
        launch_timed_out = launch_process.returncode != 0
    except subprocess.TimeoutExpired as error:
        launch_timed_out = True
        launch = "launch timed out after 60s; stdout=" + str(error.stdout)[-1000:] + "; stderr=" + str(error.stderr)[-1000:]
    (output / "launch.txt").write_text(launch + "\n", encoding="utf-8")
    deadline = time.monotonic() + 60
    log = ""
    while time.monotonic() < deadline:
        path = container / "Documents/log.txt" if container else None
        if path and path.exists():
            log = path.read_text(encoding="utf-8")
            if scene_ready(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose) or "Vulkan 初始化或绘制失败" in log:
                break
        time.sleep(1)
    (output / "app.log").write_text(log, encoding="utf-8")
    try:
        unified = subprocess.run(["xcrun", "simctl", "spawn", device, "log", "show", "--last", "3m",
            "--style", "compact", "--predicate", 'process == "PortLab" OR process == "SpringBoard" OR eventMessage CONTAINS[c] "PortLab"'],
            capture_output=True, text=True, timeout=30)
        unified_code, unified_log = unified.returncode, unified.stdout + unified.stderr
    except subprocess.TimeoutExpired as error:
        unified_code, unified_log = -1, str(error)
    (output / "unified.log").write_text(unified_log, encoding="utf-8")
    container_logs = container / "Library/Logs" if container else None
    crash_dir = output / "app-crashes"
    crash_dir.mkdir(exist_ok=True)
    if container_logs and container_logs.exists():
        import shutil
        for crash in container_logs.rglob("*.ips"):
            shutil.copyfile(crash, crash_dir / crash.name)
    diagnostic_reports = Path.home() / "Library/Logs/DiagnosticReports"
    if diagnostic_reports.exists():
        import shutil
        for pattern in ("*PortLab*.ips", "*SimMetalHost*.ips"):
            for crash in diagnostic_reports.glob(pattern):
                shutil.copyfile(crash, crash_dir / crash.name)
    try:
        screenshot = subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(output / "sprite-scene.png")],
            capture_output=True, text=True, timeout=30)
        screenshot_log = screenshot.stdout + screenshot.stderr
    except subprocess.TimeoutExpired as error:
        screenshot_log = str(error)
    (output / "screenshot-command.txt").write_text(screenshot_log, encoding="utf-8")
    if not scene_ready(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose):
        try:
            process = subprocess.run(["xcrun", "simctl", "spawn", device, "launchctl", "list"],
                capture_output=True, text=True, timeout=30)
            process_log = process.stdout + process.stderr
        except subprocess.TimeoutExpired as error:
            process_log = str(error)
        (output / "processes.log").write_text(process_log, encoding="utf-8")
        if unified_code:
            raise RuntimeError("Simulator did not report a Vulkan frame; unified log query failed: " + unified_log[-1500:])
        raise RuntimeError("Simulator did not report a submitted Vulkan sprite frame; launch_timed_out=" +
            str(launch_timed_out) + "; launch=" + launch[-1000:] + "; log=" + log[-2000:])
    report = {"simulator": phone["name"], "runtime": phone["runtime"], "udid": device,
              **scene_evidence(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose)}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    run("xcrun", "simctl", "terminate", device, "org.example.portlab")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime")
    parser.add_argument("--expected-scene", choices=SCENES, default="checker")
    parser.add_argument("--boot-only", action="store_true")
    args = parser.parse_args()
    if args.boot_only:
        print(json.dumps(select_device(args.output, args.runtime)))
    elif args.app:
        check(args.app, args.output, args.runtime, args.expected_scene)
    else:
        parser.error("--app is required unless --boot-only is selected")
