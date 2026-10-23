# iOS PortLab

The intended architecture is now native AArch64 game execution with a focused Apple-platform host and Vulkan → MoltenVK → Metal graphics. Original shader semantics still need offline recovery and conversion. See [native-runtime-design.md](docs/native-runtime-design.md) for the requirements and the current missing input: the supplied main executable is PE32 x86, and no usable AArch64 version or source build has been established. There is no verified playable game release yet.

The Windows-to-Switch reference source has now been located: `ruje0504-2/biko3-switch-runtime`, pinned at `63fddc3830b991e725657689934c3b6e3b5786bb`. Its published NRO hash and size match the local `weixing3` input. Its native reconstruction, isolated original-function comparisons and modular Vulkan approach are reviewed in [weixing3-porting-method.md](docs/weixing3-porting-method.md). This source match has not yet been reproduced by rebuilding the NRO, and no upstream implementation was imported into this product.

The existing interpreter IPA belongs to an earlier experiment and does not satisfy this native architecture. Its phone checks are optional historical diagnostics, not a prerequisite for the native route.

Native reconstruction has started with the indexed PP resource reader in `native/`. Its byte decoder matches the pinned original x86 leaf on 163 offline cases, while the native archive audit covers 71 recognized local archives and 5,011 entries. One archive remains unrecognized. These are resource-module results, not a complete game. [native-modules.md](docs/native-modules.md) records the exact coverage; `native-core.yml` tests the C module on ARM64 macOS and compiles it for iPhoneOS.

The native image layer now decodes standalone BMP, TGA (including RLE) and EMA
entries into bounded, top-left RGBA8 buffers. All 1,409 such entries in recognized
local archives match Pillow pixel-for-pixel. The Apple archive adapter exposes
these decoded buffers to future texture uploads; game rendering and game logic
remain incomplete. This comparison does not cover textures embedded in models
or original D3DX sampling and resizing behavior.

The offline effect reader now restores the seven original effect record graphs,
including pass bindings and shader-array alternatives. Its 158 declared shader
ranges (135 unique hashes) pass independent D3DX length/disassembly checks.
The sprite effect explicitly disables both programmable shader stages. Its
admitted fixed-function sprite profile now has a reconstructed native Vulkan backend. These are
offline recovery results; no game shader has yet been validated on the iOS GPU.
See [effect-conversion-tools.md](docs/effect-conversion-tools.md).

All 135 unique original shaders now translate offline to SPIR-V and pass
Vulkan 1.0 validation with a pinned vkd3d 2.1 tool plus scoped LGPL legacy
instruction extensions. The native sprite entry state, draw submission and
vertex generation are also reconstructed and checked against isolated original
routines. The native Vulkan sprite backend now passes numeric pixel gates on
Mesa lavapipe (zero validation errors), a local Intel UHD 630 GPU, and MoltenVK
on an Apple Paravirtual GPU. The Apple gate also exercises actual Metal surface
acquire/blit/present. The iOS host uses this route for a self-authored sprite
scene; physical iPhone execution remains unverified. Original effect integration and
game flow remain incomplete; this is not a playable release. See
[vulkan-sprites.md](docs/vulkan-sprites.md).

The first two-card startup update is also reconstructed as a native state/action
planner. Its 5,600 isolated original-function comparisons pass, including exact
skip input, ordered transition actions and unsigned timer wrap. It is not yet
connected to the view's game flow; the external transition controller and next
states remain incomplete. See [startup-reconstruction.md](docs/startup-reconstruction.md).

## Previous interpreter experiment

The manually dispatched `runtime-ios-app.yml` workflow now builds `PortLab-interpreter-unsigned.ipa` with the genuine 32-bit interpreter, launch bridge and frontend. Build `39877459414` succeeded, and its IPA was inspected as an iOS-device ARM64 executable with the interpreter entry point linked. JIT is not required by that build. Wine's runtime ZIP must still be supplied separately, original game files are not bundled, and iOS guest boot and target-device playability remain unverified.

Wine console execution has passed on the ARM64 macOS runner in run `39878555474`: the genuine no-JIT interpreter produced the exact guest-output line `PORTLAB_WINE32_OK` in 31.08 seconds. The host was subsequently stopped by the bounded harness; normal shutdown was not demonstrated. This console-only profile disables optional HTML/.NET installers. It does not prove iOS execution, graphics, audio or game compatibility. The same workflow now also builds and runs a self-authored PE32 probe for file roundtrips, thread/event synchronization, offscreen GDI pixel readback and WinMM buffer completion through a dummy SDL audio device. These additional checks require their own successful guest markers.

Those four self-authored PE32 checks passed on ARM64 macOS in run `39879664469`, with all subsystem markers and `PORTLAB_WIN32_OK` observed. The report records 27.16 seconds and a harness-controlled shutdown. The PCM log shows conversion from 22050 Hz to 44100 Hz. The iOS build now stages the same probe with a **Run Win32 compatibility check** button and a dedicated diagnostic prefix. It requires importing the Wine runtime ZIP through Settings first. The button is an entry point for future phone verification, not evidence of a device pass.

The app with the bundled check and persistent-report viewer built successfully in run `39880869873` from revision `45f7976`. Its downloaded IPA was checked as ARM64/iPhoneOS, and its PE32 probe matches the compiler artifact from that same run. IPA SHA-256: `32d5bf3f971814c616c6900ac516421abb26a5f8d52e4a1e3d15843c3d1a5040`. The probe also passed a native Windows control run and wrote all six report lines. Follow [runtime-device-check.md](docs/runtime-device-check.md) for the remaining phone verification.

The persistent-report variant also passed the real no-JIT Wine gate in run `39881581198`: all four subsystem markers, the final guest-output marker and the guest-written report's six lines were verified. The Win32 run's elapsed time was 36.82 seconds including harness cleanup; this is not a phone performance result. Normal host shutdown, device execution, D3D9 and playability remain unverified.

The default `build-ios.yml` and `release-ios.yml` workflows still produce the earlier diagnostic `PortLab-unsigned.ipa`. Those are platform tests, not the interpreter runtime or a playable game release.

The host already has the resource import contract needed for a future port. A bundled manifest describes 132 local `Data` files split into three release assets, each no larger than 1 GB. The assets are intentionally outside Git history and the IPA.

## Build in GitHub Actions

The `Build PortLab iOS IPA` workflow runs portable Python checks on Ubuntu, then prepares pinned MoltenVK, compiles the self-authored sprite shaders and builds the Swift/native Vulkan host on macOS. It uploads an unsigned simulator app and an unsigned device IPA. A developer must sign the device app with their own Apple identity before installation.

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
