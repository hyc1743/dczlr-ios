# Model runtime and triangle geometry

`dc_model` connects the existing bounded XX/XA readers, controller, pose and
material samplers, node hierarchy and mesh projector. Inputs stay borrowed;
decoded numeric arrays are owned. The root local matrix becomes identity,
matching the final original loader setup. Pose names bind to the last matching
root descendant; material names bind to the first matching material. Missing
targets are inert. Tracks retain file order and individual model baselines.

The current explicit profile has mode-0 node tracks, material tracks, framed
event tracks whose target/flag payload remains opaque, unskinned meshes and
indexed four-matrix skinning. Crossfades, mode-1 poses, billboard transforms
and morphs are still rejected. Failed updates
preserve the model's clips, controller, node matrices, material values,
palettes and deformed vertex buffers. This runtime is an integration
step toward the original game; it does not certify all resources or game flow.

`dc_model_open_static` admits XX-only maps without inventing a clip or XA.
The original archive/XA adapter `0x0045c090` leaves models unchanged when lookup
fails; the map loader `0x0051e3b0` ignores that result and requests clip 1 only
for map selector 1. The first nonscript map, selector 0, has no corresponding
XA in its archive. Static ticks apply the world/hierarchy and any skin palette;
query reports an explicit no-animation sentinel and requests return not-found.

The private map-0 audit loads 98 nodes, 91 meshes, 53 materials and 37 textures.
All 91 meshes project under a synthetic bounded camera. Across two world
matrices, 196 node-global comparisons match the isolated original hierarchy
driver with reference D3DX math exactly. This is not the original game camera,
GPU appearance or scene execution. See `skinning.md` for the weighted path.

The real chapter-3 path now also admits the original map-1 animation
`RPP_10.pp/mn00_01.xa`: its clip 1 spans frames 10–50, binds 35 mode-0 node
tracks to `mm00_01.xx`, and retains four event tracks as bounded opaque views.
`DCGameScene` loads that XA only when the original map archive provides it;
selector 0 and the other audited static maps continue through the explicit
XX-only path. The event dispatcher changes target vertex channels in the
original runtime; that channel update is still outside the native model
controller, so the audit proves map pose motion and admission but not original
effect-channel equivalence.

`dc_scene_update` implements the default, modifier-1 and modifier-2 branches of
`0x00415620`. The default is local times parent-global using row vectors.
Modifier 1 removes the combined translation before postmultiplying its extra
matrix, then restores translation. Modifier 2 premultiplies the extra matrix.
A hidden node suppresses its entire subtree, preserving previous global values.
Parent indices must precede children. Invalid topology or visible unsupported
modifiers/billboards fail atomically. The original hierarchy oracle executes
the pinned recursive driver, constructor and inverse wrapper on synthetic
trees with pure math D3DX43 import boundaries. All 27 compared cases match.
This excludes draw-list submission, GPU rendering and billboards.

XX mesh extraction uses source offsets established by `0x00408f60`: position
at 4/8/12, normal at 32/36/40 and the first UV stream at 44/48 in each 52-byte
record. The weighted path also reads three explicit weights and four byte
indices from offsets 16–31. Triangle indices retain their serialized order. Bounds, finite selected
components and capacities are validated before output writes.

`dc_mesh_project` transforms indexed triangles by a caller-supplied row-vector
matrix and viewport into XYZRHW vertices. Positive reciprocal W is retained
for GPU perspective interpolation. Triangles crossing nonpositive W are
outside this profile and fail explicitly. Lighting, skinning, effect selection,
sorting and automatic camera inference are separate work.

The Vulkan backend accepts explicit preprojected triangle lists through
`dc_vk_geometry_render`. It uses an unlit single-texture diffuse modulation
profile and explicit standard/additive/modulation blend selection. Geometry can
select disabled, read-only or write-enabled D32 depth testing with LESS_OR_EQUAL;
ordinary sprite/overlay draws leave depth disabled. Dedicated
triangle-list pipelines share the existing textures, filtering and surface
presentation. The shader reconstructs clip W from RHW for perspective-correct
UV interpolation; existing sprite vertices keep RHW=1. The pixel gate checks
triangle coverage, a UV result that changes with RHW, alpha modulation and
atomic invalid-input rejection in addition to its earlier sprite regressions.

