# New-game script host

The Apple view now uses `dc_title_build_plan` to route New Game after the
original transition and selection-player gates. The startup transition model
continues across title and intro scenes; external sprites render below its
projected meshes. Renderer rebuilds retain CPU scene state and recreate GPU
textures. Backgrounding pauses audio and excludes suspended transition time.

`DCIntroScene` initializes the reconstructed 59,960-byte numeric game state
and follows the original 26-entry chapter descriptor table. The opening
script chapters use `RPP_16.pp/00.txt`, `01.txt` and `02.txt`, with terminal
records 2, 31 and 9. Background EMA resources come from RPP_02;
music, effects and voice come from RPP_01, RPP_14 and RPP_00 respectively. Media
bytes stay in local user resource files. No original image, audio or dialogue
is included in the source tree or CI.

The normal text controller now supplies original byte-pair positions, alpha,
line/frame state and forward-input behavior; see `text-controller.md`. The
Apple adapter decodes CP936 and rasterizes cells with a fallback font. It no
longer previews the complete record immediately. Backlog, voice gating,
broader input and subsequent nonscript gameplay remain unfinished. At the
first nonscript boundary, chapter 3, the host reports the missing callback.
Load/edit/extra/options are also pending.

The generated simulator fixture exercises startup cards, title pointer
hover/press/release, transition/sound waits, CP936 text, normal numeric fade,
three audio playback clocks, records 0–2 and the reload into chapter 1.
`PORTLAB_EXERCISE_NEW_GAME=1` supplies a test pointer through the normal input
adapter. Normal launches use user input. Exact first-record GPU readback
checks generated background and body-text pixels. Generated text and media
are self-authored. This check does not establish original-resource GPU/font
equivalence, audibility, physical-device playability or full compatibility.

The previous source `44a2099` passed both Apple workflows: 156 portable tests, 115 native
ARM64 tests, all 16 iPhoneOS native objects, unsigned device packaging and
the generated simulator route on iPhone 16 Pro/iOS 18.5. The generated
background/text screenshot and exact startup-card captures were inspected.
This validates the documented adapter scope only. Original resource bindings
were checked separately and kept local; original GPU/audio execution and a
physical iPhone remain unverified.

The next dispatcher work is explicit: chapter 0 ends by incrementing the
chapter index and opening script 1 through action 4 in `0x0052bcf0`. After
script chapters 0/1/2, chapter 3 dispatches the first nonscript scene at
`0x00512cc0`. `dc_intro_finish` and `dc_intro_transition` now restore the
numeric end-of-script and transition helper logic, including callback backup,
audio-stop order, selector/stage admission and progression flags. Isolated
original functions match 567 chapter-end and 2,568 transition cases. The Apple
host connects script reloads; nonscript and auxiliary destinations are pending.

A private local CPU audit follows all 45 opening records, 875 text ticks and
48 original forward-input comparisons through these three chapters. All
pending media references resolve and their admitted EMA/PCM profiles parse:
six background, three music, one sound and 33 voice references. External
transition readiness is synthetic in this audit; no original media is rendered
or uploaded, and this is not original GPU/audio or gameplay execution proof.

Source `6ee92da` passed both Apple workflows: 166 portable tests, 124 native
ARM64 tests, all 17 iPhoneOS native objects and unsigned device packaging.
The iPhone 16 Pro/iOS 18.5 generated run presented records `0:0`, `0:1`,
`0:2`, then `1:0`, with normal text fade and all three audio playback clocks.
Exact first-record GPU capture passed 9/9 background samples and 2,205 bright
body-text pixels; the self-authored Chinese sentence and width-fitted ASCII
chapter text were inspected. This remains a partial script host. First
nonscript gameplay, broader input/backlog/options/save-load, original media
GPU/audio equivalence and physical-device playability remain unverified.
