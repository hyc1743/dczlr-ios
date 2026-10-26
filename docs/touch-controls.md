# Touch controls for the native game host

The default is point/select and interaction, rather than a console button
diamond or a desktop keyboard. The controls use the actions implemented by
this game's title, script, gameplay and chapter-end handlers.

| Screen | Control | Consumer |
| --- | --- | --- |
| Title | Tap a menu row, then confirm | Native title hit test/action planner |
| Script | Tap or press Continue / Skip | Native text/script progression |
| Gameplay | Tap the scene or its menu | Native pointer hit test and admitted interaction path |
| Gameplay | Interact | Native interaction request; not a fabricated keyboard shortcut |
| Gameplay | End segment | Chapter-end phase, using the existing finish action |
| Completed segment | Next chapter | Native story advance with recorded stage outcomes |
| Completed segment | Stay in segment | Return from the chapter-end phase |
| Gameplay | Drag the labelled camera area | Relative touch camera motion, consumed once; no rotation from a stationary finger |
| Gameplay | Zoom in / out | Camera distance adjustment |
| Gameplay | Save | Write the native player/story record and report completion after successful write |
| Gameplay | Reset view | Reset camera offsets |
| Menu | Adjust position | Reveal the optional position pad; the default scene has no movement stick |
| Menu | Return to title | Existing native title-return destination |
| Menu | Keyboard/mouse panel | Optional advanced input UI, with an explicit return-to-touch button |

The original keyboard/mouse evidence establishes pointer/button edge states
and the Z/X/A/S fallbacks; it does not establish WASD movement or a complete
original camera gesture map. Position adjustment and touch camera gestures
are explicit adapters to the current native runtime. This UI does not claim
that missing original interaction mechanics have been reconstructed.

Each launch starts in touch mode, including installations that retained the
old `DCZLRPCInput` preference. Switching back from the optional PC panel clears
its active pointer source, so it cannot override scene taps.

The controller reference from weixing3 is limited to the ownership principle,
radial normalization for the optional position pad, and physical-controller
merging. Its Nintendo key names, face diamond, shoulders, D-pad and 2D/3D
layout selector are not used by this interface. The MIT attribution is kept
for the retained mechanisms.

## Input ownership and lifecycle

The portable `dc_touch_controls` module defines the same geometry used by
UIKit. Buttons own their finger until release/cancel, even when it slides
outside. Different fingers can select, adjust the camera and hold a control
without releasing one another. A second finger cannot steal an active pad.
Camera drag motion is consumed once, while a physical right stick retains
continuous behavior. Rotation, backgrounding, scene changes and mode switches
release held virtual input. Game-scene pointer dragging no longer secretly
translates the player.

Primary and secondary action labels change with the scene and chapter-end
state. Save/reset/zoom and position controls are hidden outside gameplay.
The completed segment has one Next Chapter action instead of two duplicate
advance buttons. Voice playback allows camera, position and save controls;
repeated interaction/advance presses remain gated while a voice is playing.

## Validation

Portable tests cover scene layouts, phone/tablet safe areas, minimum target
sizes, concurrent ownership, pointer coordinates, cancelled touches, short
save taps through the actual bridge, and stopping camera movement without
lifting the finger.

The Debug UIKit regression checks button hits, simultaneous position/camera/
action input, independent release, mode switching and lifecycle reset.
The real-resource simulator route uses `--touch-controls`: it targets the
visible control, verifies the hit through the actual window hierarchy, invokes
the UIKit touch handlers, then observes native movement, camera changes,
manual save completion and chapter advancement. This route disables the old
direct controller injection. It is still synthesized UIKit input rather than
physical-device finger testing.

Evidence requires all of `PORTLAB_TOUCH_INPUT_STARTED`, native movement and
camera markers, `PORTLAB_TOUCH_SAVE_COMPLETED`, and
`PORTLAB_TOUCH_ROUTE_PASSED`, plus the ordered script/gameplay/next-script
route, GPU-frame checks and successful native decoding of the saved file.
