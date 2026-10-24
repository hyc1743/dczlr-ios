# XL light reader

The local `RPP_07.pp` map-light records use an observed `LLL\0` prefix. A
one-byte count is followed by variable-length records. The same record
decoder also admits the one-light `RPP_10.pp` map variants, whose four-byte
prefix stores map-specific opaque bytes instead of the `LLL\0` marker. Each
record contains two
XOR-`0xff` encoded, `0xff`-terminated names, a five-byte tag/flag header, 41
little-endian floats, and no trailing bytes.

The native `dc_xl_probe` and `dc_xl_light_at` APIs validate the complete
container before exposing borrowed spans and the numeric groups. The float
groups are kept in their serialized order: three RGBA groups, position and
direction vectors, five light parameters, and a 4×4 transform. Unknown tag bytes
remain visible through the kind/enabled/flags fields; no shader or lighting
semantics are guessed by the reader.

`DCGameScene` now loads both the selector-matched `RPP_07.pp` light set and the
map-specific `RPP_10.pp/mp00_%02u.xl` record during initialization and on every
map transition. A malformed or missing light record fails the scene transition
instead of silently falling back to generated lighting. The current renderer
still uses the parsed records only as validated scene state; original GPU
lighting and effect selection remain separate work.

The local audit command is:

```powershell
python tools/audit_native_xl.py --data Data --output research/native-core/native-xl-audit.json
```

The audit records hashes and decoded labels only. It does not export resource
payloads or claim original GPU execution.
