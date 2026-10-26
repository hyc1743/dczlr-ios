"""Launch the self-authored sprite integration scene on an iOS simulator."""
import argparse
import hashlib
import json
import math
import plistlib
import re
from pathlib import Path
import subprocess
import sys
import time
import os
import shutil
import uuid


SCENES = {"checker": "self-authored checker sprite", "startup": "first startup-card sprite", "warning": "second startup-card sprite",
          "title": "title-screen background and menu layers", "intro": "first new-game script record and text adapter"}
GAMEPLAY_SCENES = {"gameplay": "chapter 3 map and actor scene", "gameComplete": "completed chapter 3 map sequence"}
STORY_SCENES = {"story": "script chapters 0-2, gameplay scene, interaction and chapter 4 script"}
SCENE_CHOICES = tuple(SCENES) + tuple(GAMEPLAY_SCENES) + tuple(STORY_SCENES) + ('renderProbe','mouseInput')


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


def story_evidence(log):
    if "Vulkan 初始化或绘制失败" in log:
        raise ValueError("Story run reported a rendering failure")
    scenes = gameplay_scenes(log)
    if not scenes or scenes[0] != "gameplay":
        raise ValueError("Story gameplay scene was not presented")
    interactions = re.findall(r"(?m)^\S+ PORTLAB_GAME_INTERACTION_COMPLETED(?= |$)", log)
    if not interactions:
        raise ValueError("No completed story interaction was reported")
    records = re.findall(r"(?m)^\S+ PORTLAB_INTRO_RECORD=(\d+:\d+)(?= |$)", log)
    chapter4 = [record for record in records if record.startswith("4:")]
    if not chapter4:
        raise ValueError("Chapter 4 script did not follow the first gameplay scene")
    skin = bool(re.search(r"(?m)^\S+ PORTLAB_GAMEPLAY_SKIN_ADVANCED(?= |$)", log))
    if not skin:
        raise ValueError("Real gameplay actor skinning was not reported")
    # Require a forward route in this session. Unordered or stale markers
    # must not certify that a script actually followed the game scene.
    route = re.findall(r"(?m)^\S+ (PORTLAB_INTRO_RECORD=\d+:\d+|PORTLAB_SCENE_PRESENTED=gameplay|PORTLAB_GAME_INTERACTION_COMPLETED)(?= |$)", log)
    expected = ("PORTLAB_INTRO_RECORD=0:0", "PORTLAB_INTRO_RECORD=1:0",
                "PORTLAB_INTRO_RECORD=2:0", "PORTLAB_SCENE_PRESENTED=gameplay",
                "PORTLAB_GAME_INTERACTION_COMPLETED", "PORTLAB_INTRO_RECORD=4:0")
    cursor = iter(route)
    if not all(any(event == required for event in cursor) for required in expected):
        raise ValueError("Story events did not follow script -> gameplay -> interaction -> next script order")
    return {
        "scenes": scenes,
        "completed_interactions": len(interactions),
        "story_loop": "script chapters 0-2, first gameplay scene, interaction and the follow-up chapter 4 script were exercised",
        "actor_skinning": "real actor skinning advanced and was presented",
        "chapter4_records": chapter4[:4],
        "complete_story": "not exercised by this bounded route",
        "physical_iphone": "not tested",
    }


def story_present(log):
    try:
        story_evidence(log)
        return True
    except ValueError:
        return False


def touch_route_evidence(log):
    if 'PORTLAB_TOUCH_ROUTE_FAILED' in log:
        raise ValueError('Visible touch input failed its window hit test')
    story=story_evidence(log)
    for event in ('PORTLAB_TOUCH_INPUT_STARTED','PORTLAB_GAMEPAD_MOVEMENT_ADVANCED',
                  'PORTLAB_GAMEPAD_CAMERA_ADVANCED','PORTLAB_TOUCH_SAVE_COMPLETED',
                  'PORTLAB_TOUCH_ROUTE_PASSED'):
        if not re.search(r'(?m)^\S+ '+event+r'(?= |$)',log):
            raise ValueError('Missing actual touch control evidence: '+event)
    return {'input_path':'visible window hit test -> UIKit touch handlers -> native input snapshot -> game scene',
            'raw_controller_injection':False,'actions':['point/confirm','position adjustment menu','camera drag','save','interaction','next chapter'],
            'story':story,'physical_device':'not tested'}


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


