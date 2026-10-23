# Execution runtime investigation

The preferred research constraint is ordinary sideloading with no manual JIT
step. Personal device information is not part of this public source document.

The existing PortLab IPA builds but contains no Windows loader or x86 engine.
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

The independent `runtime-wine-boot.yml` gate runs the real macOS interpreter
host without test-only flags. It downloads the hash-pinned upstream Wine 11
runtime and asks `cmd.exe` to emit an exact output line. Only guest output
counts; printing the command line cannot pass. The harness stops after a hard
deadline and records shutdown separately from whether Wine executed the command.
Graphics, audio, iOS execution and game playability remain separate gates.

## Correction to the earlier shader investigation

The previous token scanner undercounted both comments and instructions by one
DWORD: the encoded lengths count following tokens, not the leading token.
This caused operands and comment data to be labelled as instructions. The old
`bounded-tolerant` IR and preferred-shader selection are not trusted converter
inputs. `parse_dx9_shader.py` now checks framing without silently skipping
unknown tokens, and its regression tests cover these length errors. It still
does not validate full shader semantics or technique ownership.
