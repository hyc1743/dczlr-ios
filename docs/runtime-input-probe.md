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
