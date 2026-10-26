# Real-resource playability checks — 2026-10-26

## Version 0.1.7: actual touch-control route

Run `40307596134` from game code `c0bd2fd` passed 261 portable tests, the
simulator build, UIKit control ownership/window checks, the real-resource
touch route and unsigned ARM64 device packaging. Unlike the older tests
below, this route targets visible controls through the actual window hit
test and UIKit touch handlers. Raw controller injection is disabled.

Observed actions include title confirmation, script continuation, the
optional position-adjustment menu, camera drag, the visible Save button,
interaction completion and the visible Next Chapter action. The first
native GPU frame and the saved player/story records are checked too.
See [Touch controls](touch-controls.md) for the scene-specific layout and
the bounds of the test. Full original gameplay and physical-device finger
delivery remain unverified; the later-map placement finding below remains.

## Earlier bounded gameplay checks

The initial native gameplay routes pass on an iPhone 16 Pro simulator running
iOS 18.5. This does **not** establish complete game playability or physical
iPhone compatibility.

The simulator app was built in run `40292990624` from `9731f6f`. Its `ios/`
and `native/` sources are identical to the released `07bbcff` hotfix. Run
`40297158735` reused that binary and verified the source match before testing.
Both real-resource routes in that run succeeded. Original resource parts were
decrypted with the existing Actions secret and restored into a fresh app
container for each route.

| Check | Observed result | Scope |
| --- | --- | --- |
| Startup and New Game | Passed | Real resource loading and scripts 0–2 |
| First gameplay scene | Passed | Native GPU frame shows the actor and environment; animation advanced |
| Movement and camera | Passed | Controller axes changed native player position and camera |
| Interaction | Passed | Completion marker after gameplay presentation |
| Save data | Passed | Actual 104-byte file; native player and story readers both returned `DC_OK`, map 0 / chapter 3 |
| Script/gameplay handoff | Passed | Ordered scripts 0–2 → gameplay → interaction → script chapter 4 |
| Later progression | Observed, not certified | Logs also reached a second gameplay scene and script chapter 6 |
| Local resource/state audit | Passed | 8 maps and 26 chapter descriptors; no Apple rendering in this audit |
| Full game / title Load / long session / background resume | Not covered | Requires additional UI scenarios |
| Physical device / audible output / original visual equivalence | Not covered | Simulator and playback clocks are insufficient |

The real-controls log records movement, camera and skinning advancement at
`2026-10-26T09:15:23Z`, followed by interaction completion at `09:15:25Z`.
The story log records the first gameplay scene at `09:19:14Z` and chapter 4
at `09:19:18Z`. No texture-upload failure was reported in either route.

## Evidence corrections

The earlier run `40292990624` passed its bounded story check, but its native
capture filename was overwritten by a later scene before the harness copied
it. A loose color check also accepted blue-grey background silhouettes as an
actor. That capture cannot certify the first scene.

The harness now copies the native frame immediately on the first gameplay
event, before issuing the potentially slow `simctl screenshot` command. The
visual check requires saturated outfit pixels and a separate skin-color
region. Both routes in `40297158735` captured the correct first scene: 46,088
outfit pixels, 98,467 skin pixels, at 2622 × 1206. This remains a bounded
visibility heuristic, not an image-equivalence test. Window screenshots and
native target readbacks remain separate evidence.

Run `40295754805` failed because of a cold-simulator uninstall timeout and a
Python import-shadowing error in the new harness. These are test
infrastructure failures and are excluded from game-functionality conclusions.
The corrected harness passed 253 local portable tests before the successful
replay.

## Remaining finding: later-map placement

`DCGameScene.findAnchor:` searches only `m_Nn_yuka_l_a/b/c`. Those names are
present in map 0 and absent in maps 1, 3, 4, 5, 6, 7 and 8. Initialization
falls back to an identity world matrix when no anchor is found. The current
story integration uses this initializer for later maps too.

An earlier later-scene native capture shows an obstructed view without a
clearly visible main actor. The anchor mismatch is a confirmed source/resource
finding and a plausible contributor; a per-chapter GPU capture and placement
trace are still needed to establish the complete visual cause. Later-map
placement is **not fixed or certified by these tests**.

## Repeat the checks

Dispatch `.github/workflows/test-real-game.yml` with a successful
`build-ios.yml` run ID and the existing encrypted resource URLs/hashes. The
workflow rejects an app whose native/iOS source differs from the checkout.
Its `real-game-playability-evidence` artifact contains per-route logs, native
frames, reports and the small reconstructed save record; it does not upload
the original resource bundle.

The retained local results are under
`out/playability-07bbcff/verified-replay/real-game-controls/` and
`out/playability-07bbcff/verified-replay/real-game-story/`. The map-anchor
inventory is `out/playability-07bbcff/map-anchor-check.json`.
