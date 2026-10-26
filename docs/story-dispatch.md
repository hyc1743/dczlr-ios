# Story dispatch integration

The original game drives its story with a 26-entry chapter system. Each
chapter has a numbered script or a scene kind, a map selector, a story stage
selector and a next-scene callback. All tables were recovered byte-exact from
the pinned local executable and are reimplemented in `native/game/dc_story.c`.

## Recovered tables

| Table | Original address | Contents |
| --- | --- | --- |
| Chapter descriptors | `0x0078d908` | 26 x 2 bytes: script index and last frame; `0xff` marks scene chapters |
| Next-scene callbacks | `0x006d39d0` | 26 dwords: `FUN_00605510` (script scene), `FUN_00512cc0` (gameplay scene), `FUN_00489f20` (watch scene), `FUN_00483510` (night scene), `FUN_0051abb0` (ending scene) |
| Story stage selectors | `0x006d3a44` | 26 bytes: stage record 0/1/2 per chapter |
| Map selectors | `0x006d3a84` | 26 bytes: map 0/1/3/4/6 per scene chapter |

The chapter type byte (`0x1352e`) is 3 for script scenes, 4 for gameplay, 5
for watch, 6 for night, 2 for the ending, 8 for the save/load menu, 9 for the
edit scene and 10 for the title scene.

## Chapter flow

```
chapter 0/1/2     scripts 00/01/02.txt        (new game)
chapter 3         gameplay scene, map 0, stage 2
chapter 4         script 15.txt
chapter 5         watch scene, map 1, stage 2
chapter 6         script 03.txt
chapter 7         night scene, map 3, stage 2
chapter 8/9       scripts 04/05.txt
chapter 10        gameplay scene, map 0, stage 1
chapter 11        script 16.txt
chapter 12        watch scene, map 1, stage 1
chapter 13        script 06.txt
chapter 14        night scene, map 6, stage 1
chapter 15/16     scripts 07/08.txt
chapter 17        gameplay scene, map 0, stage 0
chapter 18        script 09.txt
chapter 19        watch scene, map 1, stage 0
chapter 20        script 10.txt
chapter 21        night scene, map 4, stage 0
chapter 22        script 11.txt
chapter 23        script 13.txt
chapter 24        ending scene (keeps the previous map/stage selectors)
chapter 25        script 12.txt (epilogue; the story ends afterwards)
```

A script chapter ends by installing the next chapter's callback from the
static table and, for scene chapters, committing the map/stage selectors.
Entering chapter 24 with a clear stage-0 progress flag unlocks the ending
flags in all three stage records (`0x1355b`, `0x156f3`, `0x1788b`).

## Chapter-end menu

The original chapter-end handler `FUN_00523380` consumes an action code and
an outcome record per stage:

- action 2 advances the chapter: outcome short A (nonzero) sets the stage
  flag A, otherwise outcome short B sets flag B; the chapter increments and
  the next callback/map/stage selectors are installed.
- action 3 enters the character edit scene (`FUN_0050de60`).
- action 4 enters the save/load menu scene (`FUN_0052e070`).
- action 5 enters the fade transition (`FUN_0051e010`).

`tools/oracle_story.py` runs the original handler in isolation with synthetic
contexts and compares every observable (chapter, selectors, flags, callback
installs, backup banks, audio-player stops and cleanup calls) against
`dc_story_advance`/`dc_story_menu_action` on 5,760 cases.

## Gameplay menu activation

The shared original menu activation helper `FUN_00532240` (chapter type 4
branch) drives the gameplay scene rows:

- row 4 plays the finish event and exits to the chapter-end menu;
- row 2 starts a touch interaction (voice chain and animation);
- rows 1/3/5 trigger alternate events;
- a row-1 activation keeps the scene only when the interaction counter
  exceeds one;
- a missed press keeps the scene without an event; the release edge clears
  the armed toggle flag.

`dc_game_menu_activate` reimplements this branch and is covered by portable
tests in `tests/test_native_story.py`.

## Host wiring

`DCVulkanSpriteView` owns one `dc_story_state`, persists it in the host save
record (`save/player.state`, PLGS record after the PLGP player record) and
routes chapter entries: numbered scripts enter `DCIntroScene` with the
chapter's start index; scene chapters enter `DCGameScene` with the story map
and stage. `DCGameScene` exposes the chapter-end action and per-stage outcome
flags; the view applies `dc_story_advance` and enters the next chapter.

Title Load resumes the saved story chapter. Title Edit enters the gameplay
scene's edit presentation (outfit variants through the original hidden-mesh
sets, finish returns to the title). Title Extra shows the gallery grid whose
images follow the story unlock flags. The options route stops the title music
and returns to the title state.

`tools/audit_story_loop.py --data Data` walks the complete loop against local
resources and asserts every transition, resource binding, the chapter-24
unlock and the final termination.
