# Touch mouse and keys

The default controls follow the supplied picture and remain at the edges.
There is no Close button, expanded keyboard grid, movement joystick,
Finish Segment button or Next Chapter shortcut in this layout.

| Position | Inputs |
| --- | --- |
| Upper left | Esc, V, F1 |
| Left upper diamond | A above; Z left, X right; S below |
| Left middle diamond | PgUp above; Home left, End right; PgDn below |
| Left lower diamond | Arrow Up/Left/Right/Down |
| Right outer column | 1, 2, 3, 4, C |
| Right inner column | Wheel up, wheel down, left mouse, right mouse |
| Right lower diamond | Num8 above; Num4 left, Num6 right; Num2 below |

Sliding the open screen moves a persistent virtual mouse relatively.
Touch-down does not click or jump to the finger. Lifting retains the cursor,
so either mouse button can be pressed afterward. Each finger retains its
initial key/button until release or cancellation, including when sliding
outside. Keys, both mouse buttons and one pointer drag can coexist. Wheel
buttons emit one +/-120 pulse per press. Z/X and A/S retain the portable
original mouse/wheel fallback ordering. Keyboard-only activity does not
acquire the pointer; virtual releases do not release physical keys.

Geometry and ownership live in dc_pc_touch.c, used by both UIKit and the
portable regression tests. iOS DEBUG verification additionally traverses
visible window hit tests and touch handlers, including relative drag followed
by a short mouse click. The mouse gate does not inject raw pad axes.

Input delivery and implementation of a game command are separate. See
[original-fidelity.md](original-fidelity.md) for remaining original scene and
right-click-menu gaps.
