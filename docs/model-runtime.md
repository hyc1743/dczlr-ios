# Model runtime and triangle geometry

`dc_model` connects the existing bounded XX/XA readers, controller, pose and
material samplers, node hierarchy and mesh projector. Inputs stay borrowed;
decoded numeric arrays are owned. The root local matrix becomes identity,
matching the final original loader setup. Pose names bind to the last matching
root descendant; material names bind to the first matching material. Missing
targets are inert. Tracks retain file order and individual model baselines.

The current explicit profile has mode-0 node tracks, material tracks and
unskinned meshes. Crossfades, mode-1 poses, billboard transforms, skin bones,
events and morphs are rejected. Failed updates preserve the model's clips,
controller, node matrices and material values. This runtime is an integration
step toward the original game; it does not certify all resources or game flow.

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
record. IDs, weights and bone indices remain uninterpreted by this unskinned
path. Triangle indices retain their serialized order. Bounds, finite selected
components and capacities are validated before output writes.

`dc_mesh_project` transforms indexed triangles by a caller-supplied row-vector
matrix and viewport into XYZRHW vertices. Positive reciprocal W is retained
for GPU perspective interpolation. Triangles crossing nonpositive W are
outside this profile and fail explicitly. Lighting, skinning, effect selection,
sorting and automatic camera inference are separate work.

The Vulkan backend accepts explicit preprojected triangle lists through
`dc_vk_geometry_render`. It uses an unlit single-texture diffuse modulation
profile and explicit standard/additive/modulation blend selection. Dedicated
triangle-list pipelines share the existing textures, filtering and surface
presentation. The shader reconstructs clip W from RHW for perspective-correct
UV interpolation; existing sprite vertices keep RHW=1. The pixel gate checks
triangle coverage, a UV result that changes with RHW, alpha modulation and
atomic invalid-input rejection in addition to its earlier sprite regressions.

These generic primitives do not by themselves prove the original transition's
camera, draw sorting, lighting, texture stage state or final image. Original
resource payloads remain local; public oracle fixtures use self-authored data.
