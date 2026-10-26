# iOS PortLab

This project reconstructs the supplied Windows x86 game as native ARM64 modules
for an iOS host using Vulkan ? MoltenVK ? Metal. There is **no complete playable
game release yet**. Existing IPAs are development stages; producing a package,
passing a synthetic scene or recovering resource bytes does not complete the port.

The reference chain is Windows ? upstream native Switch reconstruction ?
weixing3 iOS adaptation. This project uses the same kind of module reconstruction
and isolated original-function comparisons, then compiles directly for iOS ARM64.
It does not require a Switch intermediate, CPU interpreter or Wine in the chosen
product. See [the reference comparison](docs/weixing3-porting-method.md) and
[native architecture](docs/native-runtime-design.md).

The implemented resource/runtime chain includes bounded PP and BMP/TGA/EMA
readers, XX nodes/materials/embedded images, rigid and indexed-skinned meshes, XA clips and
material/node keys, numeric animation/material/pose sampling, node hierarchy,
triangle projection and Vulkan rendering. Original-function oracles and local
resource audits document their admitted profiles; skinning, complete effects,
billboards and the full scene/game engine remain unfinished.

The Apple host now loads both startup cards and their transition model from
local archives, follows the original two-card action planner, and presents title
layers after its normal waits. CPU scene state survives renderer resize and
background GPU recreation. Title music and selection sound use archive-backed
AVAudioPlayer; pointer hover and selection use the reconstructed menu helper.
Existing save prefixes supply title unlock flags. The original 26-chapter story
dispatcher is integrated: numbered script chapters alternate with gameplay,
watch, night and ending scene chapters through the recovered static tables.
The chapter-end menu follows the original action codes (advance, edit,
save menu, fade), gameplay rows follow the original shared menu activation
dispatch, and the story state persists in the host save record. The first
observed gameplay menu route uses the original six-row hit table and chains
the first two verified map-0 voice records. The local
`tools/native_playable_session.py` runner exercises that route with real
resources, model/audio probes and file saves across all eight maps. Apple
rendering execution and the remaining event/script/audio routing remain to
be verified.

Public CI uses entirely generated fixtures. The inspected app stage, source
`f199ad8`, passed 146 portable tests, 107 ARM64 native tests, compilation of 16
iPhoneOS objects, device IPA packaging, a checker scene and generated fullscreen
two-card / title / audio-clock gates. Runs: app `40028786968`, native
`40028825820`. Exact stable-frame GPU readbacks distinguish both cards with
nine central color samples each; captures, title and checker screenshots were
inspected. Delayed system screenshot labels are not used for earlier-card
identity. The actual Swift importer also passed its generated three-part
roundtrip/recovery/preservation/corruption/path/oversized-segment gate.
Physical-device execution, audible output, original GPU equivalence and
complete-game playability remain unverified.

The intro reader matches 434 opaque numbered-record spans across 19 local
scripts, preserving cursor order for 52 repeated IDs. The new-game numeric
initializer matches all 59,960 bytes from the isolated original helper. Script
commands, glyph layout, voice sequencing and new-game state dispatch remain
unfinished; these numeric/reader results do not make gameplay available.

Implementation and verification details:

- [Story dispatch and chapter-end menu](docs/story-dispatch.md)
- [Game-specific touch controls](docs/touch-controls.md), [optional keyboard/mouse panel](docs/windows-controls.md), [original Windows input evidence](docs/windows-input-evidence.md)
- [Current runtime completeness audit](docs/runtime-completeness.md)
- [Model runtime, startup connection and triangle geometry](docs/model-runtime.md)
- [Animation controller](docs/animation-reconstruction.md), [material sampling](docs/material-sampling.md), [node pose sampling](docs/pose-sampling.md)
- [XX reader](docs/xx-reader.md), [XA reader](docs/xa-reader.md), [XL light reader](docs/xl-reader.md), [eyes/neck reader](docs/eyeneck-reader.md), [script framing](docs/script-framing.md)
- [Menu input](docs/menu-input.md), [title audio](docs/title-audio.md), [audio slot audit](docs/audio-slot-audit.md), [save-prefix metadata](docs/save-metadata.md)
- [Vulkan pixel gates](docs/vulkan-sprites.md), [offline effect/shader tools](docs/effect-conversion-tools.md)

## Local resource packages

The 132 local Data files total 2,551,369,384 bytes. Three generated packages stay
under ignored `out/resource-packs/`: 1,000,000,000 bytes, 1,000,000,000 bytes and
551,369,384 bytes. Package hashes and original files were verified using the
bundled app manifest; a complete restore also matched every file hash. Original
resources are not uploaded by the app workflows and are not bundled into the IPA.
The remaining unknown PP archive and runtime format coverage are separate
compatibility work; a package roundtrip does not establish that every game
resource is executable/renderable yet.

