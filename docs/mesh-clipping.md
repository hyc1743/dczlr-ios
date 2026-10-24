# Mesh clipping before perspective division

`dc_mesh_clip_project` transforms an indexed triangle list and clips each
triangle against `-w <= x <= w`, `-w <= y <= w`, `0 <= z <= w` before dividing
by W. It retains the visible polygon, interpolates UVs along homogeneous edges,
and triangulates that polygon into the existing XYZRHW layout. The GPU's
reciprocal-W path then preserves perspective-correct texture interpolation.

Triangles entirely outside the frustum produce no vertices. An input vertex
with nonpositive W does not reject an otherwise visible mesh. Surviving
vertices must have positive W and finite projected values. Edge interpolation
uses double precision after the existing float32 matrix transform; intersection
positions are placed exactly on the current clipping plane. The old bounded
`dc_mesh_project` interface remains available for its original profile.

Output counts vary. Query with `out=NULL, capacity=0`, allocate the resulting
count and call again. Invalid input, insufficient capacity or overlapping
buffers preserve both the vertex output and count. Inputs, capacity and
result are bounded to 1,048,576 vertices/indices. A successful empty result is
valid and needs no draw submission.

`dc_model_project_clipped` applies the same local/world distinction as the
existing model projector: rigid vertices receive node-global times VP, while
already skinned world-space vertices receive VP only. The startup host now
uses this interface, together with `dc_camera_build` for its existing camera.
Its explicit game-region scissor remains in effect.

Portable tests cover analytic near/eye-plane crossings and UV intersections,
all six planes, empty results, original projection agreement, rigid/skinned
spaces and atomic failure. The Vulkan pixel gate includes a self-authored
triangle with a W=0 input and checks the visible clipped polygon. Apple/Vulkan
results must be checked separately before certifying those runtime paths.

The local numeric map audit processes all 91 meshes under each of the three
candidate game presets without a nonpositive-W rejection. It produces 193,
1,480 and 2,613 surviving triangles respectively, including newly clipped
portions. This establishes geometry admission under those candidate matrices,
not original camera selection or scene appearance. Depth, culling, original
materials/lighting/effects and gameplay initialization remain separate work.