def mouse_input_evidence(log):
    if 'PORTLAB_TOUCH_ROUTE_FAILED' in log or 'Vulkan 初始化或绘制失败' in log:
        raise ValueError('Virtual mouse run failed')
    required=('PORTLAB_TOUCH_INPUT_STARTED','PORTLAB_INTRO_RECORD=0:0','PORTLAB_INTRO_RECORD=1:0',
        'PORTLAB_INTRO_RECORD=2:0','PORTLAB_SCENE_PRESENTED=gameplay','PORTLAB_GAMEPLAY_SKIN_ADVANCED',
        'PORTLAB_MOUSE_MOVE_DELIVERED','PORTLAB_MOUSE_LEFT_DELIVERED','PORTLAB_MOUSE_RIGHT_DELIVERED',
        'PORTLAB_MOUSE_MENU_ACCEPTED','PORTLAB_GAMEPAD_CAMERA_ADVANCED','PORTLAB_MOUSE_CONTEXT_RENDERED',
        'PORTLAB_MOUSE_CONTEXT_SELECTED','PORTLAB_MOUSE_CONTEXT_DISMISSED','PORTLAB_MOUSE_INPUT_PASSED')
    for event in required:
        if not re.search(r'(?m)^\S+ '+re.escape(event)+r'(?= |$)',log):raise ValueError('Missing mouse evidence: '+event)
    return {'scope':'bounded input on first real-resource scene','input':'visible relative drag, mouse buttons and Num6/arrow combination',
        'menu':'left click accepted by scene hit test','complete_story':'not tested',
        'right_click_menu_behavior':'initial camera menu GPU visibility, left selection and right dismissal checked',
        'context_action_callbacks':'not implemented; selection does not certify an executed game action',
        'original_game_equivalence':'not established','physical_device':'not tested'}


def black_gutter_evidence(log):
    controls=re.findall(r'(?m)^\S+ PORTLAB_GAMEPAD_PRESENTATION ([^\n]+)',log)
    render=re.findall(r'(?m)^\S+ PORTLAB_RENDER_VIEWPORT ([^\n]+)',log)
    if not controls or not render:raise ValueError('Missing game/control viewport evidence')
    c=controls[-1];r=render[-1]
    for field in ('layout=black-gutters-v4','attached=1','hidden=0','key_overlap=0'):
        if field not in c.split():raise ValueError('Virtual controls overlap game or are not visible: '+field)
    def rect(row):
        m=re.search(r'\bgame=([0-9.,-]+)',row)
        values=[float(v) for v in m[1].split(',')] if m else []
        if len(values)!=4 or not all(math.isfinite(v) for v in values):raise ValueError('Invalid game rectangle')
        return values
    a=rect(c);b=rect(r)
    if any(abs(x-y)>.01 for x,y in zip(a,b)):raise ValueError('Render and controls use different game rectangles')
    x,y,w,h=b
    if x<=0 or y<0 or w<=0 or h<=0 or abs(w/h-4/3)>.001:raise ValueError('Invalid central 4:3 game viewport')
    return {'game_rect_points':b,'virtual_key_overlap':0,'layout':'all 28 key circles in black side gutters','pointer_mapping':'shared game viewport'}

def scene_ready(log, expected, require_animation=False, require_xa=False, require_material=False, require_xx=False, require_pose=False):
    if expected=='mouseInput':
        try:mouse_input_evidence(log);return True
        except ValueError:return False
    if expected=='renderProbe':
        return bool(re.search(r'(?m)^\S+ PORTLAB_RENDER_PROBE_COMPLETED completed captures=15(?= |$)',log)) and 'Vulkan 初始化或绘制失败' not in log
    if expected == 'story':
        return story_present(log)
    if expected in GAMEPLAY_SCENES:
        try:
            gameplay_evidence(log,require_complete=expected=='gameComplete',require_skin=True)
            return "Vulkan 初始化或绘制失败" not in log
        except ValueError:
            return False
    observed = gameplay_scenes(log) if expected in GAMEPLAY_SCENES else presented_scenes(log)
    return (expected in observed and (not require_animation or animation_advanced(log))
            and (not require_xa or xa_fixture_loaded(log)) and (not require_material or material_advanced(log))
            and (not require_xx or xx_fixture_loaded(log)) and (not require_pose or pose_advanced(log)))


