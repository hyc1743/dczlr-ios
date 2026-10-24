# Animation controller request and query

`native/game/dc_animation.c` restores two bounded operations of the original
model animation controller, plus numeric per-frame and blend updates. XA loading,
pose/material sampling and the original startup composition remain separate,
so this module cannot yet drive the original startup screen by itself.

The source evidence is the existing read-only Ghidra project for PE SHA-256
`70aebdcde6bd8c252e45db14086fb4ac8837da8dd66c267c05ec7f470f5f9b07`.
Request `0x004046c0` is 464 bytes; query `0x00464ab0` is 69 bytes. The controller
contains 512 records with a 112-byte stride. The C API uses a compact structure
for the fields needed by these two operations, rather than exposing x86 object
offsets or pointers to the Apple host.

The request operation has several observable details:

- It clears the fixed-frame byte even when suppressing a duplicate request.
- The outgoing record's blend duration determines whether the switch is
  immediate. It does not use the destination's duration for that decision.
- A pending request with a nonzero outgoing duration suppresses duplicates even
  when forced. Force bypasses only the separate current-record check.
- An immediate switch preserves the pending index, pending frame and old blend
  end timestamp. A crossfade sets the pending index/frame and preserves current.
- Only a reverse byte of exactly 1 selects the last frame. Other byte values
  select the first frame. The destination iteration byte is reset on admission.
- Blend end ticks use unsigned 32-bit wrap, including near the clock boundary.

The query returns the current record index and whether its loop byte is nonzero.
It does not examine the pending record, a deadline, or an asynchronous completion
flag. The startup planner's `transition_complete` input must receive this exact
query result; it must not be synthesized from a two-second host timer.

`tools/oracle_animation.py` independently executes only those two original
functions in Unicorn. Clock reads and the four-byte memset are synthetic host
boundaries. Instruction addresses, writes, return targets and instruction counts
are guarded. There is no original process, resource loading, Windows API, or GPU.
Its 2,916 self-authored input cases match native state, iteration bytes and query
outputs. Each case runs the original query with and without its optional output
pointer, for 5,832 query calls. The public fixture contains hashes and coverage
metadata, with no original instructions or animation data.

```sh
python tools/oracle_animation.py --exe research/target.exe \
  --output research/native-core/animation-oracle.json \
  --vectors tests/fixtures/animation-original-vectors.json
python -m unittest discover -s tests -p test_native_animation.py -v
```

The portable tests replay the recorded digest without requiring the original
PE or Unicorn. Additional tests cover invalid arguments preserving outputs,
duplicate requests, the last table slot, optional query output and clock wrap.
The native CMake library and iOS source directory include this implementation;
`native-core.yml` also explicitly compiles it into its iPhoneOS archive.
Compilation is separate from physical-device execution.

This revision passed ARM64 macOS behavior tests (35 native tests), explicit
iPhoneOS SDK compilation and the Apple archive/image adapter checks in run
`39962574609`, source `df701d6b9e5a25db3af214664ef11f4a3476ca23`. The downloaded
archive's source hashes match the local C files and include `dc_animation.o`.
The app build at the same source passed all 64 portable tests, device IPA
packaging and the self-authored iOS simulator checker in run `39962543987`.
The animation controller is not yet driving that checker or the game flow.

## Numeric frame and blend update

`dc_animation_advance` restores `0x00404bd0`'s 944-byte numeric frame getter.
It supports current/pending lanes, exact freeze/reverse/loop/chain flag behavior,
endpoint clamping while blending, repeated wrapping and byte iteration counters.
It preserves the original binary32 store before the speed multiplication and
increments a limited loop's counter once per crossing call, rather than once for
every wrapped span. A chained request uses the already verified request function;
the original return-pointer behavior is preserved even when pending advances and
the request changes current or pending.

The API admits finite records with first frame <= last frame. Zero-span loops,
nonprogressing floating-point wraps and more than 4,096 wraps in one call fail
atomically. These checks bound cases where the original can loop indefinitely;
they do not establish equivalence for rejected inputs. Unknown lanes and chain
indices also fail without modifying state, records or the result.

