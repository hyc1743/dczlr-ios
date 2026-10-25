# iOS controls

The input frontend adapts weixing3's staged `DmGamepad.m`, based on
nxnative `677345b0933f5f8754aeec3125d14df32683ca97`. Its MIT notice ships in
`ios/Resources/Nxnative-LICENSE`. This replaces the simplified Swift controls.
The app uses weixing3's landscape/fullscreen policy so the full layout has
room for both bottom controls and the dpad.

Both virtual and physical buttons use A, B, X, Y, L3, R3, L, R, ZL, ZR,
Plus, Minus, Left, Up, Right, Down in bits 0–15. A is the bottom face key,
B right, X left, Y top, matching weixing3's staging patch. Each finger keeps
its initial owner; face fingers can slide between buttons, while shoulders
stay held until release. Several fingers can hold the same key independently.

The top-centre 2D/3D control persists the layout and clears held input when
switching. 3D adds the eight-way dpad, L3/R3 and an invisible right stick in
the right third of the screen. Its centre follows the finger beyond its
radius. Sticks have a radial 10% dead zone and reach full tilt at 80% radius.
The left stick, diamond, shoulder shapes, safe-area placement and pressed
layers use the reference implementation.

A connected ExtendedGamepad hides the virtual controls and sends screen
touches to the game. Buttons merge with OR, and physical sticks override
each virtual stick as a pair when its radial magnitude exceeds 4000/32767.
Short button presses latch until a render frame consumes them; releases are
reported on the next poll. Backgrounding, cancellation and rotation clear
held touches. The accelerometer follows the reference 1.5 G shake detector
and 120 ms hold; the DCZL runtime receives its separate shake flag without
inventing a game action for it.

Touches not owned by a control retain up to sixteen stable finger slots.
The native game consumes the first active slot. Coordinates are normalized
against the whole renderer view, which maps into the game's 4:3 viewport.
Applying the reference's 16:9 transform here would misplace menu clicks.

The game adapter uses its own native gameplay functions, since DCZL R is a
different game from weixing3:

| Control | DCZL R action |
| --- | --- |
| Left stick / dpad | Move directly, independent of the touch pointer |
| A / Plus | Confirm title selection; advance dialogue; interact / continue map route |
| B | Skip startup/dialogue; cancel a gameplay touch |
| X | Save current gameplay state |
| Y / R3 | Reset camera offsets |
| Right stick | Camera yaw/pitch |
| L / R | Rotate camera |
| ZL / ZR | Zoom camera |
| L3 held | Double movement speed |
| Minus | Return from gameplay to title |

Portable tests exercise radial values, whole-stick merge, all sixteen short
press/release pairs, lifetime reset and multitouch slots. Debug simulator
launches also exercise the actual UIKit ownership handlers and a mutable
GameController snapshot. The simulator probe requires
`PORTLAB_GAMEPAD_TEST_PASSED`; compilation alone does not pass this check.
Bluetooth hardware latency, real device multitouch and sensor behavior
still require device testing.
