# Native Vulkan sprite backend

`native/render/vulkan/dc_vk_sprite.c` executes the reconstructed sprite entry,
draw plans and vertex generator through Vulkan 1.0. This is an optional backend;
the CPU resource library does not depend on a Vulkan SDK. The current API renders
to an offscreen RGBA8 attachment and blocks for tightly packed pixel readback.
The optional Apple path blits this target on the GPU to a Metal surface's Vulkan
swapchain and presents through MoltenVK. It does not execute the game state machine.

The two shaders are independently authored GLSL equivalents for the admitted
fixed-function sprite profile. They are not the 135 converted original shaders.
The backend supports a repeated RGBA8 texture, point/linear minification and
magnification, a single mip, ordered triangle strips, and the observed normal,
additive and multiplicative blends. Color and alpha use the original common
blend factors. The native point-filter override restores linear filtering after
the draw, including when the frame inherited point filtering.

The profile explicitly disables depth testing, alpha testing, culling, lighting,
specular and additional texture stages. These inherited states have not all been
recovered from original runtime evidence. It must not be used for other render
paths without recovering their contracts. Software vertex processing has no
effect on the already transformed XYZRHW vertices. The shader adds half a pixel
to translate integer D3D9 pixel centers to Vulkan centers.

Alpha-op DISABLE is admitted only with an opaque texture and diffuse alpha 255.
Transparent sprites require the observed mode-3 alpha modulation. Unknown
combinations fail rather than inventing the original D3D9 transparency behavior.
Pixels are raw RGBA attachment values; the API does not unpremultiply them.

Build and run with a Vulkan SDK, glslangValidator, spirv-val and the Khronos
validation layer installed:

```sh
cmake -S native -B out/vulkan -DPORTLAB_VULKAN_SPRITES=ON
cmake --build out/vulkan
out/vulkan/vulkan_sprite_gate
```

The `Verify Vulkan sprite pixels` workflow uses Mesa lavapipe, a software Vulkan
driver. The self-authored test checks readback pixels for color/alpha blending,
filtering and repeat, native state transitions, hidden sprites, rejected frames,
stale handles and repeated rendering. It requires zero validation errors.
This checks real Vulkan execution against independent expected pixel values;
it does not establish equivalence with original D3D9 GPU output or iPhone GPU
behavior. The iOS host uses this backend for a self-authored checker while a
user imports data. Once `RPP_02.pp` is available, the native archive/image path
uploads and draws its original `illusion.ema` startup card. Later game states
and the original transition effects remain unimplemented.
MoltenVK changes `CAMetalLayer` properties during swapchain creation, so the
backend drains pending GPU work on its render queue and marshals swapchain
creation to UIKit's main thread. Frame rendering and presentation stay on the
serialized Vulkan worker. On iOS Simulator only, the host disables Metal
argument buffers before the first Vulkan call because the observed simulator
`SimMetalHost` process terminated during descriptor texture updates. Physical
iOS builds retain MoltenVK's default argument-buffer configuration.
Readback can be omitted for presentation; the initial backend serializes frames
and waits for completion, so it is a correctness foundation, not a tuned renderer.
No playable build is established by this gate.

The first cloud run `39932627781`, revision `d9107c0`, passed all 48 rendered
frames on lavapipe with zero validation errors. The same gate also passed on a
local Intel UHD 630 physical GPU, without an installed validation layer. The
additional readback-free frame and Apple integration passed in `39933932173`.

The expanded gate passed in run `39935745202`, revision `3aa5cce`: 51 frames in
the main scenario plus three frames on a fresh renderer with inherited point
sampling. It checks varying UV orientation, pivot rotation, restoration to
linear after an override, and reset to the configured inherited state each
frame. This passes on lavapipe with validation enabled and on MoltenVK's Apple
Paravirtual GPU without the Khronos layer. The same 54-frame sequence passes
both offscreen and with a CAMetalLayer swapchain. This Apple cloud GPU is not a
physical iPhone. A local Intel UHD 630 also passes the expanded pixel gate.

Run `39946226699` at revision `cda1f88` passed an actual iPhone 16 Pro
simulator frame on iOS 18.5. The screenshot and app log show the self-authored
checker sprite on the Vulkan surface; the simulator app contained no original
game assets. This confirms simulator rendering, not physical iPhone behavior.

The clean view lifecycle and corrected fallback pivot passed again in run
`39950383413`, revision `768c1da`: the app launched, presented its Vulkan frame
and produced a screenshot. Its collected Unity log contains no SwiftUI
"Publishing changes from within view updates" warnings. The Apple Simulator
also no longer terminated `SimMetalHost` during texture descriptor updates.
The fallback remains the self-authored checker because the cloud app contains
no original game data.

Presentation reporting now distinguishes the checker, startup card and title
preview. The native completion returns an explicit scene only after a successful
Vulkan render/present; Swift records each scene change with
`PORTLAB_SCENE_PRESENTED=checker`, `startup` or `title`. Texture loading alone
does not emit a presentation marker. The simulator checker requires a selected
scene (`--expected-scene`, default `checker`); a fallback frame cannot satisfy a
startup/title requirement. Its report records the observed scenes and leaves
resource-content inspection, physical-device behavior and playability separate.
The cloud gate still uses only the self-authored checker and supplies no game
resources. These reporting changes passed device and simulator builds in run
`39962543987`, source `df701d6`. The collected app log reports only `checker`,
and the inspected screenshot shows the self-authored four-color sprite. This
does not validate original startup/title resources or physical-device behavior.

`tools/bootstrap_moltenvk.py` verifies the official public-API 1.4.2 release
archive against its pinned 180,474,368-byte length and SHA-256 before extraction.
The all-platform archive includes device, simulator and macOS static slices.
For local iOS builds, run this tool with
`--notices-output ios/Generated/MoltenVKNotices` and generate the shader header under
`ios/Generated/sprite-shaders` before running XcodeGen. The Apple CI job runs the
same numeric pixel gate offscreen and with an actual CAMetalLayer swapchain.
An API presentation success does not by itself prove a user inspected the screen.

A separate local integration check decoded the two original 1024x768 startup
EMA entries from the native PP reader and uploaded/drew them on the Intel Vulkan
GPU. With explicitly selected texel-center UVs, both complete RGBA readbacks
matched the independently computed blend exactly. These images and the detailed
report remain local (`research/native-core/startup-texture-upload.json`). The
unadjusted 0..1 UV trial for the first image did not match a direct pixel copy:
integer-center sprite geometry places point samples on texel boundaries. Both
the mismatch and successful center-sampling trial are retained. This check proves
the resource-to-texture path for those inputs, not original D3D9 sampling
equivalence or an integrated startup screen.
