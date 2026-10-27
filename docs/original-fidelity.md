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
The current route additionally checks the initial camera context and primary
target-0/reset callbacks. It does not certify all original context actions,
the full story or a physical device. The separate story route covers scripts
0-2, the first scene and script 4, not all 26 chapters. Mouse-only runs cannot
produce a release IPA.

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

## Primary camera actions (2026-10-27)

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

### Render visibility versus transform suppression

Run 40407020843 passed its initial camera gate, but manual artifact review
found the target position was (0,0,0): hiding the face mesh incorrectly froze
its node's transform at the initial identity cache. That run does not certify
correct retarget binding. The superseded follow-up run 40410498469 was cancelled
when the original flag distinction was established.

Original FUN_00412450 recursively writes render-hidden byte +0x1f0. Original
FUN_00415620 continues matrix updates/traversal under a render-hidden parent;
its independent +0x1f8 byte suppresses matrix updates and the subtree. The
previous host conflated these two bytes in dc_model_hide_node. The final fix
stores render visibility separately, recursively sets it as the original does,
and keeps serialized transform-suppression flags unchanged. A child may be
shown again beneath a render-hidden parent. Hidden face targets now have
normal current cached world matrices, used through dc_model_global; no
special forced-binding transform query is retained.

Isolated original instruction execution on eight synthetic two-node scenarios
(56 operations) checks recursive render hiding, revealing a child, matrix
updates while hidden, and independent transform-skip behavior. Matrix math
and the unused no-billboard camera inverse are explicit synthetic boundaries;
render-list admission and cached matrices are observed, not GPU equivalence.
The vectors are in tests/fixtures/render-visibility-original-vectors.json.
Resource checks cover the hidden face target of all three original stages.
Captures retain the complete target world matrix; nonfinite, missing and
non-affine matrices are rejected. Retarget math also rejects a zero-filled
non-affine input. The corrected target still requires final simulator evidence.

A separate static follow-up finding for the remaining character callbacks:
FUN_005201e0 constructs 35 effect slots from 30 names starting at VA 0x63c278
(stride 12) followed by five empty entries. Slot 28 (+0x10dc) is se030.wav,
not the host's current sorted-list entry. FUN_005358c0 type-4 option 1 arms
+0x185d and, at initial progress zero, plays that slot; FUN_00513690 waits
for its query to become idle before requesting scene state 2. This route is
not implemented yet. Metadata only is retained in out/original-effect-slot-table.json.

### Confirmed corrected camera run

GitHub run 40413204123, source commit
14be47ab8bb383b596d961ea331325f8fa4314d4, completed successfully on
2026-10-27 (Asia/Shanghai). Portable checks, iOS build, generated startup/New
Game, concurrent keyboard/mouse, and the real-resource camera/mouse gate passed.
Local unittest discovery passes 297 tests. The unsigned IPA job was skipped;
no release was published.

The corrected target world matrix has translation
(21.5725231,4.6985197,-0.9768603), consistent with the character world region,
rather than the previous initial identity cache. The retarget capture has
114,935 actor-visible pixels. The reset capture has 198,551 and its seven
camera parameters equal the original home_sh CAM bytes exactly. The input
surface remains 874x402 points, game rect (183,0,508,381), with zero virtual
key overlap. The context remains usable after both actual camera actions.

The local three-stage GPU diagnostic still renders b/c/a actors with
44,065/41,292/35,293 visible pixels. Cached render-hidden target matrices now
match the separately evaluated hierarchy positions for all three stage assets.
These observations certify this bounded binding/action/render route, not
complete original lighting, interactions, other camera modes, secondary view,
save/edit screens or full-story equivalence.

Artifact 12693474951 is retained in out/primary-camera-evidence-14be47a with
report.json, native GPU captures, complete target matrices and app.log. Its
ZIP passed CRC validation; SHA-256 is
774469831f1fc9d867e5b6ccfa64f41df6bcfb20436e7420ac3c7973ac31e070.

## RGB shadows and initial character context (2026-10-27)

The supplied device log records two accepted character context selections,
each incrementing pending_actions. The pointer route worked; the original
character callback was missing. The supplied image also exposes z_On_kage
as a black rectangle. All three actor XX resources encode subset blend2,
transparent queue1, priority30 for that mesh, despite fully opaque BMP alpha.

FUN_0040a200 copies each serialized 16-byte subset header. FUN_004132e0
reads hide bit0, blend bits2..4, point-sampling bit5, order byte1 and
two-sided byte2. Blend2 establishes D3D factors ZERO/INVSRCCOLOR (1/4).
The host previously ignored these flags and always used alpha blending;
the backend also translated factor4 to SRC_COLOR instead of its inverse.
Both are corrected, including the alpha counterpart. Explicit transparent
queue admission prevents an RGB-only shadow from becoming a depth occluder.
Node queue/priority are exposed; complete original priority sorting, lighting
and special effect programs remain outside this change.

The local Intel Vulkan pixel gate verifies black/gray/white RGB shadow
samples preserve/darken/blacken the floor, independent of submission order.
All prior pixel, clipping, depth, filter, scissor and admission gates pass.
Validation layers are disabled on this local run; CI evidence follows below.

FUN_00404630/00404680 are now available as model configuration operations.
20 isolated original-instruction cases match chain enable/disable and loop
limit byte stores; no external helper executes. The public fixture is
tests/fixtures/animation-config-original-vectors.json. Synthetic native tests
cover the 1499/1500-tick delay, repeat/saturation, player-busy gating and
unsupported profile atomicity. Private asset checks show all three initial
body animation chains run 2->5->6->7->1 after loop5 is limited to one cycle.