Windows development does not require macOS. The real local resource loop can be
audited with `tools/audit_playable_loop.py --data <local Data> --output <report>`;
see [Windows native validation](docs/windows-native-validation.md). This uses
the same native module boundary as the iOS host and keeps the original `Data`
directory outside the repository.

For a manual local session, run `python tools/native_playable_session.py --data
Data`; enter `i` to complete an interaction and advance, `m dx dz` to move, and
`s`/`l` to save or restore `Data/save/player.state`. Add `--load` to start from
that saved map. The runner validates the real actor, face, animation, eyes/neck,
map and first voice-chain resources before accepting input.

## Previous interpreter experiment

The manually dispatched `runtime-ios-app.yml` workflow now builds `PortLab-interpreter-unsigned.ipa` with the genuine 32-bit interpreter, launch bridge and frontend. Build `39877459414` succeeded, and its IPA was inspected as an iOS-device ARM64 executable with the interpreter entry point linked. JIT is not required by that build. Wine's runtime ZIP must still be supplied separately, original game files are not bundled, and iOS guest boot and target-device playability remain unverified.

Wine console execution has passed on the ARM64 macOS runner in run `39878555474`: the genuine no-JIT interpreter produced the exact guest-output line `PORTLAB_WINE32_OK` in 31.08 seconds. The host was subsequently stopped by the bounded harness; normal shutdown was not demonstrated. This console-only profile disables optional HTML/.NET installers. It does not prove iOS execution, graphics, audio or game compatibility. The same workflow now also builds and runs a self-authored PE32 probe for file roundtrips, thread/event synchronization, offscreen GDI pixel readback and WinMM buffer completion through a dummy SDL audio device. These additional checks require their own successful guest markers.

Those four self-authored PE32 checks passed on ARM64 macOS in run `39879664469`, with all subsystem markers and `PORTLAB_WIN32_OK` observed. The report records 27.16 seconds and a harness-controlled shutdown. The PCM log shows conversion from 22050 Hz to 44100 Hz. The iOS build now stages the same probe with a **Run Win32 compatibility check** button and a dedicated diagnostic prefix. It requires importing the Wine runtime ZIP through Settings first. The button is an entry point for future phone verification, not evidence of a device pass.

The app with the bundled check and persistent-report viewer built successfully in run `39880869873` from revision `45f7976`. Its downloaded IPA was checked as ARM64/iPhoneOS, and its PE32 probe matches the compiler artifact from that same run. IPA SHA-256: `32d5bf3f971814c616c6900ac516421abb26a5f8d52e4a1e3d15843c3d1a5040`. The probe also passed a native Windows control run and wrote all six report lines. Follow [runtime-device-check.md](docs/runtime-device-check.md) for the remaining phone verification.

The persistent-report variant also passed the real no-JIT Wine gate in run `39881581198`: all four subsystem markers, the final guest-output marker and the guest-written report's six lines were verified. The Win32 run's elapsed time was 36.82 seconds including harness cleanup; this is not a phone performance result. Normal host shutdown, device execution, D3D9 and playability remain unverified.

The default `build-ios.yml` and `release-ios.yml` workflows produce the native development-stage `DCZL-R-unsigned.ipa` (display name `DCZL R`). They do not produce the earlier interpreter experiment or certify a playable release.

The host already has the resource import contract needed for a future port. A bundled manifest describes 132 local `Data` files split into three release assets, each no larger than 1 GB. The assets are intentionally outside Git history and the IPA.

## Build in GitHub Actions

The `Build PortLab iOS IPA` workflow runs portable Python checks on Ubuntu, then prepares pinned MoltenVK, compiles the self-authored sprite shaders and builds the Swift/native Vulkan host on macOS. The default manual run builds and exercises the simulator path only. The unsigned device IPA job is guarded by the `build_ipa` workflow input and remains off until Apple-side gameplay validation is complete. A developer must sign the device app with their own Apple identity before installation.

The workflow does not download or embed the local game data. Keep generated
resource parts local and copy them into the installed app when needed.

For simulator gameplay on GitHub Actions, local parts can be packed into an
AES-GCM encrypted bundle with `tools/encrypted_resource_parts.py`. Supply its
HTTPS URL and SHA-256 through the workflow inputs, or split the bundle into
ordered sub-1-GB URLs and hashes. Keep the 32-byte key in the
`DCZLR_RESOURCE_KEY` Actions secret. The macOS job decrypts only into its
temporary workspace, stages the parts, and records simulator gameplay evidence.

The same workflow accepts a private resource repository through
`resource_repo`, `resource_ref` and `resource_path`. Store a read token in the
`DCZLR_RESOURCE_REPO_TOKEN` Actions secret. The macOS job checks out the
plaintext parts only into its temporary workspace, verifies all three parts,
and runs the simulator gameplay check without publishing the resources.

Pushing a tag such as `v0.1.0` runs `release-ios.yml`, creates or updates a GitHub
Release, and uploads `DCZL-R-unsigned.ipa` plus the resource manifest. The three
`.dczdata` files stay local under the current delivery arrangement.

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
