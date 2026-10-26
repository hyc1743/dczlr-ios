# Original behavior audit (2026-10-27)

The current native port is incomplete. Original files, projected models, and
passing input checks do not demonstrate original gameplay or full-story
equivalence. v0.1.9 predates the corrections below.

## Verified corrections

`FUN_00517b30` indexes VA `0x00673280` with the story stage to construct body,
animation, face and placement resource names. The pinned EXE, SHA-256
`70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07`,
contains `62 63 61 64 65 00` (`bcade`) at file offset `0x273280`. Stages 0/1/2
select prefixes b/c/a. The previous host always loaded the a-prefixed files.
The host now selects the stage prefix for body/clip/face/PLST/eyes/neck and
node bindings. Local tests check all corresponding files and attachment nodes.

The virtual pointer persists after lifting. Moving the open screen does not
click. Mouse buttons and keyboard fingers retain independent owners, and
short taps survive frame polling. Physical inputs have separate owners.
Right clicks are no longer converted to a global pad Cancel action.

The unsupported tap-to-next-chapter shortcut for non-gameplay scenes was
removed. The 800ms interaction-completion harness now runs only in independent
DEBUG GPU probes, not in production gameplay. The speculative HScene asset
overlay/preload was removed: those resources belong to another original
screen, not the in-scene Character/Camera/System controls. Earlier GPU-stall
claims were not established; failed runs reached gameplay but the driver
moved the cursor without sending a mouse click.

## Callback evidence and remaining work

REA CLI/Ghidra analysis of `FUN_00489f20` produced Evidence
`ev_a8f7cef53b72f5b47728d7656e4e42d8a97662065d166b86f600fe38f1080ea4`.
It installs watch update `0x0048aa40`, separate render/cleanup callbacks, its
own state, and a six-entry scene menu. This is static analysis, not execution.
Complete local Evidence is retained in `out/original-watch.rea.json`.

Read-only exports from the existing Ghidra project are retained in
`out/original-scene-callbacks/` (ordinary local Ghidra output, not runtime
observations):

- `FUN_00513690` handles a right press over scene rows 1-4 by recording the
  pointer, entering contextual-menu state and calling `FUN_005319e0`.
- `FUN_005319e0` calls `FUN_00535730`, constructs up to seven normal/selected
  sprite pairs from `RPP_02.pp`, and places them around that pointer.
- `FUN_00532240` hit-tests that menu and dispatches to `FUN_0053a7c0`. A return
  value of 2 does not by itself mean next chapter.
- `FUN_00483510` installs night update `FUN_00483fe0` with separate state.
  The previous tap-to-continue claim for these scenes was unsupported.

Context-menu option generation/action execution, watch/night/ending state
machines, camera selection, effect/lighting equivalence and original save
serialization remain incomplete. Existing simplified scene-menu/action code
is not certified equivalent. Do not label this work original-equivalent or
publish based only on the bounded mouse check.

## Validation boundaries

The independent `--mouse-input --expected-scene mouseInput` route reaches the
first real-resource scene through startup and scripts 0-2. It checks relative
drag, separate mouse presses, a scene-menu hit, and a Num6/arrow combination.
Its report does not certify the original right-click menu, full story or a
physical device. The full story gate is retained separately. Mouse-only runs
cannot produce a release IPA.

The local `audit_texture_uploads.py` run rebuilt `dc_vk_sprite.c` and checked
4,295 standalone/XX texture references (1,608 unique decoded images) through
Vulkan upload and 16 point/alpha samples per unique image: zero mismatches.
The unrecognized `rpsp_02.pp` archive is explicitly excluded. This does not
certify original scene effects, lighting, geometry composition or gameplay.
No texture payloads were exported; the metadata report is retained locally as
`out/texture-upload-audit.json`.

## Scene UI and black gutters

The main scene icons are the P_chara/P_fuku/P_cam/P_sys S/N pairs from
RPP_02, not the HScene selection page. Table VA 0x673d98 specifies 96x96
sprites at (920,328/440/552/664), zero pivot. FUN_0051a4c0 hides the outfit
icon when the selected stage progress is zero. The host now renders these
sprites after geometry with depth disabled, retains that availability rule,
and loads the context M_k/M_c/M_s sprite pairs using their original IDs.
FUN_005319e0 uses a 105-unit fan, thirds of 35, logical 240x32 sprites and
pivot (.9,.5); the input core now hit-tests those same rectangles.

The unsupported `dc_game_menu_activate` API and production main-icon-to-clip,
interaction-count and finish mappings were removed. Context selections and
close codes are recorded separately. **Context action callbacks are pending**;
opening or selecting a visible menu does not certify the selected action.
Initial type-4 character, camera and system profiles are admitted. Evolved
character/outfit profiles and other scene types fail admission rather than
showing guessed options. Camera mode flags currently remain at initial values.

