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
audio, with edit/extra availability read from existing save metadata. It does
not yet dispatch all title actions, open the load screen or start gameplay.
The original title driver and post-transition callbacks have been located;
their host connections remain separate work. CPU oracle tests do not establish
UIKit input or complete-game behavior.