`dc_vk_geometry_render_region` adds an explicit pixel scissor for a game
viewport inside a larger drawable. The target still clears/readbacks in full;
all draws establish a fresh dynamic scissor, and default geometry/sprite calls
restore the full target. The Apple game scene clips to the pixel centers of
its letterboxed 4:3 viewport. This fixes the generated weighted surface
spilling into black bars; the exact skin-image gate also checks the bars stay
black. It does not replace perspective/frustum clipping. The depth attachment and per-draw modes now
provide map/actor occlusion; original culling and material state remain separate.

These generic primitives do not by themselves prove the original transition's
camera, draw sorting, lighting, texture stage state or final image. Original
resource payloads remain local; public oracle fixtures use self-authored data.

## Startup host connection

`DCStartupScene` loads the two startup cards from `RPP_02.pp` and the transition
XX/XA pair from `RPP_17.pp`. It applies `dc_startup` actions in order and queries
the model's current loop byte before each state update. The original 2,000 ms
and 30,000 ms card timers replace the old fixed two-second title preview. A
new touch maps to the original skip code 3. The model's animation/material/pose
and hierarchy update supplies projected triangles after the card draw.

The camera is based on the static startup camera-5 setup: right-handed
perspective, FOV .5, near .5, far 10000 and inverse camera translation Z=1.5.
Embedded textures bind to the material's first encoded texture name. Current
GPU composition uses the documented single-texture profile; original full
lighting, stage selection, sorting and image equivalence are not established.
Resource/read/profile failures stop the scene explicitly.

Stable-card presentation markers require the waiting flag to clear and the
controller to be on the looping hold clip. Transition presentation has its own
marker. The title marker is emitted only after the startup planner enters its
next state and the title layers successfully present. Later title actions and
gameplay remain unfinished.

The simulator gate also creates its own tiny PP/XX/XA/EMA resources from
`tools/startup_fixture.py`, installs them into the app container, waits through
the normal two-card sequence, requires the ordered presentation markers and
hold times, and captures each stage. No original resources are used or uploaded
for this CI gate. Local native checks separately execute actual transition
model updates and RH projection; they do not establish original GPU output.

The first integrated simulator run exposed a lifecycle bug: status-label size
changes caused the viewport to rebuild its renderer and restart startup from
card 0. `DCStartupScene` now retains its model, controller, timers and decoded
card data while detaching/recreating only GPU textures. Detachment also resets
the last host tick, so background time is not charged as startup elapsed time.
Renderer recreation therefore preserves the game-state progression.

Delayed `simctl screenshot` commands can capture a later card than the marker
that triggered them. The startup fixture gate therefore also enables an
explicit test-only launch environment: on each stable card's successful draw,
the native view reads the exact GPU frame and saves its PNG before advancing
to later frames. The gate copies both frame images from the app container and
checks nine central samples against the generated blue/orange card profiles.
Swapped or repeated-card screenshots fail this check. Normal launches do not
save these captures. UI screenshots remain useful for layout inspection but
cannot alone certify the identity of the earlier card.

## Verified development stage

Source `f199ad86f343051b70144c1337cd3b8b5ea48869` passed app run
`40028786968` and native run `40028825820`. Downloaded artifacts match the
source hashes and bundled resource manifest; all sixteen native objects are
ARM64 Mach-O objects. The unsigned iPhoneOS IPA passed packaging checks.
The generated simulator startup gate observed the two cards, title and music
clock, with 3/31-second stage intervals. Both exact GPU card PNGs pass their
9-sample identity profiles and were visually inspected, along with title and
checker screenshots. The actual Swift importer gate also passed on ARM64
macOS. There is no original full-game or physical-device playability evidence.
