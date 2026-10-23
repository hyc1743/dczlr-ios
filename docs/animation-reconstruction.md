# Animation controller request and query

`native/game/dc_animation.c` restores two bounded operations of the original
model animation controller. It does not yet load animation data or advance the
controller per frame, so it cannot drive the startup screen by itself.

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

The next evidence boundary is XA loading and frame advancement: static exports
identify `0x0040bd50` as the XA loader, `0x00404890` as the delta/speed setter,
`0x00404bd0` as frame advancement and `0x00405670` as the pose/material update.
These have not been reconstructed by this module. Original transition-record
values, animation chaining, the fullscreen transition model, sampling and final
screen composition still need validation. The view's existing fixed two-second
title preview remains temporary; neither that preview nor this leaf-function
comparison proves game playability.