def scene_evidence(log, expected, require_animation=False, require_xa=False, require_material=False, require_xx=False, require_pose=False):
    if expected=='mouseInput':return mouse_input_evidence(log)
    if expected=='renderProbe':
        if not scene_ready(log,expected):raise ValueError('GPU render checkpoints did not complete')
        return {'render_checkpoints':'completed; per-frame validation follows','physical_iphone':'not tested'}
    if expected not in SCENES and expected not in GAMEPLAY_SCENES and expected not in STORY_SCENES:
        raise ValueError("Unknown expected scene: " + expected)
    if expected == 'story':
        if not scene_ready(log, expected):
            raise ValueError("Expected story loop was not reported: " + expected)
        return story_evidence(log)
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


def simulator_screenshot(device, path):
    """Retry a failed simulator capture once; retain both attempts as evidence."""
    attempts=[]
    for attempt in range(2):
        try:
            result=run('xcrun','simctl','io',device,'screenshot',str(path),timeout=30)
            attempts.append({'attempt':attempt+1,'result':'saved','output':result})
            Path(str(path)+'.capture.json').write_text(json.dumps(attempts,indent=2)+'\n',encoding='utf-8')
            return
        except (subprocess.TimeoutExpired,RuntimeError) as error:
            attempts.append({'attempt':attempt+1,'result':'failed','error':str(error)})
    Path(str(path)+'.capture.json').write_text(json.dumps(attempts,indent=2)+'\n',encoding='utf-8')
    raise RuntimeError('Simulator screenshot failed twice: '+str(path))


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


