# RPP14 audio slot audit

`tools/audit_audio_slots.py` inventories the local `RPP_14.pp` WAV entries and
records only hashes and metadata. It also records the static bindings recovered
from the original call sites:

- slot 0: `se100.wav`, selected by the title input branches at `0x00513690`;
- slot 10: `se016.wav`;
- slot 17: `se322.wav`;
- slot 20: `se332.wav`.

The broader dispatcher at `0x00532240` reads caller-owned context slots at
offsets `0x106c` and `0x1070`. The caller object and the interaction-to-slot
index are not yet recovered, so the iOS scene does not trigger these effects by
guessing. The audit output makes that boundary explicit while preserving the
local inventory needed for the next routing pass.

The Apple audio adapter now prepares the complete 35-name chapter-3 table in
the verified original order (`se000`, `se015`–`se031`, `se100`, `se101`,
`se200`, `se300`–`se332`) and exposes slot-index playback. Event semantics stay
separate until the original caller state is recovered.

A bounded local Frida run now reaches the first non-script callback through the
original title dispatcher. With the title START selection and chapter-3
dispatcher forced in process memory for this experiment, the target opened
`RPP_10.pp`, `RPP_08.pp`, `RPP_09.pp`, `RPP_04.pp`, `RPP_15.pp`, `RPP_03.pp`
and `RPP_14.pp` at about 50.1 seconds. The runtime read-size correlation
matched `se016.wav`, `se322.wav`, `se332.wav` and the other preloaded RPP14
entries to local WAV records. This proves the chapter-3 resource load and the
effect-resource availability; it does not prove which later interaction calls
each slot or audible device output. The reproducible probe is
`tools/frida_directinput_probe.py`, and the ignored local reports are
`research/native-core/directinput-frida-force-chapter3b.json` and
`research/native-core/audio-runtime-force-chapter3b-correlation.json`.

In follow-up runs, the chapter-3 callback received DirectInput scan code
`0x3b` at about 55 seconds and reopened `RPP_01.pp/bgm005.wav`, followed by
`RPP_14.pp/se100.wav` and `se101.wav`. The parallel `0x3c` branch reopened
`RPP_01.pp/bgm015.wav` and the same `se100.wav`/`se101.wav` pair. These are
verified callback branches and slot reads, while the `se016/se322/se332`
interaction triggers remain unresolved.

The first natural gameplay-menu activation (hover at `(1200,470)` with input
`0`, then release with input `3`) additionally opens `RPP_11.pp` and reads the
`325272`-byte `ast001_01.wav` entry. This is the first observed chapter-3
voice binding. The iOS host now queues that voice when row 1 is activated on
map 0; later map-specific voice bindings remain separate until observed.

```powershell
python tools/audit_audio_slots.py --data Data --output research/native-core/audio-slot-audit.json
```
