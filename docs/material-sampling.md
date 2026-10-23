# XA material sampling

`dc_material_interpolate` restores the numeric helper at `0x00416cd0`.
`dc_material_sample` restores the selection/fallback behavior for one track in
`0x00416ee0`. The original material consists of 17 scalar components. The
interpolation helper updates 14 of them and preserves destination components
7, 11 and 15. These are destination values from before this call, not forced
values copied from a key or baseline.

The first inclusive interval matching `left.frame <= frame <= right.frame`
wins in file order. Duplicate or unordered timestamps are not sorted away.
One-key tracks and nonmatching intervals copy the complete model baseline.
Zero-key tracks leave the destination unchanged. Target matching, baseline
capture from the XX model and ordering of multiple tracks are host operations;
this API does not claim the original multi-track driver is fully reconstructed.

The original assembly subtracts signed integer timestamps before storing the
span to binary32. The interpolation weight is also stored to binary32 before
the multiply/add chain. Separately casting each timestamp to float changes
results near signed integer limits. Interpolation is non-fused and unclamped,
including explicit pair extrapolation. The C implementation accepts finite
selected inputs and calculated results; invalid inputs fail without modifying
the destination. Preserved or copied baseline components are not numerically
interpreted by that operation. The documented finite profile does not assert
equivalence for every possible x87 floating-point environment or input pattern.

## Verification

The static evidence is the existing standalone, read-only Ghidra export for the
pinned local PE. `tools/oracle_material.py` executes only the 517-byte helper
and 252-byte one-track driver on self-authored keys, with an exact synthetic
bounded memcpy for baseline fallback. Instruction/write spans, return targets,
input keys, output canaries and an instruction budget are checked. It matches
826 calls exactly under x87 control words `0x027f` and `0x037f`, including the
three preserved destination components, zero/one keys, duplicate/unsorted keys,
signed-limit timestamps, endpoint selection and extrapolation. Public fixtures
retain only hashes and coverage; they include no original instructions or assets.

```sh
python tools/oracle_material.py --exe research/target.exe \
  --output research/native-core/material-oracle.json \
  --vectors tests/fixtures/material-original-vectors.json
python -m unittest discover -s tests -p 'test_native*material*.py' -v
```

## Resource and host connection

`dc_xa_material_track_at` validates the whole XA input before returning encoded
name/key offsets and counts. `dc_xa_load_material_keys` decodes the 17 values and
signed timestamp for each 72-byte record into caller-owned memory. Invalid tails,
out-of-range indices, truncated keys, insufficient capacity and overlapping
buffers leave outputs unchanged. Empty tracks return successfully with zero
keys; absent indices return `DC_NOT_FOUND`. Names remain encoded and opaque.

The local audit covers all 81 recognized XA entries: 487 material tracks and
2,902 key records. Track offsets/counts match an independently advanced Python
cursor, and decoded numeric bytes match each serialized key. The audit records
only counts and hashes, without exporting names, material values or asset data.
This is a resource-reader result, not proof of original model linking, runtime
baseline selection, GPU composition or playability. The unknown PP archive
remains outside the audit.

A further local comparison fed the decoded actual key records to both native
sampling and the isolated original one-track functions. All 487 tracks passed
12,582 exact output comparisons at key timestamps, adjacent midpoints, zero and
outer endpoints, under both selected x87 profiles. There were no skipped tracks.
Targets and baselines were synthetic; this result still does not recover the
model's baseline values, target lookup, multiple-track order or GPU output. Only
counts and output digests were retained in the local report.

```sh
python tools/audit_native_xa.py --data Data \
  --reference research/native-core/xa-framing-audit.json \
  --output research/native-core/native-xa-material-audit.json
```

The iOS checker now constructs a self-authored material track alongside its
rotation clip. Both come through the native XA reader; the animation sample
selects the material value, which controls Vulkan sprite alpha. The host reports
`PORTLAB_NATIVE_MATERIAL_ADVANCED` only after a positive-delta animation sample
changes alpha and the resulting frame presents. The simulator gate requires
this marker in addition to scene, XA and animation markers. The original game
assets are not supplied to this cloud gate.

Source `3186da484ca00c8946f1486b95486dcf4078092d` passed 98 portable tests,
device IPA packaging and the iPhone 16 Pro/iOS 18.5 simulator pipeline in run
`39980622644`. The app log reports scene presentation, XA decoding, animation
advancement and changed material alpha followed by presentation. The inspected
screenshot shows the self-authored sprite and material status. Run `39980656755`
passed 66 ARM64 macOS native tests and explicit iPhoneOS SDK compilation including
`dc_material.o`. Downloaded artifacts matched the pinned source hashes; the IPA
was inspected as unsigned ARM64/iPhoneOS with the matching resource manifest.
This verifies the diagnostic material pipeline, not original game/device playability.

Original material-name binding to the XX model, fullscreen transition geometry,
pose sampling, full startup composition and later game states remain incomplete.