def stage_resource_parts(parts_root, container, output, restore=False):
    """Copy verified local dczdata parts into the simulator Documents tree."""
    parts_root = Path(parts_root).resolve(strict=True)
    manifest_path = parts_root / "DczlrData.manifest.json"
    if not parts_root.is_dir() or not manifest_path.is_file():
        raise ValueError("resource-parts must contain DczlrData.manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    documents = container / "Documents"
    destination = documents / "ResourcePacks"
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
        # Keep a root-level copy too. Older app containers and the native
        # importer accept both layouts; staging both removes container-path
        # ambiguity across simulator launches.
        shutil.copy2(source, documents / source.name)
        staged.append({"name": source.name, "size": source.stat().st_size, "sha256": digest})
    (output / "resource-staging.json").write_text(json.dumps({
        "source": str(parts_root), "destination": str(destination),
        "parts": staged, "manifest_total_bytes": manifest.get("total_bytes")
    }, indent=2) + "\n", encoding="utf-8")
    if restore:
        restored = container / "Documents" / "game" / "Data"
        subprocess.run([sys.executable, "tools/pack_resources.py", "restore",
                        "--parts", str(parts_root), "--manifest", str(manifest_path),
                        "--out", str(restored)], check=True, timeout=600)
    return staged


def controls_visible(log, pc_input=False):
    # NSArray's device description can span several lines. Keep continuation
    # lines with their own timestamped presentation event, never a later event.
    for event in re.split(r'(?m)(?=^\d{4}-\d{2}-\d{2}T\S+\s)', log):
        match=re.search(r'PORTLAB_GAMEPAD_PRESENTATION bounds=(\d+)x(\d+) attached=(\d+) hidden=(\d+) physical=(\d+) paths=(\d+)',event)
        if not match:continue
        width,height,attached,hidden,physical,paths=map(int,match.groups())
        if width<=0 or height<=0 or attached!=1:continue
        if pc_input:
            if re.search(r'\bpc_visible=1\b',event):return True
        elif hidden==0 and physical==0 and paths==1:return True
    return False


def preserve_gameplay_capture(container, output):
    """Copy a native frame before later scene objects overwrite its filename."""
    shutil.copyfile(Path(container)/'Documents/gameplay-first-native.png',
                    Path(output)/'gameplay-first-native.png')


def check(app, output, runtime, expected_scene="checker", startup_fixture=False,
          exercise_new_game=False, resource_parts=None, exercise_real_gameplay=False, pc_input=False,
          exercise_story=False,touch_controls=False,render_probe=False,mouse_input=False):
    if mouse_input and (not resource_parts or expected_scene!='mouseInput' or exercise_story or touch_controls or pc_input):
        raise ValueError('Mouse input check requires its independent real-resource route')
    if exercise_new_game and (not startup_fixture and not resource_parts):
        raise ValueError('New-game exercise requires generated startup fixture or staged resource parts')
    if exercise_new_game and startup_fixture and expected_scene != 'intro':
        raise ValueError('Generated startup fixture new-game exercise requires intro target')
    if exercise_real_gameplay and (not resource_parts or expected_scene not in ('gameplay', 'gameComplete')):
        raise ValueError('Real gameplay exercise requires resource parts and gameplay target')
    if exercise_story and (not resource_parts or expected_scene != 'story'):
        raise ValueError('Story exercise requires resource parts and story target')
    if touch_controls and (not exercise_story or pc_input):
        raise ValueError('Touch controls require the real story route without PC mode')
    if render_probe and (not resource_parts or expected_scene!='renderProbe' or exercise_story or touch_controls):
        raise ValueError('Render probe requires real resource parts and its own independent route')
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
    # Every probe owns a fresh container. This prevents generated-fixture runs
    # and real-resource runs in the same workflow from sharing partial Data.
    try:
        subprocess.run(["xcrun", "simctl", "uninstall", device, "org.example.portlab"],
                       capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        # On a cold runner bootstatus can return before the installation
        # service answers. Retry the cleanup before creating this session.
        subprocess.run(["xcrun", "simctl", "uninstall", device, "org.example.portlab"],
                       capture_output=True, text=True, timeout=60)
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
        # Both automation routes hand Data to the renderer at launch. Restore
        # it completely before either route can start reading game resources.
        stage_resource_parts(resource_parts, container, output,
                             restore=exercise_real_gameplay or exercise_story or render_probe or mouse_input)
    launch_environment=dict(os.environ)
    # Hosted simulators can expose a host/virtual gamepad. Isolate this display
    # probe from that device so virtual controls are actually rendered. The
    # override is compiled out of Release; physical mapping has its own test.
    launch_environment['SIMCTL_CHILD_PORTLAB_TEST_VIRTUAL_CONTROLS']='1'
    if pc_input:launch_environment['SIMCTL_CHILD_PORTLAB_TEST_PC_INPUT']='1'
    session=uuid.uuid4().hex
    launch_environment['SIMCTL_CHILD_PORTLAB_LAUNCH_ID']=session
    if startup_fixture:launch_environment['SIMCTL_CHILD_PORTLAB_CAPTURE_STARTUP']='1'
    if exercise_new_game:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_NEW_GAME']='1'
    if exercise_real_gameplay:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_REAL_GAMEPLAY']='1'
    if exercise_real_gameplay:launch_environment['SIMCTL_CHILD_PORTLAB_CAPTURE_GAMEPLAY']='1'
    if exercise_story:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_STORY']='1'
    if exercise_story:launch_environment['SIMCTL_CHILD_PORTLAB_CAPTURE_GAMEPLAY']='1'
    if touch_controls:launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_TOUCH_CONTROLS']='1'
    if mouse_input:
        launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_STORY']='1'
        launch_environment['SIMCTL_CHILD_PORTLAB_EXERCISE_TOUCH_CONTROLS']='1'
        launch_environment['SIMCTL_CHILD_PORTLAB_CAPTURE_GAMEPLAY']='1'
    if render_probe:launch_environment['SIMCTL_CHILD_PORTLAB_RENDER_PROBE']='1'
    # Cold CoreSimulator may queue the same request for over two minutes.
    # Observe that live command and app-authored evidence concurrently; never
    # issue another launch merely because an observation interval elapsed.
    launch_output=(output/'launch.txt').open('w',encoding='utf-8')
    launch_process=subprocess.Popen(['xcrun','simctl','launch','--terminate-running-process',device,'org.example.portlab'],
        stdout=launch_output,stderr=subprocess.STDOUT,text=True,env=launch_environment)
    wait_seconds=600 if exercise_story or render_probe or mouse_input else (300 if startup_fixture else 240)
    deadline = time.monotonic() + wait_seconds
    log = ""
    captured=set()
    while time.monotonic() < deadline:
        path = container / "Documents/log.txt" if container else None
        if path and path.exists():
            candidate=path.read_text(encoding='utf-8')
            if not has_session(candidate,session):
                time.sleep(1);continue
            if candidate!=log:
                (output/'app.log').write_text(candidate,encoding='utf-8')
            log=candidate
            if 'PORTLAB_GAMEPAD_TEST_FAILED' in log or 'PORTLAB_PC_INPUT_TEST_FAILED' in log or 'PORTLAB_TOUCH_ROUTE_FAILED' in log:
                (output/'app.log').write_text(log,encoding='utf-8')
                raise RuntimeError('UIKit gamepad regression failed: '+log[-2000:])
            if startup_fixture:
                for scene in presented_scenes(log):
                    if scene not in captured:
                        simulator_screenshot(device,output/('startup-'+scene+'.png'))
                        captured.add(scene)
            if (exercise_real_gameplay or exercise_story or mouse_input) and 'gameplay' in gameplay_scenes(log) and 'gameplay-first' not in captured:
                # Scene objects reuse this native capture filename. Preserve
                # the first scene now, before a slow simctl screenshot lets
                # the game advance and overwrite it with a later chapter.
                preserve_gameplay_capture(container,output)
                simulator_screenshot(device,output/'gameplay-first.png')
                captured.add('gameplay-first')
            story_ok = not exercise_story or story_present(log)
            if touch_controls:
                story_ok=story_ok and bool(re.search(r'(?m)^\S+ PORTLAB_TOUCH_ROUTE_PASSED(?= |$)',log))
                if 'PORTLAB_TOUCH_SAVE_COMPLETED' in log and 'manual-save' not in captured:
                    shutil.copyfile(container/'Documents/game/Data/save/player.state',output/'touch-player.state')
                    captured.add('manual-save')
            gameplay_ok = not exercise_real_gameplay or all(event in log for event in (
                'PORTLAB_GAMEPAD_MOVEMENT_ADVANCED', 'PORTLAB_GAMEPAD_CAMERA_ADVANCED'))
            scene_ok=scene_ready(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose)
            audio_ok=not startup_fixture or bool(re.search(r'(?m)^\S+ PORTLAB_TITLE_AUDIO_ADVANCED(?= |$)',log))
            if startup_fixture:audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_NATIVE_SKIN_ADVANCED(?= |$)',log))
            if exercise_new_game and startup_fixture:
                audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_INTRO_AUDIO_ADVANCED(?= |$)',log))
                audio_ok=audio_ok and bool(re.search(r'(?m)^\S+ PORTLAB_INTRO_RECORD=1:0(?= |$)',log))
            if (scene_ok and audio_ok and story_ok and gameplay_ok) or "Vulkan 初始化或绘制失败" in log:
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
        for crash in container_logs.rglob("*.ips"):
            shutil.copyfile(crash, crash_dir / crash.name)
    diagnostic_reports = Path.home() / "Library/Logs/DiagnosticReports"
    if diagnostic_reports.exists():
        for pattern in ("*PortLab*.ips", "*SimMetalHost*.ips"):
            for crash in diagnostic_reports.glob(pattern):
                shutil.copyfile(crash, crash_dir / crash.name)
    simulator_screenshot(device,output/'sprite-scene.png')
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
    if 'PORTLAB_GAMEPAD_TEST_PASSED' not in log:
        raise RuntimeError('Missing UIKit gamepad regression evidence')
    if 'PORTLAB_PC_INPUT_TEST_PASSED' not in log:
        raise RuntimeError('Missing simultaneous UIKit keyboard and mouse regression evidence')
    if expected_scene != 'checker':
        if not controls_visible(log,pc_input):
            raise RuntimeError('Gamepad overlay was not visible in the actual application window: '+log[-2000:])
    report = {"gamepad_regression": "UIKit touch ownership and GameController snapshot passed",
              "pc_input_regression": "Simultaneous UIKit key hold, mouse hold, pointer drag and independent release passed",
              "pc_input_visible": pc_input,
              "simulator": phone["name"], "runtime": phone["runtime"], "udid": device,"launch_command":launch_state,
              **scene_evidence(log, expected_scene, require_animation, require_xa, require_material, require_xx, require_pose)}
    if mouse_input:
        from startup_pixels import verify_gameplay_actor
        report['virtual_controls']=black_gutter_evidence(log)
        report['initial_actor_visibility']=verify_gameplay_actor((output/'gameplay-first-native.png').read_bytes())
        for name in ('gameplay-first-native.json','gameplay-context-native.png','gameplay-context-native.json'):
            shutil.copyfile(container/'Documents'/name,output/name)
        context=json.loads((output/'gameplay-context-native.json').read_text())
        if not context['context_open'] or context['context_icon']!=3 or context['context_count']!=7 or context['context_visible_pixels']<100:
            raise ValueError('Original camera context is not visible in exact GPU capture')
        report['context_gpu_capture']=context
    if startup_fixture:
        report['startup_fixture']=startup_evidence(log,require_audio=True,require_skin=True)
        if not {'startup','warning','title'}<=captured:raise ValueError('Missing startup stage screenshots')
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
        from startup_pixels import verify_gameplay_actor
        report['initial_actor_visibility']=verify_gameplay_actor((output/'gameplay-first-native.png').read_bytes())
        if not all(event in log for event in ('PORTLAB_GAMEPAD_MOVEMENT_ADVANCED', 'PORTLAB_GAMEPAD_CAMERA_ADVANCED')):
            raise RuntimeError('Controller input did not advance both native movement and camera')
        import ctypes as C
        from native_core import library, GamePlayer, StoryState
        saved=(container/'Documents/game/Data/save/player.state').read_bytes()
        (output/'player.state').write_bytes(saved)
        player,story=GamePlayer(),StoryState()
        lib=library()
        player_status=lib.dc_game_player_load(saved,len(saved),C.byref(player))
        story_status=lib.dc_story_load(saved[32:],max(0,len(saved)-32),C.byref(story))
        save_report={'bytes':len(saved),'player_status':player_status,'story_status':story_status,
                     'player_map':player.map_selector,'story_chapter':story.chapter if story_status==0 else None}
        (output/'save-check.json').write_text(json.dumps(save_report,indent=2)+'\n',encoding='utf-8')
        if player_status or story_status:
            raise RuntimeError('Gameplay save did not preserve both player and story records: '+json.dumps(save_report))
        report['save_record']=save_report
        report['real_resource_gameplay'] = {
            'resources': 'local dczdata parts staged and imported',
            'interaction_input': 'automated touch pulses through the normal input adapter',
            'scene_evidence': 'expected gameplay/gameComplete marker and gameplay interaction evidence'
        }
    if exercise_story and resource_parts:
        from startup_pixels import verify_gameplay_actor
        report['initial_actor_visibility']=verify_gameplay_actor((output/'gameplay-first-native.png').read_bytes())
        report['real_resource_story'] = {
            'resources': 'local dczdata parts staged and imported',
            'interaction_input': 'automated touch pulses through the normal input adapter',
            'story_evidence': 'expected script->gameplay->interaction->chapter-4 script markers'
        }
        report['story']=story_evidence(log)
    if touch_controls:
        report['touch_controls']=touch_route_evidence(log)
        import ctypes as C
        from native_core import library,GamePlayer,StoryState
        saved=(output/'touch-player.state').read_bytes()
        player,story=GamePlayer(),StoryState();lib=library()
        assert lib.dc_game_player_load(saved,len(saved),C.byref(player))==0
        assert lib.dc_story_load(saved[32:],max(0,len(saved)-32),C.byref(story))==0
        report['touch_save']={'bytes':len(saved),'player_record':'valid','story_record':'valid','chapter':story.chapter}
    if render_probe:
        source=container/'Documents/render-probe.json'
        data=json.loads(source.read_text(encoding='utf-8'))
        shutil.copyfile(source,output/'render-probe.json')
        for row in data.get('captures',[]):
            name=row['file']
            if Path(name).name!=name:raise ValueError('Invalid native frame name')
            shutil.copyfile(container/'Documents'/name,output/name)
        from render_probe_evidence import validate
        report['render_probe']=validate(data,output)
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
    parser.add_argument("--pc-input", action="store_true", help="show and verify the actual keyboard/mouse overlay")
    parser.add_argument("--touch-controls", action="store_true",help="drive visible touch controls through window hit tests and UIKit handlers")
    parser.add_argument("--render-probe",action="store_true",help="capture and validate idle/interaction/restored GPU frames in each distinct story map")
    parser.add_argument("--mouse-input",action="store_true",help="independent real-resource virtual mouse gate; does not certify original scene callbacks")
    parser.add_argument("--resource-parts", type=Path,
                        help="local directory containing DczlrData.manifest.json and all dczdata parts")
    parser.add_argument("--exercise-real-gameplay", action="store_true",
                        help="automatically pulse interaction input after staging real resource parts")
    parser.add_argument("--exercise-story", action="store_true",
                        help="automatically drive the original script/scene story loop after staging real resource parts")
    args = parser.parse_args()
    if args.boot_only:
        print(json.dumps(select_device(args.output, args.runtime)))
    elif args.app:
        check(args.app, args.output, args.runtime, args.expected_scene,args.startup_fixture,args.exercise_new_game,args.resource_parts,args.exercise_real_gameplay,args.pc_input,args.exercise_story,args.touch_controls,args.render_probe,args.mouse_input)
    else:
        parser.error("--app is required unless --boot-only is selected")
