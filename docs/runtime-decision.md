# Execution runtime investigation

The current goal is native AArch64 execution with direct Metal and offline
shader translation, as defined in `native-runtime-design.md`. The interpreter
work below is retained as a historical experiment; it is not the chosen
delivery architecture and its phone tests are not a prerequisite.

The preferred research constraint is ordinary sideloading with no manual JIT
step. Personal device information is not part of this public source document.

The original diagnostic PortLab IPA built without a Windows loader or x86 engine.
Game data and shader conversion alone cannot make its Windows PE32 input run.
The Switch reference already starts from ARM64 code, a different execution
problem. A game-specific port still needs its own implementation and tests.

## Upstream source review

| Source | Pinned revision | Finding |
| --- | --- | --- |
| willfaust/Madeira | 279fd0f83170425db002fe25d6bd62f6355f497d | README describes FEX, Wine WoW64 and DXMT; explicitly requires JIT. Its clean-build document also lists missing toolchain inputs. |
| 125hz/BoxedVN | 7b6e03575922967ca161f2b55c39846e242916f6 | iOS README and build configuration require JIT. Boxedwine also contains interpreter code; its usability in this iOS configuration is unproven. |
| Contonion/WineGlass | README reviewed only | Describes PE32 handling and Win32 dialogs. This does not establish complete D3D9 game support. |

These are upstream claims and source observations. No candidate has been
executed against the supplied game or tested on the target phone. In particular,
the presence of a 32-bit backend does not prove D3D9 or audio compatibility.
Local review snapshots are kept under ignored `research/runtime-candidates/`.

## Next experiment

The manually dispatched `runtime-interpreter.yml` workflow compiles the pinned
BoxedVN source with its JIT selection removed and a compile-time assertion that
`BOXEDWINE_JIT` is absent. It runs a bounded subset of upstream CPU self-tests
on the macOS runner. It does not load Wine, a Windows game or its data.

A passing test would establish only a host interpreter baseline. It would not
establish iOS startup, graphics, audio, acceptable speed or game playability.
The existing app will not advertise the interpreter as ready until those later
gates have real execution evidence.

The host experiment has now passed: run `39871262517`, revision `6510113`,
compiled the interpreter on an ARM64 macOS runner and executed 16 upstream
baseline tests with zero failures. Its log explicitly reports that no JIT
backend was compiled. The run took four seconds to execute those tests; this
is not a game performance measurement.

`runtime-ios-core.yml` is the next gate: compile the real interpreter archive
against the iPhoneOS SDK, without test-only flags and without a JIT backend.
It does not yet launch Wine or a game, and it does not replace the app's
runtime with a pretend implementation.

The iOS core gate has passed in run `39873046529`: the downloaded archive
contains 177 ARM64 Mach-O objects and the no-JIT backend assertion compiled.
`runtime-ios-app.yml` now builds the genuine launch bridge and upstream
frontend, with interpreter startup separated from JIT preflight checks.
That app build is not yet evidence of guest execution.

The actual interpreter App gate has passed in run `39877459414`. The inspected
IPA is an iOS-device ARM64 executable; its interpreter backend symbol and
non-JIT launch path are linked. No Wine root filesystem or original game is
bundled. This still does not establish phone startup or game playability.

The first Wine console experiment, run `39877142723`, did not emit the required
marker within its deadline. It loaded the pinned Wine root archive and produced
X11 window events. This is a failed boot gate, not a successful Wine test. The
next run enables Wine exception diagnostics and uses a console-only profile
that disables optional HTML/.NET installation prompts. That profile is confined
to the console test; it is not a claim of general game compatibility.

The independent `runtime-wine-boot.yml` gate runs the real macOS interpreter
host without test-only flags. It downloads the hash-pinned upstream Wine 11
runtime and asks `cmd.exe` to emit an exact output line. Only guest output
counts; printing the command line cannot pass. The harness stops after a hard
deadline and records shutdown separately from whether Wine executed the command.
Graphics, audio, iOS execution and game playability remain separate gates.

Run `39878555474` passed that console execution gate. The retained guest log
ends with the exact `PORTLAB_WINE32_OK` line (surrounded by terminal cursor
escapes), and the report records 31.08 seconds. The host was subsequently
stopped by the bounded harness with exit code 1, so this is evidence of command
execution, not clean host shutdown. Changing the diagnostic profile made the
test pass; it does not isolate which change resolved the initial timeout.

The next gate in the same workflow compiles `probes/win32_smoke.c` as a static
PE32 executable, mounts only its artifact directory and launches it through
Wine in a separate scratch prefix. It checks a temporary file roundtrip,
thread/event completion and exit status, 64 known offscreen GDI pixels, and
WinMM submission/completion of a silent PCM buffer. The harness requires all
four exact subsystem markers plus the final marker. SDL uses a dummy audio
device; neither audible output nor on-screen presentation is established.
D3D9 and physical iOS execution remain untested by this gate. No original
application executable or resources are used or uploaded.

Run `39879664469` passed all four checks and emitted the final Win32 marker.
The report records 27.16 seconds, with host shutdown still controlled by the
harness. Audio telemetry confirms the silent PCM buffer reached an SDL device
and was converted from 22050 Hz to 44100 Hz; audible output is not established.
The macOS native-audio CoreAudio selection concerns MIDI, while this PCM path
is implemented by `platform/sdl/kdspaudio.cpp`. The iOS frontend now stages the
same self-authored probe and offers a dedicated compatibility-check button,
using its own scratch directory and prefix. It does not apply the probe's
installer overrides to other launch profiles. Device execution remains open.

The persistent-report variant passed in run `39881581198`. Both the console
gate and the self-authored Win32 gate emitted their required markers. The
artifact additionally contains `portlab-win32-result.txt`, written by the
guest into the mounted probe directory, with all six expected lines. The
Win32 harness reports 36.82 seconds including shutdown handling. The host was
still stopped by the harness, so clean exit remains open. The iOS build that
bundles this report-writing probe and its report viewer passed in run
`39880869873` (source `45f7976`); downloaded IPA contents and PE32 identity
were verified, with physical iOS execution still pending.

## Correction to the earlier shader investigation

The previous token scanner undercounted both comments and instructions by one
DWORD: the encoded lengths count following tokens, not the leading token.
This caused operands and comment data to be labelled as instructions. The old
`bounded-tolerant` IR and preferred-shader selection are not trusted converter
inputs. `parse_dx9_shader.py` now checks framing without silently skipping
unknown tokens, and its regression tests cover these length errors. It still
does not validate full shader semantics or technique ownership.
