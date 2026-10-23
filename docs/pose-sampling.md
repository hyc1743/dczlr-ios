# XA node pose sampling

`dc_xa_pose_track_at` validates the complete XA before returning the encoded
node name, mode and 52-byte key spans. `dc_xa_load_pose_keys` decodes the signed
timestamp followed by twelve binary32 fields without interpreting the mode.
Outputs remain unchanged on framing, capacity or overlap failures. Empty and
absent tracks are distinct.

`dc_pose_select` restores the two binary searches at `0x00412ff0` and
`0x00413080`. It truncates the finite sampling frame toward zero for integer
key selection. The left search can stop at an exact interior match; the right
search continues to its upper bound. Timestamps remain in file order. The
admitted profile requires 2..1,048,576 nondecreasing timestamps. Zero/one keys,
unsorted timestamps and frames outside signed-int32 range fail explicitly.

The mode-0 driver subtracts signed timestamps with 32-bit wrapping before
converting the span to binary32. It separately stores the floating sampling
frame minus the left timestamp to binary32, then stores their quotient.
Coincident timestamps use weight zero. Selection is unclamped. Pose sampling
admits weights from -1 to 2 and rejects extrapolation outside that profile.

`dc_pose_sample` uses quaternion fields 0..3, translation 6..8 and scale 9..11;
fields 4/5 remain opaque. It computes shortest-arc quaternion interpolation,
separate translation/scale interpolation and row-vector matrix composition
`rotation * (scale * translation)`. Input quaternions must be near unit length
and are not normalized. Only mode 0 is implemented; the original mode-1 matrix
decomposition branch remains excluded. Matrix multiplication permits aliased
outputs and rejects nonfinite inputs/results without partial writes.

XX node binding uses the last exact case-sensitive C-string match in preorder,
matching the full recursive traversal at `0x004131f0`/`0x00413270`. Material
lookup keeps its separate first-match rule. Serialized local node matrices
can be copied with `dc_xx_node_matrix`. Neither operation applies a hierarchy,
skinning, shader parameters or GPU draws.

## Verification boundaries

`tools/oracle_pose.py` runs the pinned original key searches, float-to-integer
conversion, vector interpolation, mode-0 driver and trivial constructor in
isolated Unicorn. All keys and node memory are self-authored. Instruction,
write, key immutability and return boundaries are checked. Quaternion/matrix
imports call only pure math exports from the local 64-bit Microsoft D3DX43
reference DLL. This DLL is a comparison boundary, not proof of the original
game's D3DX version or device behavior. Neither the DLL nor original executable
instructions are copied into public fixtures or the product.

The public replay fixture records 182 exact key-selection comparisons and
564 transform comparisons across two x87 profiles. Matrix comparisons allow
`abs(error) <= 5e-5 * (1 + abs(reference))`; the observed maximum absolute error
was about `1.79e-6`. Weight bytes match exactly. Cases include duplicate keys,
negative fractional frames, signed timestamp wrap, arbitrary quaternion axes,
opposite quaternion signs, small angles and bounded extrapolation. Node lookup
also matches twelve isolated original-tree comparisons with synthetic strcmp.
These are standalone local comparisons, not REA Evidence records.

```sh
python tools/oracle_pose.py --exe research/target.exe \
  --d3dx .tools/d3dx-reference/build/native/release/bin/x64/D3DX9_43.dll \
  --output research/native-core/pose-original-comparison.json \
  --vectors tests/fixtures/pose-original-vectors.json
python -m unittest discover -s tests -p 'test_native_pose.py' -v
```

The local key audit covers 81 recognized XA entries, 10,398 pose tracks and
14,884,058 key records. Decoded bytes and offsets match an independent cursor;
this does not establish sampling compatibility for every track or mode. The
unknown PP archive remains excluded. For the non-character startup transition,
all 361 keys decode exactly and 1,446 original-driver/reference-D3DX matrix
comparisons match exactly at key frames, midpoints and outer endpoints. The
track binds to node 2, the common ancestor of three submeshes. Local reports
retain counts and hashes without exporting original motion values or images.

The iOS diagnostic now reads two self-authored pose keys through the XA reader,
binds their encoded target to an XX node, samples its local matrix and projects
its planar translation, rotation and uniform scale into the checker sprite.
`PORTLAB_NATIVE_POSE_ADVANCED` is reported only after a changed transform at
positive animation delta is successfully presented. This is a resource and
numeric integration check. The original transition mesh renderer, node
hierarchy, remaining game flow and physical-device playability are unfinished.
