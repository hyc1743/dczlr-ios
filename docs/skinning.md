# Indexed skinning

The XX reader exposes per-node shared vertex/FVF metadata and bone ranges,
encoded names, serialized indices, matrices and raw three-weight/four-index
records. `dc_xx_bind_bones` follows the original last named root-descendant
match. It preserves missing targets explicitly and never invents an identity
binding for a missing named bone. Isolated original bone loading and binding
match 30 self-authored cases, including duplicate, root-only and missing names.

`dc_skin_palette_update` restores the indexed-world setup in the prefix of
`0x004132e0`: offset matrix times bound global matrix, stored at the serialized
index. Index 255 is skipped and later duplicate indices overwrite earlier ones.
Untouched palette slots retain prior state. Initialization sets identity, as
observed with a host Direct3D9 NULLREF device, including slot 255. The primitive
matches 15 isolated-original prefix cases with reference D3DX matrix calls.

`dc_skin_apply` reconstructs the fourth weight as `1-(w0+w1+w2)` in binary32.
It does not clamp, renormalize or discard index 255. This matters for local
assets whose exported three weights leave small positive or negative residuals
at that slot. Three normal modes preserve input normals, apply weighted inverse
transpose matrices, or additionally normalize. Camera normals and lighting
remain separate operations. Finite affine input and finite output are admitted;
singular normal transforms fail without partial output writes.

The position/projected output matches 528 self-authored FVF111c inputs through
the host Direct3D9 software `ProcessVertices` path. Maximum measured screen
error is 0.0000153 in the synthetic 100x100 viewport. Normal modes are compared
with host D3DX inverse/transpose/vector math. No reference path draws or
Presents, creates a visible window or executes the original game process.
This proves numeric scope, not original shader, lighting or GPU-image identity.

The model runtime now owns source weights and separate committed/scratch
deformed buffers. It samples local animation, updates hierarchy, builds
palettes, deforms geometry, then commits all state only after success. Weighted
positions and normals become world-space; projection uses view-projection
alone, avoiding a second node-world transform. Unskinned meshes retain their
node-local path. Hierarchical hidden flags have a separate draw-admission API.
Current admission requires active non-255 indices to belong to the node's
serialized bone set. The general palette API can preserve state across draws.
Crossfades, morphs and unsupported/keyed event channels remain pending; the
verified map-1 type-0/1 no-key UV event path is now part of model ticking.

A private first-actor audit follows three actual-data animation samples through
384 original pose calls, 675 original hierarchy comparisons and 93 original
palette-prefix calls, then compares 502,524 indexed screen vertices with host
Direct3D software processing. Maximum global-matrix error is 0.00000430 and
maximum screen error is 0.000336 in the synthetic viewport. All 89 meshes are
included, 61 using skinning. Original media and geometry are never exported;
only counts/errors/hashes are retained. This excludes the actual game initializer,
camera, effects/lighting, auxiliary morph model and full gameplay.

The generated Apple startup fixture now has a named bone and animated weighted
quad. Its gate requires changed world-space geometry, successful GPU submission
and an exact-frame textured-surface capture with black letterbox bars, alongside existing card/title/text
checks. Every pixel, key and model in this fixture is self-authored. This is a
host integration check and cannot certify the original game's complete scenes.