A shared C viewport reserves three columns of virtual controls in each black
gutter and keeps the central game view at 4:3. Renderer frame, visible key
bounds, relative mouse scale and DEBUG pointer route use the same rectangle.
The pointer persists within that rectangle. All 28 key circles must stay
outside it, including Esc/V/F1. iPad layouts reserve gutters by reducing the
central game viewport, rather than covering its original UI.

The mouse gate now requires exact GPU context visibility, a left-selected
context index, subsequent right dismissal and reopening. Separate GPU
readbacks compare actor against map-only geometry and UI against geometry,
so icons cannot count as visible actor pixels. The report explicitly keeps
context action callbacks, full story and original equivalence unverified.
The preceding f96d3c6 GitHub run 40393733219 passed portable tests and failed
on a simctl startup-title screenshot timeout after title presentation; it
never reached the real mouse gate. Screenshot capture now retries once and
retains each attempt, and still fails if neither capture succeeds.

FUN_0051a890 additionally selects the outfit texture atlas quarter by stage:
u0=.5/.25/0, u1=u0+.25 (the underlying resource is 384x96). Both that helper
and FUN_00533940 render the S base followed by a visible N hover overlay.
The host preserves that composition instead of stretching the entire outfit
atlas or replacing the base texture on hover.

### Confirmed simulator run

GitHub run 40399442097, implementation commit
f160ef080a2d5ed04e024d40b214aa60a4af1a46, completed successfully on
2026-10-27 (Asia/Shanghai). Portable checks, iOS build, generated startup/New
Game, concurrent PC input, and the bounded real-resource mouse/menu gate all
passed. Local unittest discovery passed 287 tests. The unsigned IPA job was
skipped and no release was created.

The iPhone 16 Pro / iOS 18.5 report records game rect (183,0,508,381) points
inside an 874x402 input surface, matching the control layout with zero key
circle overlap. The actual camera context GPU capture contains 98,555 pixels
that differ from the same scene with only main icons. Logs show context index
6 selected, a separate right dismissal and three openings. These are menu
shell/input observations; context callback execution remains unimplemented.

Downloaded artifact 12689596700 is retained in
out/scene-ui-evidence-f160ef0, with its report, native captures and app log.
The downloaded ZIP passed CRC validation; SHA-256 is
26b2942da36616eab2f58ff092e8f933166a15dde86098883b15367d034cc09e.
The layout-review image masks the game area only for reviewing the controls;
original GPU captures are retained separately and are not modified.

## Primary camera actions (next implementation)

`dc_scene_action_build` now separates original context indices from resource
IDs. Isolated execution of FUN_00539dd0 and the type-4 system branch of
FUN_0053a7c0 matched the native numeric plans on 729 combinations of option,
mode, stage and active preset. Camera math/reset/publication, sound and cookie
checking are explicit synthetic boundaries; destination screens do not execute.
The replayable numeric metadata is in tests/fixtures/scene-action-original-vectors.json.
System option 0 requests the original save/load screen, and option 1 the edit
screen. These requests are not chapter advancement or a quick-save substitute.

`dc_camera_retarget` ports the two retarget bodies, FUN_00581380/00581af0.
128 isolated original-instruction cases with documented Python math boundaries
match within 0.000004 absolute error. They exercise both controller layouts,
height, pitch, rotation, distance and target positions. These checks do not
cover target binding, tracking, collision, original model state or a GPU.

The host now executes primary camera option 0 using the third face-node binding
from FUN_005181f0 (+0x1708): stage prefix plus `_On_namida`. It applies the
recovered retarget calculation to the current camera and the bound node's
world position. Option 6 restores the active original CAM record and resets
both camera mode flags; the primary view is rendered from that restored pose.
Other camera options, secondary-view rendering, automatic tracking, character
and outfit actions, and the save/edit destination screens remain incomplete.
They are recorded as pending instead of applying fabricated transitions.

FUN_0047e110's resource selection replaces heuristic camera-name guesses for
scene types 4/5/6. Reachable chapters select home_sh, trai_ch, toil_ta, park_tc
and hote_tb CAM files, as dictated by the scene/map/stage tables. No camera
search based on visible triangle counts substitutes a different preset for
those scene kinds. Their complete scene implementations remain unverified.

Opening the context now processes its input in the same frame, preserving the
original simultaneous-left/right behavior. The real mouse gate additionally
requires primary retarget and default-reset callbacks, exact GPU captures of
each, and a reset pose checked independently against original CAM bytes.
Local unittest discovery passes 293 tests. GitHub validation for this change
must complete before treating these new callback captures as observed evidence.
