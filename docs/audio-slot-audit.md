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

```powershell
python tools/audit_audio_slots.py --data Data --output research/native-core/audio-slot-audit.json
```
