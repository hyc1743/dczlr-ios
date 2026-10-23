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

The parser's pre-record CG/music/sound state accumulation, custom header
controls, CP932 text layout, typewriter timing, voice handling, branching and
new-game callback dispatch still require their own reconstruction and tests.
This reader is deliberately separate from those runtime responsibilities.
