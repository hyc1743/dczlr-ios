"""Launch the self-authored sprite integration scene on an iOS simulator."""
import argparse
import json
import plistlib
import re
from pathlib import Path
import subprocess
import time
import os


SCENES = {"checker": "self-authored checker sprite", "startup": "first startup-card sprite", "warning": "second startup-card sprite",
          "title": "title-screen background and menu layers", "intro": "first new-game script record and text adapter"}


def presented_scenes(log):
    # LabModel prefixes every app-authored record with its timestamp. Require
    # the exact marker at the start of that message, not an echoed command or
    # prose saying an asset was merely loaded.
    return re.findall(r"(?m)^\S+ PORTLAB_SCENE_PRESENTED=(checker|startup|warning|title|intro)(?= |$)", log)


def startup_evidence(log,require_audio=False):
    from datetime import datetime
    events=re.findall(r'(?m)^(\S+) PORTLAB_SCENE_PRESENTED=(startup|warning|title)(?= |$)',log)
    if [scene for _,scene in events]!=['startup','warning','title']:
        raise ValueError('Both startup cards and title must be presented in order')
    if not re.search(r'(?m)^\S+ PORTLAB_STARTUP_COMPLETED(?= |$)',log):
        raise ValueError('Startup action completion was not reported')
    if not re.search(r'(?m)^\S+ PORTLAB_STARTUP_TRANSITION_PRESENTED(?= |$)',log):
        raise ValueError('Transition geometry presentation was not reported')
    if require_audio and not re.search(r'(?m)^\S+ PORTLAB_TITLE_AUDIO_ADVANCED(?= |$)',log):
        raise ValueError('Title audio playback clock advancement was not reported')
    times=[datetime.fromisoformat(t.replace('Z','+00:00')) for t,_ in events]
    first=(times[1]-times[0]).total_seconds();second=(times[2]-times[1]).total_seconds()
    if first<2 or second<30:
        raise ValueError('Normal two-card hold times were not observed')
    return {'startup_flow':'both stable cards, transition geometry and title presented in order',
            'first_to_second_seconds':first,'second_to_title_seconds':second,
            'title_audio':'playback clock advanced; audible output unverified' if require_audio else 'not required by this profile',
            'original_resources':'not exercised; generated fixtures only','game_playability':'not verified'}


def new_game_evidence(log):
    if presented_scenes(log)!=['startup','warning','title','intro'] or not re.search(r'(?m)^\S+ PORTLAB_INTRO_AUDIO_ADVANCED(?= |$)',log):
        raise ValueError('New-game route or intro audio clocks were not verified')
    records=re.findall(r'(?m)^\S+ PORTLAB_INTRO_RECORD=(\d+:\d+)(?= |$)',log)
    if records!=['0:0','0:1','0:2','1:0'] or not re.search(r'(?m)^\S+ PORTLAB_TEXT_FADE_ADVANCED(?= |$)',log):
        raise ValueError('Original text state advancement and first chapter reload were not verified')
    return {'route':'startup/title pointer hover, press, release/transition and sound wait/intro',
        'resources':'self-authored generated PP/script/image/audio only','intro_audio_clocks':'music/sound/voice advanced',
        'records':records,'text_adapter':'original numeric byte-pair layout/fade/forward input; CP936 Apple font rasterization',
        'physical_device':'not tested','complete_game':'not verified'}


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


def check(app, output, runtime, expected_scene="checker", startup_fixture=False, exercise_new_game=False):
    if exercise_new_game and (not startup_fixture or expected_scene!='intro'):
        raise ValueError('New-game exercise requires generated startup fixture and intro target')
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
    if startup_fixture:
        if expected_scene not in ('title','intro') or container is None:
            raise ValueError('Startup fixture requires title target and resolved app container')
        from startup_fixture import install
        profile=install(container/'Documents/game/Data')
        (output/'fixture.json').write_text(json.dumps(profile,indent=2)+'\n',encoding='utf-8')
    try:
        launch_environment=dict(os.environ)
        if startup_fixture:launch_environment['SIMCTL_CHILD_PORTLAB_CAPTURE_STARTUP']='1'
        if exercise_new_game:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_NEW_GAME']='1'
        launch_process = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
            device, "org.example.portlab"], capture_output=True, text=True, timeout=60,env=launch_environment)
        launch = launch_process.stdout + launch_process.stderr
        launch_timed_out = launch_process.returncode != 0
    except subprocess.TimeoutExpired as error:
        launch_timed_out = True
        launch = "launch timed out after 60s; stdout=" + str(error.stdout)[-1000:] + "; stderr=" + str(error.stderr)[-1000:]
    (output / "launch.txt").write_text(launch + "\n", encoding="utf-8")
    deadline = time.monotonic() + (100 if startup_fixture else 60)
    log = ""
    captured=set()
    while time.monotonic() < deadline:
        path = container / "Documents/log.txt" if container else None
        if path and path.exists():
            log = path.read_text(encoding="utf-8")
            if startup_fixture:
                for scene in presented_scenes(log):
                    if scene not in captured:
                        run('xcrun','simctl','io',device,'screenshot',str(output/('startup-'+scene+'.png')),timeout=30)
                        captured.add(scene)
            scene_ok=scene_ready(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose)
            audio_ok=not startup_fixture or bool(re.search(r'(?m)^\S+ PORTLAB_TITLE_AUDIO_ADVANCED(?= |$)',log))
            if exercise_new_game:
                audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_INTRO_AUDIO_ADVANCED(?= |$)',log))
                audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_INTRO_RECORD=1:0(?= |$)',log))
            if (scene_ok and audio_ok) or "Vulkan 初始化或绘制失败" in log:
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
    if startup_fixture:
        report['startup_fixture']=startup_evidence(log,require_audio=True)
        if not {'startup','warning','title'}<=captured:raise ValueError('Missing startup stage screenshots')
        import shutil
        from startup_pixels import verify
        for index in range(2):
            name=f'startup-card-{index}.png'
            shutil.copyfile(container/'Documents'/name,output/name)
        report['startup_pixels']=verify((output/'startup-card-0.png').read_bytes(),(output/'startup-card-1.png').read_bytes())
    if exercise_new_game:
        report['new_game']=new_game_evidence(log)
        import shutil
        from startup_pixels import verify_intro
        shutil.copyfile(container/'Documents/intro-first-record.png',output/'intro-first-record.png')
        report['intro_pixels']=verify_intro((output/'intro-first-record.png').read_bytes())
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
    parser.add_argument("--startup-fixture", action="store_true")
    parser.add_argument("--exercise-new-game", action="store_true")
    args = parser.parse_args()
    if args.boot_only:
        print(json.dumps(select_device(args.output, args.runtime)))
    elif args.app:
        check(args.app, args.output, args.runtime, args.expected_scene,args.startup_fixture,args.exercise_new_game)
    else:
        parser.error("--app is required unless --boot-only is selected")
