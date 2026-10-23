# First new-game chapter host

The Apple view now uses `dc_title_build_plan` to route New Game after the
original transition and selection-player gates. The startup transition model
continues across title and intro scenes; external sprites render below its
projected meshes. Renderer rebuilds retain CPU scene state and recreate GPU
textures. Backgrounding pauses audio and excludes suspended transition time.

`DCIntroScene` initializes the reconstructed 59,960-byte numeric game state,
opens `RPP_16.pp/00.txt`, and decodes records 0–2 using the verified normal
parser branch. This is the first entry in the original chapter descriptor
table, whose terminal record is 2. Background EMA resources come from RPP_02;
music, effects and voice come from RPP_01, RPP_14 and RPP_00 respectively. Media
bytes stay in local user resource files. No original image, audio or dialogue
is included in the source tree or CI.

This is an incomplete first-chapter adapter. The current text surface uses
Apple's fallback font at the observed 1024-resolution size and bounds and
previews the complete record. Original glyph layout, alpha/typewriter timing,
backlog, voice gating, branches and subsequent gameplay remain unfinished.
Touch release advances a preview record; this is not a claim of original input
or timing equivalence. At the first chapter boundary the host explicitly
reports the missing next callback. Load/edit/extra/options are also pending.

The generated simulator fixture exercises startup cards, title pointer
hover/press/release, transition/sound waits, intro background/text and three
audio playback clocks. `PORTLAB_EXERCISE_NEW_GAME=1` supplies a test pointer
through the normal input adapter after title presentation. Normal launches
use user input. Generated text and media are self-authored. The check does
not establish original-resource GPU equivalence, audibility, physical-device
playability or complete-game compatibility.

Source `44a2099` passed both Apple workflows: 156 portable tests, 115 native
ARM64 tests, all 16 iPhoneOS native objects, unsigned device packaging and
the generated simulator route on iPhone 16 Pro/iOS 18.5. The generated
background/text screenshot and exact startup-card captures were inspected.
This validates the documented adapter scope only. Original resource bindings
were checked separately and kept local; original GPU/audio execution and a
physical iPhone remain unverified.

The next dispatcher work is explicit: chapter 0 ends by incrementing the
chapter index and opening script 1 through action 4 in `0x0052bcf0`. After
script chapters 0/1/2, chapter 3 dispatches the first nonscript scene at
`0x00512cc0`. The current adapter stops at the first chapter boundary.
