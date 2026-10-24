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

On a macOS host with Xcode and a built simulator app, local resource packs can
be staged without putting them in the repository:

```text
python tools/check_ios_sprite.py --app <PortLab.app> --runtime iOS-18-5 \
  --expected-scene intro --exercise-new-game \
  --resource-parts out/resource-packs --output out/ios-real-resources
```

The tool verifies every part against `DczlrData.manifest.json`, copies them to
the simulator's `Documents/ResourcePacks`, and records the staging manifest.
