"""Launch the self-authored sprite integration scene on an iOS simulator."""
import argparse
import hashlib
import json
import plistlib
import re
from pathlib import Path
import subprocess
import time
import os
import shutil
import uuid


SCENES = {"checker": "self-authored checker sprite", "startup": "first startup-card sprite", "warning": "second startup-card sprite",
          "title": "title-screen background and menu layers", "intro": "first new-game script record and text adapter"}
GAMEPLAY_SCENES = {"gameplay": "chapter 3 map and actor scene", "gameComplete": "completed chapter 3 map sequence"}
SCENE_CHOICES = tuple(SCENES) + tuple(GAMEPLAY_SCENES)


def has_session(log,session):
    if not re.fullmatch(r'[0-9a-f]{32}',session):return False
    return bool(re.search(r'(?m)^\S+ PORTLAB_SESSION='+re.escape(session)+r'(?= |$)',log))


def presented_scenes(log):
    # LabModel prefixes every app-authored record with its timestamp. Require
    # the exact marker at the start of that message, not an echoed command or
    # prose saying an asset was merely loaded.
    return re.findall(r"(?m)^\S+ PORTLAB_SCENE_PRESENTED=(checker|startup|warning|title|intro)(?= |$)", log)


def startup_evidence(log,require_audio=False,require_skin=False):
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
    if require_skin and not re.search(r'(?m)^\S+ PORTLAB_NATIVE_SKIN_ADVANCED(?= |$)',log):
        raise ValueError('World-space skinned geometry change/presentation was not reported')
    times=[datetime.fromisoformat(t.replace('Z','+00:00')) for t,_ in events]
    first=(times[1]-times[0]).total_seconds();second=(times[2]-times[1]).total_seconds()
    if first<2 or second<30:
        raise ValueError('Normal two-card hold times were not observed')
    result={'startup_flow':'both stable cards, transition geometry and title presented in order',
            'first_to_second_seconds':first,'second_to_title_seconds':second,
            'title_audio':'playback clock advanced; audible output unverified' if require_audio else 'not required by this profile',
            'original_resources':'not exercised; generated fixtures only','game_playability':'not verified'}
    if require_skin:result['native_skin']='changed world-space skinned mesh and successful presentation reported'
    return result


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


def gameplay_scenes(log):
    return re.findall(r"(?m)^\S+ PORTLAB_SCENE_PRESENTED=(gameplay|gameComplete)(?= |$)", log)


def gameplay_evidence(log, require_complete=True, require_skin=True):
    scenes = gameplay_scenes(log)
    if not scenes or scenes[0] != "gameplay":
        raise ValueError("Chapter 3 gameplay scene was not presented")
    interactions = re.findall(r"(?m)^\S+ PORTLAB_GAME_INTERACTION_COMPLETED(?= |$)", log)
    if not interactions:
        raise ValueError("No completed gameplay interaction was reported")
    skin = bool(re.search(r"(?m)^\S+ PORTLAB_GAMEPLAY_SKIN_ADVANCED(?= |$)", log))
    if require_skin and not skin:
        raise ValueError("Real gameplay actor skinning was not reported")
    if require_complete and "gameComplete" not in scenes:
        raise ValueError("Terminal gameplay scene was not presented")
    return {
        "scenes": scenes,
        "completed_interactions": len(interactions),
        "gameplay": "chapter 3 scene presented and at least one interaction completed",
        "actor_skinning": "real actor skinning advanced and was presented" if skin else "not required",
        "complete_game": "terminal chapter 3 scene presented" if "gameComplete" in scenes else "not required",
        "physical_iphone": "not tested",
    }


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
    observed = gameplay_scenes(log) if expected in GAMEPLAY_SCENES else presented_scenes(log)
    return (expected in observed and (not require_animation or animation_advanced(log))
            and (not require_xa or xa_fixture_loaded(log)) and (not require_material or material_advanced(log))
            and (not require_xx or xx_fixture_loaded(log)) and (not require_pose or pose_advanced(log)))


