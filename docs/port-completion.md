# Original-port completion audit

Objective: finish the secondary camera, original system screens, and the
complete original game flow. A successful bounded scene test or development
release does not complete this objective.

| Requirement | Required evidence | Current state |
| --- | --- | --- |
| Original secondary view | Original viewport and visibility controls; actual second GPU pass with independent camera/depth; both targets, automatic on/off, reset and pointer controls | Implementation present; numeric oracle and local GPU checks pass; iOS route/artifact review pending |
| System save/load destination | Original page resources, hit rectangles, slot selection, confirmations, cancel/back, save and subsequent load through UI | Destination currently recorded as pending |
| System edit/options destinations | Original layouts and actions with original return routing; settings retained | Incomplete; current shortcut does not establish original screen fidelity |
| All reachable scene callbacks | Types 4/5/6/2, their admitted menu/state/animation/audio actions and original exit conditions | Initial type-4 progress-zero character route only verified |
| Entire numbered route | New Game through all 26 normal chapter selectors via actual original actions; retained chapter/transition/audio trace | Only script 0/1/2 -> scene 3 -> script 4 verified |
| Alternate/special routing | Original outcome branches and special callback selectors with faithful conditions | Pending source inventory and execution |
| Original resources/rendering | Every resource required by those routes resolves, with correct bindings and effects; real scene captures reviewed | Upload audit and bounded model/camera/shadow coverage; lighting/effects and complete scene equivalence unverified |
| Touch input | All 28 virtual controls in black gutters; persistent relative mouse, separate buttons/wheel, simultaneous holds, correct game hit coordinates | Existing bounded simulator evidence; must remain valid across added pages/scenes |
| Persistence | Save, leave/relaunch, load, and resume original state without losing unknown source state | Existing custom player/story record is insufficient proof of original save compatibility |
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
