# Resource Release

`Data` is about 2.55 GB and is not embedded in the source repository or IPA. The generated manifest is only about 40 KB and is embedded in the iOS app. The original local inventory contains 132 files and is divided into three parts, each no larger than 1 GB:

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

The exact hashes and file segments are in `ios/Resources/DczlrData.manifest.json`. The three `.dczdata` files must be published as separate GitHub Release assets. They must not be committed to Git or embedded in the IPA.

## Build the parts locally

Run from the project root with the legal local `Data` directory:

```powershell
python tools/pack_resources.py pack --data Data --out out/resource-packs --part-bytes 1000000000
python tools/pack_resources.py verify --parts out/resource-packs --data Data
```

The packer streams files in deterministic path order, permits a file to cross a part boundary, writes SHA-256 hashes, and refuses an existing output directory. Upload the three `.dczdata` files to a Release without renaming them. The manifest in the IPA must come from the same source tree and source identity.

## Import on iOS

Install the unsigned/signed IPA, open it once so the app creates its Documents directory, then copy all three `.dczdata` files with the Files app or Apple Devices file sharing to the app root. `ResourcePacks/` is also accepted. On the next foreground launch, the app reads its bundled manifest, verifies every part hash and size, and restores files into `game/Data` using temporary files and SHA-256 checks. Missing or modified parts are reported in `log.txt` and are not imported.

The current repository contains the host, manifest and build workflow. It does not contain a real converted D3DX/Metal game runtime or a signed IPA; the GitHub workflow currently builds the PortLab host and an unsigned test IPA until the native guest and shader conversion are implemented.

Import is resumable at the file level: an existing destination file is skipped only when its size and SHA-256 match the bundled manifest. Partial or modified files are replaced through a temporary file after a complete hash check.
