# Original behavior audit (2026-10-27)

The current native port is incomplete. Original files, projected models, and
passing input checks do not demonstrate original gameplay or full-story
equivalence. v0.1.9 predates the corrections below.

## Verified corrections

`FUN_00517b30` indexes VA `0x00673280` with the story stage to construct body,
animation, face and placement resource names. The pinned EXE, SHA-256
`70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07`,
contains `62 63 61 64 65 00` (`bcade`) at file offset `0x273280`. Stages 0/1/2
select prefixes b/c/a. The previous host always loaded the a-prefixed files.
The host now selects the stage prefix for body/clip/face/PLST/eyes/neck and
node bindings. Local tests check all corresponding files and attachment nodes.

The virtual pointer persists after lifting. Moving the open screen does not
click. Mouse buttons and keyboard fingers retain independent owners, and
short taps survive frame polling. Physical inputs have separate owners.
Right clicks are no longer converted to a global pad Cancel action.

The unsupported tap-to-next-chapter shortcut for non-gameplay scenes was
removed. The 800ms interaction-completion harness now runs only in independent
DEBUG GPU probes, not in production gameplay. The speculative HScene asset
overlay/preload was removed: those resources belong to another original
screen, not the in-scene Character/Camera/System controls. Earlier GPU-stall
claims were not established; failed runs reached gameplay but the driver
moved the cursor without sending a mouse click.

## Callback evidence and remaining work

REA CLI/Ghidra analysis of `FUN_00489f20` produced Evidence
`ev_a8f7cef53b72f5b47728d7656e4e42d8a97662065d166b86f600fe38f1080ea4`.
It installs watch update `0x0048aa40`, separate render/cleanup callbacks, its
own state, and a six-entry scene menu. This is static analysis, not execution.
Complete local Evidence is retained in `out/original-watch.rea.json`.

Read-only exports from the existing Ghidra project are retained in
`out/original-scene-callbacks/` (ordinary local Ghidra output, not runtime
observations):

- `FUN_00513690` handles a right press over scene rows 1-4 by recording the
  pointer, entering contextual-menu state and calling `FUN_005319e0`.
- `FUN_005319e0` calls `FUN_00535730`, constructs up to seven normal/selected
  sprite pairs from `RPP_02.pp`, and places them around that pointer.
- `FUN_00532240` hit-tests that menu and dispatches to `FUN_0053a7c0`. A return
  value of 2 does not by itself mean next chapter.
- `FUN_00483510` installs night update `FUN_00483fe0` with separate state.
  The previous tap-to-continue claim for these scenes was unsupported.

Context-menu option generation/action execution, watch/night/ending state
machines, camera selection, effect/lighting equivalence and original save
serialization remain incomplete. Existing simplified scene-menu/action code
is not certified equivalent. Do not label this work original-equivalent or
publish based only on the bounded mouse check.

## Validation boundaries

The independent `--mouse-input --expected-scene mouseInput` route reaches the
first real-resource scene through startup and scripts 0-2. It checks relative
drag, separate mouse presses, a scene-menu hit, and a Num6/arrow combination.
Its report does not certify the original right-click menu, full story or a
physical device. The full story gate is retained separately. Mouse-only runs
cannot produce a release IPA.
