# iOS PortLab

This repository contains an experimental iOS interpreter runtime and a separate diagnostic host. There is no verified playable game release yet.

The manually dispatched `runtime-ios-app.yml` workflow now builds `PortLab-interpreter-unsigned.ipa` with the genuine 32-bit interpreter, launch bridge and frontend. Build `39877459414` succeeded, and its IPA was inspected as an iOS-device ARM64 executable with the interpreter entry point linked. JIT is not required by that build. Wine's runtime ZIP must still be supplied separately, original game files are not bundled, and guest boot and target-device playability remain unverified.

The default `build-ios.yml` and `release-ios.yml` workflows still produce the earlier diagnostic `PortLab-unsigned.ipa`. Those are platform tests, not the interpreter runtime or a playable game release.

The host already has the resource import contract needed for a future port. A bundled manifest describes 132 local `Data` files split into three release assets, each no larger than 1 GB. The assets are intentionally outside Git history and the IPA.

## Build in GitHub Actions

The `Build PortLab iOS IPA` workflow runs portable Python checks on Ubuntu, then generates and builds the Swift/Metal host on macOS. It uploads an unsigned simulator app and an unsigned device IPA. A developer must sign the device app with their own Apple identity before installation.

The workflow does not download or embed the local game data. Publish the resource parts separately as GitHub Release assets after generating them locally.

Pushing a tag such as `v0.1.0` runs `release-ios.yml`, creates or updates a GitHub Release, and uploads `PortLab-unsigned.ipa` plus the resource manifest. The three `.dczdata` files must be uploaded separately from a machine that has the local `Data/` directory.

The repository intentionally ignores the local `Data/` directory, original Windows binaries, local `research/` outputs, generated IPA files and `.dczdata` parts. Only the small resource manifest is committed to the app bundle. Research commands regenerate their local reports from separately supplied inputs.

Every CI workflow validates the same release contract before building: the manifest must describe exactly three ordered parts, each at most 1 GB, with SHA-256 values and contiguous file segments. The round-trip test runs on Windows and on the GitHub Ubuntu runner; a restricted shell may require permission to create temporary fixtures.

## Generate resource parts

```powershell
python tools/pack_resources.py pack --data Data --out out/resource-packs --part-bytes 1000000000
python tools/pack_resources.py verify --parts out/resource-packs --data Data
```

Copy the three generated `.dczdata` assets to the installed app's Documents root or `ResourcePacks/`. On the next launch, the app validates part names, sizes, SHA-256 hashes and every file segment before restoring to `game/Data`.

See [resource-release.md](docs/resource-release.md) for the release contract and [ios-port-plan.md](docs/ios-port-plan.md) for the remaining native guest and shader work.

License and asset boundaries are documented in [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md). Use [public-repo-checklist.md](docs/public-repo-checklist.md) before publishing a repository or Release.
