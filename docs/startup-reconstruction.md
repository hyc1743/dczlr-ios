# First game-state reconstruction

The first startup update now has a portable C state/action planner in
`native/game/dc_startup.c`. It covers the observed two-card update and its
transition helper, not the entire game initialization. It is linked into the
native library and iOS target but is not yet driving the view: the original
external transition controller and subsequent game states still need restoration.

The static route on the pinned PE is CRT entry `0x0062065e`, WinMain
`0x00464b90`, nested game initialization/frame loop `0x004621f0`, then initial
callback `0x00511f20`. That callback installs update `0x00512050`, sprite draw
`0x00512150` and cleanup `0x00512020`. The update first invokes helper
`0x0052bc10`. A completed external state 1 unlocks timing. A completed state 3
loads card 1 after card 0, or releases the current card and replaces the update
callback with `0x00512370` after card 1. The native planner represents that last
boundary as `ENTER_NEXT`; it does not pretend the next state is implemented.

When timing is unlocked, elapsed adds the supplied delta and compares against
2,000 for card 0 or 30,000 for card 1. Exact input byte 3 requests external state
3 immediately. A timeout requests external state 2. Both reset elapsed to zero
and lock timing pending another completed transition. Loading the replacement
card requests external state 4. These numeric states are preserved rather than
assigning unverified animation semantics to them.

The original comparisons use unsigned carry branches. Decompiler output alone
misrepresents their signedness. The native implementation uses explicit unsigned
32-bit wrap, including negative delta bit patterns. A completed transition is
processed before adding delta, so timing may start and expire in the same update.

The source of the route above is standalone Ghidra 12.1.4 read-only exports from
the existing local analysis project, not a new REA native-provider result. The
connected REA provider lacked Ghidra configuration; the existing standalone engine
and database were reused. Original pseudocode, assembly, resources and binaries
remain under ignored local paths. The complete bounded trace is retained locally
as `research/native-core/startup-trace.json`.

`tools/oracle_startup.py` separately executes only the analyzed 247-byte update
and 209-byte helper in Unicorn. Transition query/request and card load/release
are synthetic host boundaries. It guards original instruction addresses, writes,
return addresses and the instruction count; it never starts the Windows game,
uses real resources or calls a GPU. All 5,600 self-authored cases match native
state and ordered actions. Inputs cover both cards, pending/unlocked transitions,
five input bytes, completed external states 1/2/3/4, threshold boundaries and
32-bit wrap. Public fixtures retain inputs/results and hashes, not original code.

```sh
python tools/oracle_startup.py --exe research/target.exe \
  --output research/native-core/startup-oracle.json \
  --vectors tests/fixtures/startup-original-vectors.json
python -m unittest discover -s tests -p test_native_startup.py -v
```

The full local suite has 54 tests. Startup's resource operations, initial
configuration, original screen-transition implementation, next state's logic,
models, audio, saves and playable-device validation remain separate work.
