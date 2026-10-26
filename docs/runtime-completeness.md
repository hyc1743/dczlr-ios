# Runtime completeness audit

The native host is a development port. An IPA, submitted frames, input markers
and a bounded map exercise do not establish a complete playable original
runtime. Some isolated numeric story helpers have original-function oracles;
those checks do not certify the scene state machines or their host wiring.

| Area | Observed host behavior | Completeness |
| --- | --- | --- |
| Pointer and keyboard transport | One immutable frame carries pointer coordinates, relative motion, wheel, three mouse buttons and 256 scan codes | Generic transport implemented; per-screen shortcut consumers are separate |
| Title pointer | Hover and press/hold/release feed the native menu helper | Implemented for the admitted title profile |
| Title destinations | New Game, Load, Edit, Extra and the options route all dispatch | Destination scenes follow the original scene kinds; Edit/Extra are bounded host presentations |
| Story chapters | The full 26-chapter loop alternates numbered scripts and scene chapters through the original static tables | All 26 chapter descriptors, map/stage selectors and next-scene callbacks recovered and oracle-verified |
| Script chapters | The intro text host plays any numbered script chapter, including mid-story entries | Chapters 0–25 scripts verified against local 00–16.txt resources |
| Gameplay scenes | Chapters 3/10/17 (gameplay), 5/12/19 (watch), 7/14/21 (night) and 24 (ending) enter the story scene with the original map/stage | Scene kinds wired; per-scene camera/lighting internals remain partial |
| Chapter-end menu | Rows map to the original action codes 2/3/4/5 (advance, edit, save menu, fade) | Original FUN_00523380 semantics reimplemented and matched on 5,760 oracle cases |
| Scene UI | Original right-side icons and initial type-4 right-click menu profiles render from RPP_02 | Menu layout/input shell implemented; evolved profiles and action callbacks pending |
| Interactions | Unsupported main-row-to-event/chapter shortcuts removed | Original context action callbacks and scene behavior remain incomplete |
| Story persistence | Story state roundtrips through the host save record with the player position | Native PLGS record with checksum verified |
| Chapter 24 ending | Entering the ending chapter unlocks all three stage progress flags; the epilogue script completes the story | Matches the original end-of-script dispatcher |
| Saves | Host position/map state and original save-prefix metadata exist | Complete original session serialization is not established |
| Rendering | Map, actor and face geometry render; full original effect/material equivalence is not established | Partial |

Source boundaries:

- `native/game/dc_story.c`: recovered chapter tables, chapter-end handler,
  script-finish routing and the story save record.
- `native/game/dc_scene_ui.c`: initial right-click profiles and menu geometry
  from FUN_005319e0/00533a70/005352c0/00535730; no story dispatch.
- `ios/Native/DCVulkanSpriteView.m`: story loop, title destinations, gallery
  presentation and persistence wiring.
- `ios/Native/DCIntroScene.m`: numbered script chapters with mid-story entry.
- `ios/Native/DCGameScene.m`: partial scene rendering and original scene icon/
  context sprite composition. Original scene action state machines are pending.

Verification:

- `tools/oracle_story.py` matches the original chapter-end handler
  (FUN_00523380) with the real static tables on 5,760 synthetic cases.
- `tools/oracle_intro.py` matches the original end-of-script/transition
  helpers on 567 + 2,568 synthetic descriptor cases and, with
  `--real-table`, on 78 + 2,304 reachable cases driven by the recovered
  real 26-entry chapter descriptor table. The chapter-end oracle
  (5,760 cases) exercises the real table bytes because the original handler
  reads them from the image's own data section.
- `tools/audit_story_loop.py --data Data` walks all 26 chapters against the
  local resources: every script, map, actor, face, camera candidate and
  voice binding resolves; chapter 24 unlocks and the final termination are
  asserted.
- `tools/story_cases.py` plus `tests/test_native_story.py` run the portable
  native story cases.

The keyboard/mouse work adds input delivery and corrects menu edge-state
translation. A visible Esc, function key or modifier on the keyboard is not
proof of a corresponding implemented menu command. Original GPU equivalence,
audible device output and physical-device playability remain unverified.
