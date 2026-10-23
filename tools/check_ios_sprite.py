"""Launch the self-authored sprite integration scene on an iOS simulator."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def run(*command, timeout=120):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed: {(result.stdout + result.stderr)[-4000:]}")
    return result.stdout.strip()


def check(app, output):
    output.mkdir(parents=True, exist_ok=True)
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    phones = [device for entries in devices.values() for device in entries if device["name"].startswith("iPhone")]
    if not phones:
        raise ValueError("No available iPhone simulator")
    phone = next((device for device in phones if device["state"] == "Booted"), phones[0])
    device = phone["udid"]
    if phone["state"] != "Booted":
        run("xcrun", "simctl", "boot", device)
    run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
    run("xcrun", "simctl", "install", device, str(app))
    run("xcrun", "simctl", "launch", "--terminate-running-process", device, "org.example.portlab")
    container = Path(run("xcrun", "simctl", "get_app_container", device, "org.example.portlab", "data"))
    deadline = time.monotonic() + 60
    log = ""
    marker = "Vulkan / MoltenVK 已提交精灵首帧"
    while time.monotonic() < deadline:
        path = container / "Documents/log.txt"
        if path.exists():
            log = path.read_text(encoding="utf-8")
            if marker in log or "Vulkan 初始化或绘制失败" in log:
                break
        time.sleep(1)
    (output / "app.log").write_text(log, encoding="utf-8")
    run("xcrun", "simctl", "io", device, "screenshot", str(output / "sprite-scene.png"))
    if marker not in log:
        raise RuntimeError("Simulator did not report a submitted Vulkan sprite frame: " + log[-2000:])
    report = {"simulator": phone["name"], "udid": device, "scene": "self-authored checker sprite",
              "vulkan_first_present": "reported_by_native_view_after_successful_present",
              "physical_iphone": "not tested", "game_playability": "not verified"}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    run("xcrun", "simctl", "terminate", device, "org.example.portlab")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    check(args.app, args.output)
