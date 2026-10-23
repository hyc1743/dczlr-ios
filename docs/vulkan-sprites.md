# Native Vulkan sprite backend

`native/render/vulkan/dc_vk_sprite.c` executes the reconstructed sprite entry,
draw plans and vertex generator through Vulkan 1.0. This is an optional backend;
the CPU resource library does not depend on a Vulkan SDK. The current API renders
to an offscreen RGBA8 attachment and blocks for tightly packed pixel readback.
It does not yet present through the iOS host or execute the game state machine.

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
behavior. The existing iOS host remains a direct Metal diagnostic until its
MoltenVK integration is complete. No playable build is established by this gate.
