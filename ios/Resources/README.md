# Resource bundle contract

The iOS host reserves one converted effect file per verified PE resource identifier:

```text
IDR_BUMP.bin
IDR_CUBE.bin
IDR_GLARE.bin
IDR_PARA.bin
IDR_SPRITE.bin
IDR_TOON.bin
IDR_WATER.bin
```

The source payloads are D3DX9-effect candidates, not Metal libraries. These files
are not populated yet. The metadata-only manifest at
`../research/ios-resource-manifest.json` records source ranges and hashes from
REA. A future converter must identify each payload format, write the converted
file atomically, and update `decoded_format` with independent validation. The
host must reject the original D3DX magic or an unrecognized format instead of
treating arbitrary bytes as a Metal library.

The required manifest shape is in `converted-effects.schema.json`. The host
must verify its schema and source identity before loading a `.metallib`.
