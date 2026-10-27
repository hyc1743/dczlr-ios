# Original-port completion audit

Objective: finish the secondary camera, original system screens, and the
complete original game flow. A successful bounded scene test or development
release does not complete this objective.

| Requirement | Required evidence | Current state |
| --- | --- | --- |
| Original secondary view | Original viewport and visibility controls; actual second GPU pass with independent camera/depth; both targets, automatic on/off, reset and pointer controls | Numeric oracle, local GPU gate and real-resource iOS route passed at 06881c4; artifact CRC and numeric sidecars reviewed; physical device pending |
| System save/load destination | Original page resources, hit rectangles, slot selection, confirmations, cancel/back, save and subsequent load through UI | New DCSaveScene is integrated with original 85-record resources, slot codec, host-owned write/load and transition gates; simulator route/artifact still pending |
| System configuration and title edit destinations | Original layouts and actions with original return routing; settings retained | New type9 configuration page is integrated with exact sliders/switches, gcd.cfg persistence and owner-scene resume; title edit remains separate and the old outfit shortcut is no longer used for config |
| All reachable scene callbacks | Types 4/5/6/2, their admitted menu/state/animation/audio actions and original exit conditions | Initial type-4 progress-zero character route only verified |
| Entire numbered route | New Game through all reachable chapter selectors (0..28), including the chapter24 selector and outcome branches, via actual original actions; retained chapter/transition/audio trace | Only script 0/1/2 -> scene 3 -> script 4 verified; prior 26-entry/linear-ending assumption is incomplete |
| Alternate/special routing | Original outcome branches and special callback selectors with faithful conditions | Pending source inventory and execution |
| Original resources/rendering | Every resource required by those routes resolves, with correct bindings and effects; real scene captures reviewed | Upload audit and bounded model/camera/shadow coverage; lighting/effects and complete scene equivalence unverified |
| Touch input | All 28 virtual controls in black gutters; persistent relative mouse, separate buttons/wheel, simultaneous holds, correct game hit coordinates | Existing bounded simulator evidence; must remain valid across added pages/scenes |
| Persistence | Save, leave/relaunch, load, and resume original state without losing unknown source state | Live system-page write/load path now uses the 0xea40-byte codec and preserves decoded raw bytes in memory; relaunch/device and full UI evidence remain pending; legacy player/story record remains only a compatibility fallback |
| Deliverable | GitHub build/checks and inspected ARM64 unsigned IPA containing the verified implementation | v0.1.12 released; future changes require new validation |

Acceptance must use the current implementation and artifacts. Direct chapter
render checkpoints are useful asset tests but do not prove playthrough.
DEBUG timers, fabricated next/finish shortcuts, replaced resources, and
changing original story/interaction conditions are not acceptable substitutes.
Physical-device signing/execution remains a separate unverified boundary
until actual device evidence exists.

Working evidence is indexed in original-fidelity.md. Mark completion only
after each applicable requirement has matching execution coverage; keep
unverified requirements open.
