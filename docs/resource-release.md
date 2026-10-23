# Resource Release

`Data` is about 2.55 GB and is not embedded in the source repository or IPA. A small generated manifest is embedded in the iOS app. The original local inventory contains 132 files and is divided into three parts, each no larger than 1 GB:

```text
DczlrData.part001.dczdata  1,000,000,000 bytes
DczlrData.part002.dczdata  1,000,000,000 bytes
DczlrData.part003.dczdata    551,369,384 bytes
```

Current source-tree manifest hashes:

```text
DczlrData.part001.dczdata  73d7afb8fb32e22b2332c1fe662c7551544997cbe0b76d9a7f9a0b71deb1da8e
DczlrData.part002.dczdata  b2bbb758fb766ed6950eb0eba41e44c9d2bcb3b78af575e7f4ef8cf5afa72774
DczlrData.part003.dczdata  007009a2a61a95a79fe095e72c9af19183d81f994b416358df2d3cfc83633109
```

The exact hashes and file segments are in `ios/Resources/DczlrData.manifest.json`.
Under the current delivery arrangement, all three `.dczdata` files stay local.
They are not committed, embedded in the IPA or uploaded to the public repository.

## Build the parts locally

Run from the project root with the legal local `Data` directory:

```powershell
python tools/pack_resources.py pack --data Data --out out/resource-packs --part-bytes 1000000000
python tools/pack_resources.py verify --parts out/resource-packs --data Data
```

The packer streams files in deterministic path order, permits a file to cross a
part boundary, writes SHA-256 hashes, and refuses an existing output directory.
Keep the three files local without renaming them. The app's bundled manifest
must match their deterministic stream and source identity. The generated local
parts have been checked against that manifest and completely restored with all
132 file hashes matching.

## Import on iOS

Install the unsigned/signed IPA, open it once so the app creates its Documents directory, then copy all three `.dczdata` files with the Files app or Apple Devices file sharing to the app root. `ResourcePacks/` is also accepted. On the next foreground launch, the app reads its bundled manifest, verifies every part hash and size, and restores files into `game/Data` using temporary files and SHA-256 checks. Missing or modified parts are reported in `log.txt` and are not imported.

While an import is active, the game resource directory is not handed to the
renderer. It becomes available only after the importer completes. Missing or
corrupt parts keep the import UI active; its retry control can restart checking
after the local files are corrected. Directly supplied Data remains supported
when no resource parts are present.

The repository contains reconstructed native modules, the Apple host, manifest
and build workflow. IPAs remain unsigned development stages, with complete
gameplay and real game save/load unfinished.

Import is resumable at the file level: an existing destination file is skipped only when its size and SHA-256 match the bundled manifest. Partial or modified files are replaced through a temporary file after a complete hash check.

Existing `.sav` and `.cfg` files are preserved rather than overwritten with
packaged defaults. The native-core workflow compiles and runs the actual Swift
importer against three generated small parts, checking mixed root/ResourcePacks
locations, cross-part restoration, stale/partial repair, save/config preservation,
corrupt-part rejection and malformed-path/oversized-segment rejection. This gate
uses no original resources; the separate local full-data roundtrip covers the
real package bytes.
