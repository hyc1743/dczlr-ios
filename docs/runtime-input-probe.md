# Original runtime input probe

`tools/frida_directinput_probe.py` launches the local PE32 executable suspended,
installs a Frida agent, resumes it, clicks the existing startup dialog button
`1012`, and records DirectInput COM calls plus `ReadFile` reads from local PP
archives. The agent hooks `IDirectInputDevice8::GetDeviceState` through the COM
vtable. Keyboard pulses are written only into the returned 256-byte state
buffer; mouse probes use the returned 16-byte state buffer. The executable and
its resources are not modified.

The first title menu uses a 1280x960 window with a 1.25 scale. Its first menu
rectangle is `x=702..958`, `y=400..448`, so the corresponding window input
coordinate is about `(1038,529)`. Two consecutive menu frames return the
original selection results `3` then `1`, after which the original callback
opens `RPP_16.pp`.

For the local chapter-3 resource experiment, the probe forced the existing
dispatcher state in process memory after the intro had loaded:

```powershell
python tools/frida_directinput_probe.py `
  --duration 65 --start-after 5 `
  --force-menu 1038:529:3:5 `
  --force-chapter 50:3 `
  --output research/native-core/directinput-frida-force-chapter3b.json
python tools/correlate_audio_runtime.py `
  --probe research/native-core/directinput-frida-force-chapter3b.json `
  --data Data `
  --output research/native-core/audio-runtime-force-chapter3b-correlation.json
```

The observed chain reaches `0x00512cc0` and loads `RPP_10`, `RPP_08`, `RPP_09`,
`RPP_04`, `RPP_15`, `RPP_03`, `RPP_14` and `RPP_11`. The forced dispatcher is
an evidence aid for the unfinished original input path; it is not a claim that
the iOS port should write these state fields. Runtime audio is still device
untested, and the local PP data remains outside the public repository.

The chapter-3 gameplay menu contains six entries. The first active target is
stored at logical `x=920..1016`, `y=328..424` with the same `1.25` window scale,
so its window-space center is about `(1200,470)`. A forced probe reaches the
original menu result `3`; the following action transition additionally checks
the context mode at `+0x504`, the action input byte at `+0x261`, and the local
state flags before calling `0x00532240`. These gates are now observable in the
probe, while a real user interaction still needs to drive them naturally.

A follow-up bounded run now drives the menu in its original order: five hover
frames with input code `0`, followed by five release frames with input code
`3` at `(1200,470)`. The original menu returns `2` while the row is first
entered and `1` on release, confirming activation of row 1. The captured menu
table has six rows: row 1 at `(920,328,96,96)`, disabled row 2 at
`(920,440,96,96)`, rows 3 and 4 at y `552` and `664`, and row 5 at
`(0,504,352,264)`. The same run loads the post-action `RPP_11.pp` records;
the report is kept locally as
`research/native-core/directinput-frida-gameplay-natural-menu.json`.

The iOS gameplay scene now uses this six-row table and the same hover/release
codes through `dc_menu_step`. Its existing near-target touch path remains as a
compatibility input for the local playable-loop exercise; menu activation and
near-target admission are kept as separate state gates.

On a normal launch, completing an interaction leaves the current map active
while the observed voice chain plays. The trigger for the original map change
is still unresolved; repeated row-1 activation alone did not load another map
in the bounded Windows probe. The simulator exercise sets
`PORTLAB_EXERCISE_REAL_GAMEPLAY=1` and keeps the bounded automatic map sequence
only for host-side coverage of all eight local maps.

A two-action forced probe confirms the boundary: a second hover/release pair at
the same row returns menu result `1`, but does not open a new `RPP_11.pp` voice
record or reload `RPP_10.pp`. The map-change caller and its state prerequisites
therefore remain open; the probe is retained locally as
`research/native-core/directinput-frida-gameplay-two-actions.json`.

Static recovery narrows that caller: `0x00598a50` reads a context field at
`+0x305c`, selects from the original map table `[0,1,3,4,5,6,7,8]`, writes
`main+0x13533`, and calls `0x0051e3b0`. The story-state table feeding this
route is now exposed and tested as `dc_game_story_map_selector`; dynamic
evidence still does not show which user action sets the required context field.
The Frida agent now observes `0x005f9561`, `0x00598a50` and the context getter
`0x005ffd90`, plus the context setter `0x005feeb0`; the natural voice probe
did not enter any of these gates or write the map-context value.

The simulator resource check is optional and can run in the public macOS workflow; it is not required for the Windows native validation path. When a built simulator app is available, local resource packs can be staged without putting them in the repository:

```text
python tools/check_ios_sprite.py --app <PortLab.app> --runtime iOS-18-5 \
  --expected-scene gameComplete --exercise-real-gameplay \
  --resource-parts out/resource-packs --output out/ios-real-resources
```

The tool verifies every part against `DczlrData.manifest.json`, copies them to
the simulator's `Documents/ResourcePacks`, sends touch pulses through the
normal input adapter, and records the staging manifest plus gameplay markers.

For a GitHub macOS run, the same parts can be supplied as an encrypted bundle
without committing plaintext resources. Create it locally with:

```powershell
python tools/encrypted_resource_parts.py pack `
  --parts out/resource-packs `
  --output out/dczlr-resources.dczenc `
  --key-env DCZLR_RESOURCE_KEY
```

Store the 32-byte key in the Actions secret `DCZLR_RESOURCE_KEY`, publish the
encrypted file at a controlled HTTPS URL, and start `Build PortLab iOS IPA`
with `resource_bundle_url` and `resource_bundle_sha256`. The macOS job verifies
the bundle hash, decrypts each AES-GCM chunk into its temporary runner directory,
stages the parts into the simulator, and runs the `gameComplete` gameplay check.
The decrypted files are removed with the runner workspace.
