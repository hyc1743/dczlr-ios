# Bounded XX model metadata and embedded images

`dc_xx` reads the observed 3.17/3.19 serialized profiles. A validating pass
checks the complete structured prefix and count/depth limits before a second
pass allocates metadata. Source bytes remain borrowed and immutable until
close. Node parents, matrices, submesh indices, 52-byte vertex records,
separate UV streams, material names/values and embedded images retain source
offsets. Bone records are bounded and counted; skinning is not implemented.
Bytes after the last embedded image remain an explicit opaque tail. Eight of
the 83 local models contain such tails; the observed original loader returns
without reading them, and their semantics remain unknown.

`dc_xx_find_material_encoded` accepts an XA encoded name, requires an encoded
NUL and selects the first case-sensitive C-string match in file order.
`dc_xx_material_baseline` negates components 0..15 and preserves component 16,
including signed zeros, within the admitted finite profile. The sampler can
use this baseline for one-key and out-of-interval fallback. Material checksums,
effects, multiple-track update ordering and GPU material binding are excluded.

Embedded `.bmp` and `.tga` names select the existing bounded RGBA decoders.
The explicit `DC_IMAGE_XX_BMP` profile permits a zero BMP signature without
relaxing normal BMP parsing. This performs no texture resampling or mipmaps.
Getters, baseline extraction and image operations reject outputs overlapping
the borrowed model input.

The isolated original material loader, name decoder and checksum routine
match 18 self-authored table comparisons under x87 control words `0x027f` and
`0x037f`. The material function's two exact instruction fragments are admitted
separately; the intervening ten bytes do not execute. Allocation and memcpy
are bounded synthetic boundaries. The public replay fixture contains only
hashes and coverage. Executing checksum code here does not establish its
acceptance policy. These are standalone Unicorn comparisons and Ghidra
exports, not REA Evidence records.

```sh
python tools/oracle_xx_materials.py --exe research/target.exe \
  --output research/native-core/xx-material-original-comparison.json \
  --vectors tests/fixtures/xx-material-original-vectors.json
python -m unittest discover -s tests -p 'test_native_xx.py' -v
```

The local inventory admits 83/83 XX entries in recognized PP archives;
independent iterative Python framing agrees with the recursive C parser.
The unknown PP archive remains excluded. Only the non-character startup
transition was audited with full embedded-image decoding: its two images
match Pillow at every pixel, and its three companion XA material names bind.
The general model inventory checks metadata/baselines, not all image payloads.
Local reports retain hashes/counts rather than names, geometry or pixels.

For that transition, native binding also supplied the actual model baselines
to the existing original one-track sampler oracle. All three bound tracks
matched 122 comparisons at key timestamps, midpoints and outside intervals,
under both x87 profiles. Each sample starts independently from its bound
baseline; this does not establish the original multiple-track driver, live
destination history or GPU result.

The iOS diagnostic uses a reproducible self-authored XX fixture. Its embedded
BMP supplies the checker texture; its material is found by the decoded XA
track name and supplies the baseline used by the numeric sampler. The exact
`PORTLAB_NATIVE_XX_FIXTURE_LOADED` log marker is emitted only after animation
advancement and successful presentation. This validates the resource chain,
not a full model renderer or the original startup scene. Full game flow and
physical-device playability remain unverified.
