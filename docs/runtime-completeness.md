# Runtime completeness audit

The native host is a development port. An IPA, submitted frames, input markers
and a bounded map exercise do not establish a complete playable original
runtime; the reconstructed story/menu/interaction logic below is verified
function-by-function against the pinned original executable.

| Area | Observed host behavior | Completeness |
| --- | --- | --- |
| Pointer and keyboard transport | One immutable frame carries pointer coordinates, relative motion, wheel, three mouse buttons and 256 scan codes | Generic transport implemented; per-screen shortcut consumers are separate |
| Title pointer | Hover and press/hold/release feed the native menu helper | Implemented for the admitted title profile |
| Title destinations | New Game, Load, Edit, Extra and the options route all dispatch | Destination scenes follow the original scene kinds; Edit/Extra are bounded host presentations |
| Story chapters | The full 26-chapter loop alternates numbered scripts and scene chapters through the original static tables | All 26 chapter descriptors, map/stage selectors and next-scene callbacks recovered and oracle-verified |
| Script chapters | The intro text host plays any numbered script chapter, including mid-story entries | Chapters 0–25 scripts verified against local 00–16.txt resources |
| Gameplay scenes | Chapters 3/10/17 (gameplay), 5/12/19 (watch), 7/14/21 (night) and 24 (ending) enter the story scene with the original map/stage | Scene kinds wired; per-scene camera/lighting internals remain partial |
| Chapter-end menu | Rows map to the original action codes 2/3/4/5 (advance, edit, save menu, fade) | Original FUN_00523380 semantics reimplemented and matched on 5,760 oracle cases |
| Gameplay menu activation | Row 2 touch, row 4 finish, rows 1/3/5 alternate events with the interaction-counter gate | Original FUN_00532240 chapter-type-4 branch reimplemented |
| Interactions | Touch/finish/alternate events drive animation, voice chains and outcome flags | Bounded port semantics; the original per-region mood curves remain unrecovered |
| Story persistence | Story state roundtrips through the host save record with the player position | Native PLGS record with checksum verified |
| Chapter 24 ending | Entering the ending chapter unlocks all three stage progress flags; the epilogue script completes the story | Matches the original end-of-script dispatcher |
| Saves | Host position/map state and original save-prefix metadata exist | Complete original session serialization is not established |
| Rendering | Map, actor and face geometry render; full original effect/material equivalence is not established | Partial |

Source boundaries:

- `native/game/dc_story.c`: recovered chapter tables, chapter-end handler,
  script-finish routing and the story save record.
- `native/game/dc_gameplay.c`: `dc_game_menu_activate` row dispatch from
  FUN_00532240.
- `ios/Native/DCVulkanSpriteView.m`: story loop, title destinations, gallery
  presentation and persistence wiring.
- `ios/Native/DCIntroScene.m`: numbered script chapters with mid-story entry.
- `ios/Native/DCGameScene.m`: story scene kinds, the six-row menu, chapter-end
  actions and the edit presentation.

Verification:

- `tools/oracle_story.py` matches the original chapter-end handler
  (FUN_00523380) with the real static tables on 5,760 synthetic cases.
- `tools/oracle_intro.py` matched the original end-of-script/transition
  helpers with the real 26-entry chapter descriptor table (567 + 2,568
  cases).
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
