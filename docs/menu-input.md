# Pointer menu behavior

`dc_menu_step` reconstructs the numeric state update at `0x0045f7c0` and its
scaled rectangle helper at `0x0045f600`. Bounds are inclusive. Position and
dimensions are each multiplied by scale and stored as binary32 before the
right/bottom sums are compared to signed integer pointer coordinates. The
first hit wins, skipping x=-1 sentinel rows and exact disabled value 1.

The original clears pressed flags only for rows visited through that first
hit. Later rows retain their previous values. No-hit leaves the previous hover
and selection but clears active. Return codes distinguish unchanged hover,
new hover, release on a new row and activation. Press-activation and toggle
rows use separate fields; odd input codes and exact code 3 have distinct
behavior. This cannot be replaced by a single generic click-in-rectangle rule.

The bounded API accepts up to 32 finite, nonnegative-size buttons at a positive
finite scale. Invalid geometry, counts or overlapping outputs fail atomically.
An isolated original-function oracle matches 3,780 self-authored cases covering
overlap order, exact edges, scaling, sentinel/disabled rows, integer pointer
precision, hover, press and toggle behavior. Public replay stores only a digest;
original code and game resources remain separate local analysis inputs.

The Apple title view uses this module for pointer hover/release and selection
audio, with edit/extra availability read from existing save metadata. New Game
and Load Game now enter the native chapter-3 scene path; Load Game restores the
saved map and player state. Options and the remaining title destinations still
fail explicitly. See `intro-host.md`
for adapter and validation limits. CPU oracle tests do not establish UIKit
input or complete-game behavior.

`dc_title_build_plan` now restores the ordered routing at `0x005129c0` and
`0x0052b830`. It first resolves a pending transition, including the selection
player's busy gate for actions 1–5. Action 6 enters options without that sound
gate. It preserves the distinct load/options callback backups, hide flags,
music-stop operations and action/hover reset rules. New Game orders cleanup,
intro callback installation, then numeric game-state initialization/chapter 0.
The host replaces the title update after a departure and must execute each
operation in order before committing state. Initial action 0 clears waiting
and can accept input in that same frame. Menu result 3 updates hover only.

The isolated original frame and helper match 10,584 self-authored combinations
of actions, waiting/query/busy flags, escape codes, hover and menu results.
External menu/audio/transition/initialization calls are synthetic boundaries;
callback writes and callback clearing execute in the original functions.
The Windows Alt-F4 path is held inactive. This adds verified native routing;
Apple New Game dispatch now uses this planner; other callback destinations
and original intro text-rendering equivalence remain unfinished.
