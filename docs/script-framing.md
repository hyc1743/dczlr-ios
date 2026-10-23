# Numbered intro script records

The new-game callback `0x00605510` opens an entry in `RPP_16.pp`, initializes
the original text controller through `0x00605390`/`0x0058e990`, and drives
background, music, sound and text updates. Its text parser is `0x00592590`.
The complete command interpreter and glyph rendering remain unfinished.

`dc_script_find` supplies bounded source spans for one numbered record: the
first exact six-byte `#Tdddd` marker at or after a caller-owned cursor, the
rest of its header line, a speaker line and opaque body through `$END`.
The next cursor lies immediately after that delimiter. LF/CRLF input and
speaker lines up to 32 bytes are admitted; NUL-containing input and larger
unknown profiles fail explicitly. Headers and bodies retain original bytes
without character conversion, control-code interpretation or text export.

The cursor is essential: the local 19 scripts have 434 numbered records and
52 repeated IDs within their respective files. Treating IDs as unique keys
would lose original record order. A local independent Python marker/line/
delimiter probe agrees with all 434 native spans; maximum speaker length is
four bytes. Reports retain hashes and counts, not original text. This is a
framing comparison against local data and static exports, not execution of
the original parser or proof of dialogue/gameplay equivalence.

`dc_script_decode` adds the parser's normal sequential branch: background,
music, sound and message accumulation before the selected marker, followed by
up to 11 configured fixed-width header controls and their optional A/B/C suffix.
The scan retains original command check order and case sensitivity, including
the three-byte `#bg` comparison. Multiple pending names concatenate rather
than replacing one another. A repeated header control without a suffix retains
the previous suffix byte, matching the original fixed-width copy. Limits and
truncated header parameters fail without changing the caller's output.

An isolated execution of original `0x00592590`, with synthetic CRT boundaries,
matches 761 self-authored cases. A separate private audit also matches all 434
records from the 19 local scripts for pending commands, controls, speaker/body
bytes and next cursor. The local audit stores only source/comparison hashes
and counts; original script bytes are not uploaded. The `%C` actor-command and
backlog/replay branches remain outside the admitted profile and fail explicitly.

CP932 text layout, body control execution, typewriter timing, voice playback,
branching and new-game callback dispatch still require reconstruction and
runtime tests. Parser equivalence does not establish playability.