def scene_evidence(log, expected, require_animation=False, require_xa=False, require_material=False, require_xx=False, require_pose=False):
    if expected not in SCENES and expected not in GAMEPLAY_SCENES:
        raise ValueError("Unknown expected scene: " + expected)
    observed = gameplay_scenes(log) if expected in GAMEPLAY_SCENES else presented_scenes(log)
    if not scene_ready(log, expected, require_animation, require_xa, require_material, require_xx, require_pose):
        raise ValueError("Expected scene/animation/XA/material/XX/pose pipeline was not reported: " + expected)
    if expected in GAMEPLAY_SCENES:
        return gameplay_evidence(log, require_complete=expected == "gameComplete", require_skin=True)
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


def stage_resource_parts(parts_root, container, output):
    """Copy verified local dczdata parts into the simulator Documents tree."""
    parts_root = Path(parts_root).resolve(strict=True)
    manifest_path = parts_root / "DczlrData.manifest.json"
    if not parts_root.is_dir() or not manifest_path.is_file():
        raise ValueError("resource-parts must contain DczlrData.manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    destination = container / "ResourcePacks"
    destination.mkdir(parents=True, exist_ok=True)
    staged = []
    for part in manifest.get("parts", []):
        source = parts_root / part["name"]
        if not source.is_file():
            raise ValueError("missing resource part: " + str(source))
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if digest != part.get("sha256") or source.stat().st_size != part.get("size"):
            raise ValueError("resource part checksum/size mismatch: " + source.name)
        shutil.copy2(source, destination / source.name)
        staged.append({"name": source.name, "size": source.stat().st_size, "sha256": digest})
    (output / "resource-staging.json").write_text(json.dumps({
        "source": str(parts_root), "destination": str(destination),
        "parts": staged, "manifest_total_bytes": manifest.get("total_bytes")
    }, indent=2) + "\n", encoding="utf-8")
    return staged


def check(app, output, runtime, expected_scene="checker", startup_fixture=False,
          exercise_new_game=False, resource_parts=None, exercise_real_gameplay=False):
    if exercise_new_game and (not startup_fixture and not resource_parts):
        raise ValueError('New-game exercise requires generated startup fixture or staged resource parts')
    if exercise_new_game and startup_fixture and expected_scene != 'intro':
        raise ValueError('Generated startup fixture new-game exercise requires intro target')
    if exercise_real_gameplay and (not resource_parts or expected_scene not in ('gameplay', 'gameComplete')):
        raise ValueError('Real gameplay exercise requires resource parts and gameplay target')
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
    if resource_parts:
        if container is None:
            raise ValueError('resource-parts requires a resolved simulator app container')
        stage_resource_parts(resource_parts, container, output)
    launch_environment=dict(os.environ)
    session=uuid.uuid4().hex
    launch_environment['SIMCTL_CHILD_PORTLAB_LAUNCH_ID']=session
    if startup_fixture:launch_environment['SIMCTL_CHILD_PORTLAB_CAPTURE_STARTUP']='1'
    if exercise_new_game:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_NEW_GAME']='1'
    if exercise_real_gameplay:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_REAL_GAMEPLAY']='1'
    # Cold CoreSimulator may queue the same request for over two minutes.
    # Observe that live command and app-authored evidence concurrently; never
    # issue another launch merely because an observation interval elapsed.
    launch_output=(output/'launch.txt').open('w',encoding='utf-8')
    launch_process=subprocess.Popen(['xcrun','simctl','launch','--terminate-running-process',device,'org.example.portlab'],
        stdout=launch_output,stderr=subprocess.STDOUT,text=True,env=launch_environment)
    wait_seconds=300 if startup_fixture else 240
    deadline = time.monotonic() + wait_seconds
    log = ""
    captured=set()
    while time.monotonic() < deadline:
        path = container / "Documents/log.txt" if container else None
        if path and path.exists():
            candidate=path.read_text(encoding='utf-8')
            if not has_session(candidate,session):
                time.sleep(1);continue
            log=candidate
            if startup_fixture:
                for scene in presented_scenes(log):
                    if scene not in captured:
                        run('xcrun','simctl','io',device,'screenshot',str(output/('startup-'+scene+'.png')),timeout=30)
                        captured.add(scene)
            scene_ok=scene_ready(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose)
            audio_ok=not startup_fixture or bool(re.search(r'(?m)^\S+ PORTLAB_TITLE_AUDIO_ADVANCED(?= |$)',log))
            if startup_fixture:audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_NATIVE_SKIN_ADVANCED(?= |$)',log))
            if exercise_new_game and startup_fixture:
                audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_INTRO_AUDIO_ADVANCED(?= |$)',log))
                audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_INTRO_RECORD=1:0(?= |$)',log))
            if (scene_ok and audio_ok) or "Vulkan 初始化或绘制失败" in log:
                break
        time.sleep(1)
    launch_pending=launch_process.poll() is None
    launch_returncode=launch_process.poll()
    if launch_pending:
        # This owns only the simctl request process. The app is left running
        # for evidence collection, then terminated explicitly at the end.
        launch_process.terminate()
        try:launch_process.wait(timeout=5)
        except subprocess.TimeoutExpired:launch_process.kill();launch_process.wait(timeout=5)
    launch_output.close()
    launch=(output/'launch.txt').read_text(encoding='utf-8')
    launch_timed_out=launch_pending or launch_returncode!=0
    launch_state={'pid':launch_process.pid,'pending_when_frame_poll_ended':launch_pending,
        'returncode_before_cleanup':launch_returncode,'frame_wait_seconds':wait_seconds,'single_launch_request':True,'session_id':session}
    (output/'launch-state.json').write_text(json.dumps(launch_state,indent=2)+'\n',encoding='utf-8')
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
    # Diagnostics can outlast a late cold launch. Re-read the same container's
    # evidence before classifying the outcome; a stale empty snapshot is not
    # proof that the app failed to start.
    path=container/'Documents/log.txt' if container else None
    if path and path.exists():
        candidate=path.read_text(encoding='utf-8')
        if has_session(candidate,session):log=candidate
        (output/'app.log').write_text(log,encoding='utf-8')
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
    report = {"simulator": phone["name"], "runtime": phone["runtime"], "udid": device,"launch_command":launch_state,
              **scene_evidence(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose)}
    if startup_fixture:
        report['startup_fixture']=startup_evidence(log,require_audio=True,require_skin=True)
        if not {'startup','warning','title'}<=captured:raise ValueError('Missing startup stage screenshots')
        import shutil
        from startup_pixels import verify
        for index in range(2):
            name=f'startup-card-{index}.png'
            shutil.copyfile(container/'Documents'/name,output/name)
        report['startup_pixels']=verify((output/'startup-card-0.png').read_bytes(),(output/'startup-card-1.png').read_bytes())
        from startup_pixels import verify_skin
        shutil.copyfile(container/'Documents/skinned-transition.png',output/'skinned-transition.png')
        report['skin_pixels']=verify_skin((output/'skinned-transition.png').read_bytes())
    if exercise_new_game and startup_fixture:
        report['new_game']=new_game_evidence(log)
        import shutil
        from startup_pixels import verify_intro
        shutil.copyfile(container/'Documents/intro-first-record.png',output/'intro-first-record.png')
        report['intro_pixels']=verify_intro((output/'intro-first-record.png').read_bytes())
    elif exercise_new_game and resource_parts:
        report['real_resource_route'] = {
            'resources': 'local dczdata parts staged and imported',
            'intro_fixture_markers': 'not required',
            'gameplay_evidence': 'validated by expected scene and gameplay markers'
        }
    if exercise_real_gameplay and resource_parts:
        report['real_resource_gameplay'] = {
            'resources': 'local dczdata parts staged and imported',
            'interaction_input': 'automated touch pulses through the normal input adapter',
            'scene_evidence': 'expected gameplay/gameComplete marker and gameplay interaction evidence'
        }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    run("xcrun", "simctl", "terminate", device, "org.example.portlab")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime")
    parser.add_argument("--expected-scene", choices=SCENE_CHOICES, default="checker")
    parser.add_argument("--boot-only", action="store_true")
    parser.add_argument("--startup-fixture", action="store_true")
    parser.add_argument("--exercise-new-game", action="store_true")
    parser.add_argument("--resource-parts", type=Path,
                        help="local directory containing DczlrData.manifest.json and all dczdata parts")
    parser.add_argument("--exercise-real-gameplay", action="store_true",
                        help="automatically pulse interaction input after staging real resource parts")
    args = parser.parse_args()
    if args.boot_only:
        print(json.dumps(select_device(args.output, args.runtime)))
    elif args.app:
        check(args.app, args.output, args.runtime, args.expected_scene,args.startup_fixture,args.exercise_new_game,args.resource_parts,args.exercise_real_gameplay)
    else:
        parser.error("--app is required unless --boot-only is selected")
