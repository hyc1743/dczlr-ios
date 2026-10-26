# Windows pointer and keyboard evidence

The local original executable has SHA-256
`70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07`.
The following input findings come from retained Ghidra exports and read-only
PE32 disassembly of that executable. No target execution was performed for
this recovery. Existing Frida reports are historical observations.

`research/native-core/functions/004621f0.c:104` samples the mouse through
`0x00466dd0`, then updates keyboard state through `0x00467ab0`. At lines
110–126, physical Z (`0x2c`) and X (`0x2d`) supplement the left and right
mouse state bytes only when those bytes are zero. A (`0x1e`) newly pressed
sets wheel input to +120; otherwise S (`0x1f`) newly pressed sets it to -120.
This is a wheel fallback, not evidence of WASD movement.

`0x00467ab0`, addresses `0x00467b2a`–`0x00467b6c`, converts raw keyboard
high bits and prior state into 0 idle, 3 newly pressed, 1 held, 2 newly
released. `0x00467b90` returns `0x007c83d8[scan_code]` without remapping.
Historical `research/native-core/directinput-frida-inputarray.json` confirms
the sequence for a Z pulse lasting seconds 39–41: 3 at 39.002, 1 at 39.019,
2 at 41.003, then 0 at 41.019.

`0x004042a0`, addresses `0x004042c7`–`0x004043a9`, reads a 16-byte
DirectInput mouse state: signed relative dx/dy/wheel and four raw button
bytes. `0x00466dd0:0x00466e63`–`0x00466ed7` generates the same four states
for the first three buttons. Its scene outputs are:

| Main-object offset | Value |
| --- | --- |
| `0x260`, `0x261`, `0x262` | Left, right, middle four-state button codes |
| `0x264`, `0x268`, `0x26c` | Relative dx, dy, signed wheel |
| `0x270`, `0x274` | Virtual pointer x, y |

`0x004042a0:0x004043ac`–`0x00404461` accumulates sensitivity-scaled,
integer-converted dx/dy into a virtual pointer, unless its input flag is set,
and clamps it to configured bounds. `0x004044e0` sets the upper bounds to
width-1 and height-1. `004621f0.c:44`–`56` initializes the pointer at the
window center and chooses sensitivity `(width/1024) * {1,1.5,2}`. The virtual
pointer is distinct from the operating-system cursor.

`tools/frida_directinput_agent.js:169` injects keyboard high bits into the
256-byte state; line 179 injects mouse dx/dy and buttons into the 16-byte
state. This agent does not inject wheel input. Its forced menu input codes
are internal numeric overrides, not physical press/release observations.
Earlier documentation calling numeric input 3 “release” is inconsistent
with both original state converters: 3 is the press edge.

The ordinary menu helper at
`research/native-core/transition-functions/0045f7c0.c:29`–`49` distinguishes
odd input states, exact press state 3, press-activated rows and toggle rows.
Result 1 activates a row; 2 changes hover; 3 is a press on a newly entered
row; -1 misses all enabled rows. The first hit wins. The rectangle helper
`0045f600.c` applies scale and inclusive edges. The title callback
`005129c0.c:21` ignores navigation while its transition flag is set, handles
Escape press separately, and passes the virtual pointer plus left-button
state into the menu helper.

The portable adapter preserves these generic state codes and fallback
ordering. Source ownership, normalized pointer coordinates, saturated motion
accumulation and retention of taps between polls are host-adapter decisions.
Clearing input on focus loss discards unseen pending taps while releasing
controls already published to a frame. HID usage conversion maps physical
keyboard locations to DirectInput scan codes; it does not assign actions.

The retained exports do not establish complete camera drag/button mappings,
camera-controller input limits, every ordinary screen's shortcuts, or all
navigation transition prerequisites. Those remain unknown; no camera
gesture or gameplay action is inferred from WASD or generic UI conventions.
