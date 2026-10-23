# Normal text controller

`dc_text_build_plan` reconstructs the normal branch of `0x0058eb30` and
`dc_text_advance` reconstructs forward input in `0x00591310`. These are native
C modules, with no original executable or CPU emulator in the iOS product.

The original copies two-byte text cells, wraps at a fixed byte-column limit,
and preserves its LF/CRLF and zero-padded-buffer behavior. Some empty cells
participate in completion and fade state. Draws use the current cell alpha;
only afterwards does a tick add `delta * 10` to at most one cell. A large tick
does not reveal several cells. Arithmetic retains the original signed 32-bit
wrap and saturation comparisons. Line waits retain the external clock and
the original fixed state transitions.

Forward input first reveals an unfinished record. Subsequent input advances
its line/frame state and requests the next numbered record, or deactivates
the controller at the terminal frame. The preloaded first record starts with
frame and current-line values of -1. Reload operations clear alpha state and
retain the sequential source cursor, rather than creating a unique-ID map.

The bounded profile admits normal drawing, up to five lines, 39 columns,
200 alpha cells and 400 body bytes. The forward-input API admits 2–399 bytes.
Invalid arguments leave output unchanged. Texture mode, backlog and the
outer keyboard/voice/automatic-advance wrapper remain separate work.

An isolated original execution matches 1,950 layout/fade cases and 1,440
forward-input cases. The original x87 integer-conversion helper executes;
font drawing, clocks, strings and the next-record parser are synthetic
boundaries. Local original-body checks match 868 calls across all 434
records. Reports keep counts and hashes, not original dialogue or pixels.

The original font setup at `0x0058e530` requests charset 134 and a Chinese
face. The local script resources use Windows code page 936: all 434
speaker/body records and all 7,748 nonempty layout cells decode successfully.
The earlier CP932 assumption was incorrect; 119 records fail that decoder.
The Apple adapter now uses the CP936 encoding through CoreFoundation and
renders original numeric positions, colors, alpha and four outline offsets.
It uses an Apple fallback font; Windows font rasterization, speaker rendering
and exact original GPU appearance remain unverified.
