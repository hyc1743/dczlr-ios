# Runtime completeness audit

Checked against source revision `9f75278` on October 26, 2026. The native
host is a development port. An IPA, submitted frames, input markers and a
bounded map exercise do not establish a complete playable original runtime.

| Area | Observed host behavior | Completeness |
| --- | --- | --- |
| Pointer and keyboard transport | One immutable frame carries pointer coordinates, relative motion, wheel, three mouse buttons and 256 scan codes | Generic transport implemented; per-screen shortcut consumers are separate |
| Title pointer | Hover and press/hold/release feed the native menu helper | Implemented for the admitted title profile |
| Title destinations | Load enters a local scene after checking a small host save; other destinations can return an unimplemented error | Original destination interfaces are incomplete |
| Submenu return | The title planner emits backup/hide commands; the host does not restore complete original callback banks | Incomplete |
| Intro destination | Completion enters the current game scene without consuming the pending chapter as a complete destination dispatch | Incomplete |
| Gameplay interactions | A bounded host state machine uses a fixed timer; an additional activation can advance the map chain | Development exercise, not complete original event behavior |
| Saves | Host position/map state and original save-prefix metadata exist | Complete original session serialization is not established |
| Rendering | Map, actor and face geometry render; full original effect/material equivalence is not established | Partial |

Source boundaries:

- `ios/Native/DCVulkanSpriteView.m`: title command dispatch, load destination
  and intro completion routing.
- `ios/Native/DCIntroScene.m`: pending chapter and text/transition state.
- `ios/Native/DCGameScene.m`: current interaction and map advancement adapter.
- `native/game/dc_gameplay.c`: bounded timing, map sequence and host save record.

The keyboard/mouse work adds input delivery and corrects menu edge-state
translation. It does not fill missing scene consumers, destinations, script
semantics or original event behavior. A visible Esc, function key or modifier
on the keyboard is not proof of a corresponding implemented menu command.

Validation for this input change uses portable tests and self-authored iOS
startup fixtures. These checks contain no original scene resources and do
not certify complete original playability or physical-device behavior.