`dc_animation_tick` restores the numeric ordering of the animated-track path in
`0x00405670`. It saves the old current frame, evaluates current once or current
then pending, and only then updates blend progress or promotes pending. The
original unsigned `now < end` comparison is retained, including its immediate
promotion when a wrapped end tick is smaller than the current tick. Elapsed and
duration are each converted to binary32 before the blend division. The API does
not substitute a new clock-wrap rule or clamp unusual finite blend values.

The frame oracle matches 3,920 cases exactly under x87 control words `0x027f`
and `0x037f`. The update oracle matches another 1,584 cases exactly, executing the
original update, frame getter, request, stack probe and empty-target pose walker.
One synthetic bone track has a null target node; root/material/morph/event/
visibility channels are absent. Scratch constructors and zeroing/clock operations
are explicit synthetic boundaries. Original sample-store instructions provide
the observed evaluation order. No real XA, model, pose interpolation or GPU is
executed by either oracle. These selected precision profiles do not prove the
full game's runtime floating-point environment.

```sh
python tools/oracle_animation_frames.py --exe research/target.exe \
  --output research/native-core/animation-frames-oracle.json \
  --vectors tests/fixtures/animation-frames-original-vectors.json
python tools/oracle_animation_tick.py --exe research/target.exe \
  --output research/native-core/animation-tick-oracle.json \
  --vectors tests/fixtures/animation-tick-original-vectors.json
python -m unittest discover -s tests -p 'test_native_animation*.py' -v
```

A separate integration test supplies self-authored clip records and connects
request/query/tick to `dc_startup` through both cards, timeout, replacement and
skip-to-next actions. This proves numeric module coordination, without loading
the original cards or claiming that the Apple view's game flow is implemented.

The Apple checker now uses a self-authored repeating numeric clip for rotation.
It reports advancement only after a successful nonzero-delta update changes the
sample and the frame presents. The simulator checker requires that report as
well as the first-present marker. Machine markers stay in the log rather than
being included in the user's status text.

Source `e5a76fc3d2032fa2c2f3ab2cde7a9b523bae7426` passed all 77 portable tests,
device IPA packaging and the stricter iPhone 16 Pro/iOS 18.5 simulator gate in
run `39968051678`. Its app log contains both the checker-present and native
animation-advanced markers, and its screenshot shows the checker with clean
status text. Run `39968085705` passed 47 ARM64 macOS native tests and iPhoneOS
SDK compilation. Downloaded artifacts were inspected as ARM64/iPhoneOS and
their source hashes matched the pinned commit. These are diagnostic execution
results, not original game or physical iPhone playability.

The native XA metadata reader now supplies the verified controller descriptors;
see [xa-reader.md](xa-reader.md) for the 81-entry framing audit and isolated
original table-loader comparison. The next evidence boundary is model/resource
binding, pose/material sampling,
the fullscreen transition model and final composition. The view's existing
fixed two-second title preview remains temporary. The complete game and physical
device playability remain unverified.

The XA reader also exposes bounded borrowed views for morph index sets, vector
sets, morph target names and per-key value blocks. The local `RPP_09/an00_01.xa`
profile contains 10 index sets, 181 vector sets and 10 tracks, including
encoded targets such as `a_face_me`, `a_face_kuti`, `a_mayu` and `a_yodare`.
These APIs preserve offsets, encoded bytes and six-byte key headers after full
framing validation. The native view layer remains framing-only; the iOS scene
owns the resource-specific binding described below.

`dc_xa_load_morph_vector_sets` provides the validated vector-set view table in
one pass, so the Apple scene does not rescan the full XA payload for every
track key while constructing its cache.

The chapter-3 face resource now has a bounded local binding path. In
`RPP_09/ak00_00.xx` plus `an00_01.xa`, each vector set has one position array
followed by one normal array for the named XX node; the packed 16-bit pairs in
an index set form the affected-vertex mask, and a morph key's first four raw
bytes select a vector-set name in the actor's 1/256-frame time units. The iOS
scene loads the auxiliary face model, attaches it to the animated neck node,
selects the ten real tracks by target name, applies the masked position/normal
updates, and projects the result through the same clipped geometry path. The
local binding audit covers all 10 tracks, 181 vector sets and 50 sampled
track/frame selections. This is resource-level evidence; original facial
controller blending and physical-device presentation remain unverified.