Initial type4/progress0 character context option0 configures chain6->7 and
loop5 once, arms the recovered delay, then requests clip2 plus effect slot22.
Option1 starts slot28 and blocks further menu input until the actual player
is idle, requests shared transition clip2 and waits for its original ready
query before chapter advancement. Evolved/alternate-node branches are not
admitted. The shared transition is composited over the current scene with
its original camera and resources. The effect table now preserves all35
original slots, including slot22 se021.wav and slot28 se030.wav; five empty
trailing slots remain unavailable. Missing/undecodable audio reports failure.
Pausing effects preserves their playback positions for the completion gate.

The simulator mouse route now additionally requires rendered character clip2
and restored clip1, actual slot28 busy-to-idle playback, original transition,
and arrival at numbered script chapter4. The route still does not certify
full story equivalence, later character actions, outfit actions, secondary
camera modes or save/edit screens. Local unittest discovery passes314 tests.
The Apple simulator validation is recorded below.

Additional isolated execution of FUN_005358c0 matches 54 initial selection
cases across stages 0/1/2, clips 1/11/13, options 0/1 and counter boundaries.
Model configuration and sound starts are recorded helper boundaries;
alternate-node bindings are null, selecting the initial hidden-alternate
branch. This is not a live game observation. The portable replay fixture is
tests/fixtures/character-select-original-vectors.json; local discovery now
passes 315 tests.

GitHub Vulkan run 40424130048 (source 06073ab) passed both Linux llvmpipe with
validation enabled (zero reported errors) and macOS MoltenVK pixel/surface
gates. Artifact 12698093550 contains Linux pixel evidence, and 12699197138
the Apple evidence. Local RGB comparisons at a chosen overhead camera find
53,830 shadow-darkened pixels, zero shadow-lightened pixels, and 34,863 pixels
restored from the old black-rectangle rendering. Those numeric comparisons
use the original assets through the shipping renderer, with/without the
shadow draw; they are not an original-PC GPU comparison. Local captures,
reports and downloaded pixel artifacts are retained under out/render-fix.

### Confirmed initial character simulator run

GitHub run 40424126130 passed on source 06073ab9eb4e7d6e34125ca17e658c3a6d5ef3d3.
Portable checks, iOS compilation, generated startup/New Game, simultaneous
PC input and the real-resource mouse/camera/character gate all succeeded.
The unsigned IPA job was intentionally skipped; packaging is separate.

The original character context option 0 produced active clip 2 (178,999
actor-visible pixels), followed by restored clip 1 (175,026). The trace
records the actual slot 28 player busy and then idle after 6,267 ms, followed
by original transition clip 2 and a presented numbered script 4:0. The two
character and two camera actions leave pending_actions=0 on this route.
Original active CAM reset still matches its source bytes. All 28 virtual
controls remain outside game rect (183,0,508,381), with zero overlap.

Artifact 12698738978 is retained in out/render-fix/ios-mouse-input with
report.json, native captures/sidecars and app.log. ZIP SHA-256 is
1c3293af56b507512273fe37b9a6af62847e9816e27c998b61131d0fdfeb1ca8;
CRC validation and local artifact review passed. This certifies only the
initial type-4 progress-zero route, not later menus or the complete game.

## Remaining primary camera modes (2026-10-27)

FUN_005181f0 binds primary target 1 to the actor's stage prefix plus
`_Kn_kosi` at scene +0x187c + stage*4. Primary option 1 now uses that exact
node through the already verified retarget calculation. Option 2 preserves
FUN_00539dd0's toggle between mode 2 and mode 0 and its active CAM reset.
Option 6 still resets both mode bytes and the primary/secondary presets.
Secondary options 3/4/5 and system destination scenes remain pending.

FUN_00522ff0 loads RPP_17 auto_cam.xx/xa into scene +0x1058; FUN_00512cc0
binds its `z_Nz_cam` to +0x1738. This separate model was previously absent.
The asset has a populated looping clip 0 (frames 0..40, duration 40 seconds),
while clip 1 is empty. The host explicitly selects clip 0 and advances it
throughout the type-4 scene, including while automatic mode is disabled.
Private resource tests verify movement and the loop, without exporting assets.

FUN_00513690 places this camera model at the actor's `z_Nz_light` translation,
uses its animated camera node as the eye, and raises the light-node look
target by the original constant 2.0 at VA 0x62e664. Mode 2 now builds the
rendered camera from those current-frame matrices. Model advancement is
separate from geometry submission so each controller ticks once. Manual
rotation, pan and zoom stay inactive in this original mode. Selecting option
2 again restores the CAM pose and manual control.

The generic look-at body FUN_00417ac0 and its original cross/scale leaves
match 48 synthetic cases within 0.00000006 absolute error. D3DX normalization
is an explicit Python math boundary, and constructors are inert. This does
not execute an original scene or the original D3DX/GPU. Portable vectors are
in tests/fixtures/camera-look-at-original-vectors.json. Local discovery passes
323 tests, including real-resource bindings for all three stages and camera
looping, aliasing/degenerate-input checks, and capture-evidence rejection.

The expanded simulator route requires target-1 retarget, automatic camera
captures at two animation frames, held Num6/Up while automatic mode is active,
toggle-off CAM/world-matrix restoration, then the existing initial character
actions and script-4 handoff. A separate Python calculation checks captured
camera world matrices, actual eye motion and the +2 target height. Simulator
execution for this change is pending; full original scene equivalence remains
unverified.
