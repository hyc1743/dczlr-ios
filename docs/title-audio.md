# Title audio adapter

The original title initialization has a continuation through `0x0062df2c` to
`0x005126f3`; stopping at the initial decompiler function would miss menu
setup, unlock checks, background music and the fade-in request. This is an
important analysis boundary for the remaining title/game integration.

That continuation loads `bgm000` with audio-kind 1 and `se100` with kind 0.
`0x00605110` maps these kinds to `RPP_01.pp` and `RPP_14.pp`, respectively,
and appends `.wav`. The local entries are PCM WAV, mono, 22050 Hz, 16-bit. The
background music is started with the original looping flag. Resource bytes
and audio samples remain local.

`DCGameAudio` uses the native bounded PP adapter to read these entries and
AVAudioPlayer to decode/play them. It loops title music, rewinds the selection
sound for each activation, pauses playback for the background lifecycle and
keeps the audio object across renderer resize. Loading or playback errors fail
explicitly. The original full volume/mixer/fade behavior, voice sequencing and
in-game audio driver remain unimplemented.

When the native chapter-3 scene is entered, `DCGameAudio` also validates and
prepares the three effect resources named by the original scene callback:
`RPP_14.pp/se016.wav`, `se322.wav` and `se332.wav`. They remain available to
the later event router; no guessed event-to-sound mapping is claimed yet.

The original callback builds 35 `RPP_14` sound slots. Static string/data
binding places `se016.wav` at slot 10, `se322.wav` at slot 17 and `se332.wav`
at slot 20. The direct `0x00513690` state branches at input keys `0x3b` and
`0x3c` use slot 0 (`se100.wav`) for the verified selection/transition sound.
The broader action dispatcher `0x00532240` plays context-owned slots at
offsets `0x106c` and `0x1070`; its caller-owned context and the three gameplay
effect slots are not statically bound to the local interaction state yet, so
the port does not trigger them speculatively.

A bounded local Windows startup/title probe now correlates runtime `ReadFile`
sizes with the local PP index: the title path reads `bgm000.wav` from
`RPP_01.pp` (1,542,284 bytes) and `se100.wav` from `RPP_14.pp` (104,986 bytes).
This confirms the title bindings at runtime for the renamed local copy with a
temporary x86 D3DX dependency. No gameplay interaction was injected in that
probe, so it does not resolve `se016/se322/se332` triggers or prove audible
output.

`PORTLAB_TITLE_AUDIO_ADVANCED` requires the title to have presented and the
playing background track's clock to advance beyond 0.1 seconds. The simulator
startup gate supplies generated PCM tones through generated PP archives and
requires this marker in addition to both startup-card waits and title
presentation. Playback clock progression is not proof of audible device
output, correct loudness or original-sound equivalence.

The title pointer adapter now uses the verified `dc_menu_step` for hover and
selection sound. Its five menu actions still need the original callback/state
dispatch and subsequent scenes. Save-prefix unlock decisions now supply its
edit/extra availability; full save-game restore is separate. It does not
claim original full callback equivalence; the native title load route now enters
the local saved gameplay scene and the local playable-loop audit covers its
resource and state transitions.
