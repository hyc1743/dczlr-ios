"""Launch the self-authored sprite integration scene on an iOS simulator."""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import time


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


def check(app, output, runtime):
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
    try:
        launch_process = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
            device, "org.example.portlab"], capture_output=True, text=True, timeout=60)
        launch = launch_process.stdout + launch_process.stderr
        launch_timed_out = launch_process.returncode != 0
    except subprocess.TimeoutExpired as error:
        launch_timed_out = True
        launch = "launch timed out after 60s; stdout=" + str(error.stdout)[-1000:] + "; stderr=" + str(error.stderr)[-1000:]
    (output / "launch.txt").write_text(launch + "\n", encoding="utf-8")
    container = Path(run("xcrun", "simctl", "get_app_container", device, "org.example.portlab", "data"))
    deadline = time.monotonic() + 60
    log = ""
    markers = ("Vulkan / MoltenVK 已显示原始 illusion.ema 首屏",
               "Vulkan / MoltenVK 已显示自制检查精灵")
    while time.monotonic() < deadline:
        path = container / "Documents/log.txt"
        if path.exists():
            log = path.read_text(encoding="utf-8")
            if any(marker in log for marker in markers) or "Vulkan 初始化或绘制失败" in log:
                break
        time.sleep(1)
    (output / "app.log").write_text(log, encoding="utf-8")
    unified = subprocess.run(["xcrun", "simctl", "spawn", device, "log", "show", "--last", "3m",
        "--style", "compact", "--predicate", 'process == "PortLab" OR process == "SpringBoard" OR eventMessage CONTAINS[c] "PortLab"'],
        capture_output=True, text=True, timeout=60)
    (output / "unified.log").write_text(unified.stdout + unified.stderr, encoding="utf-8")
    container_logs = Path(run("xcrun", "simctl", "get_app_container", device,
        "org.example.portlab", "data")) / "Library/Logs"
    crash_dir = output / "app-crashes"
    crash_dir.mkdir(exist_ok=True)
    if container_logs.exists():
        import shutil
        for crash in container_logs.rglob("*.ips"):
            shutil.copyfile(crash, crash_dir / crash.name)
    diagnostic_reports = Path.home() / "Library/Logs/DiagnosticReports"
    if diagnostic_reports.exists():
        import shutil
        for crash in diagnostic_reports.glob("*PortLab*.ips"):
            shutil.copyfile(crash, crash_dir / crash.name)
    run("xcrun", "simctl", "io", device, "screenshot", str(output / "sprite-scene.png"))
    if not any(marker in log for marker in markers):
        process = subprocess.run(["xcrun", "simctl", "spawn", device, "launchctl", "list"],
            capture_output=True, text=True, timeout=30)
        (output / "processes.log").write_text(process.stdout + process.stderr, encoding="utf-8")
        if unified.returncode:
            raise RuntimeError("Simulator did not report a Vulkan frame; unified log query failed: " + unified.stderr[-1500:])
        raise RuntimeError("Simulator did not report a submitted Vulkan sprite frame; launch_timed_out=" +
            str(launch_timed_out) + "; launch=" + launch[-1000:] + "; log=" + log[-2000:])
    original_card = markers[0] in log
    report = {"simulator": phone["name"], "runtime": phone["runtime"], "udid": device,
              "scene": "original illusion.ema startup card" if original_card else "self-authored checker sprite",
              "original_game_assets_in_app": False,
              "vulkan_first_present": "reported_by_native_view_after_successful_present",
              "physical_iphone": "not tested", "game_playability": "not verified"}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    run("xcrun", "simctl", "terminate", device, "org.example.portlab")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime")
    parser.add_argument("--boot-only", action="store_true")
    args = parser.parse_args()
    if args.boot_only:
        print(json.dumps(select_device(args.output, args.runtime)))
    elif args.app:
        check(args.app, args.output, args.runtime)
    else:
        parser.error("--app is required unless --boot-only is selected")
