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

`PORTLAB_TITLE_AUDIO_ADVANCED` requires the title to have presented and the
playing background track's clock to advance beyond 0.1 seconds. The simulator
startup gate supplies generated PCM tones through generated PP archives and
requires this marker in addition to both startup-card waits and title
presentation. Playback clock progression is not proof of audible device
output, correct loudness or original-sound equivalence.

The title pointer adapter now uses the verified `dc_menu_step` for hover and
selection sound. Its five menu actions still need the original callback/state
dispatch, save-based unlock decisions and subsequent scenes. It does not
claim that a click starts playable gameplay yet.
