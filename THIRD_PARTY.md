# Third-Party and Asset Boundary

The MIT license in this repository applies only to original PortLab host code, tooling, workflows, tests and documentation created for this repository.

The supplied Windows executable, DLLs, embedded resources, `Data` directory, save files and any generated `.dczdata` resource parts are not relicensed by this repository. Their copyright, distribution and use remain subject to the rights and permission of their respective owners. Do not publish those files unless you have permission to distribute them.

The iOS experiment uses Apple system frameworks such as MetalKit, AVFoundation and CryptoKit. Xcode and the Apple SDK remain governed by Apple's terms. GitHub Actions uses third-party actions pinned by major version; each action retains its own license and terms.

The independently written D3DX effect record reader uses the binary layout reviewed in Wine `effect.c` and `preshader.c` at `840a939ee526137639665ff5f587224d6a36403f` as a format reference. Wine implementation code is not copied or bundled. Any future imported shader converter must retain its upstream license.

The optional Windows analysis tools load hash-pinned Microsoft D3DX/D3DCompiler DLLs from separately supplied `Microsoft.DXSDK.D3DX` 9.29.952.8. Those DLLs and their headers are not redistributed here or linked into iOS. The effect source, compiled fixture and source-reflection JSON under `tests/fixtures/effect-synthetic*` were generated from this project's self-authored source; they contain no original game shaders or resources. Original shader disassembly and extracted bytecode stay under ignored `research/` paths.

The optional offline converter workflow builds Wine vkd3d 2.1 (previous experiment: 1.17; LGPL-2.1-or-later) and Khronos SPIRV-Tools/SPIRV-Headers at `vulkan-sdk-1.4.304.0` (upstream license notices retained). Tool artifacts include the corresponding source archives and license files. These build-time conversion tools are separate from the iOS native runtime. Their upstream source code is not copied into this repository. The assembly and `.dx9` files in `tests/fixtures/shader-compat/` are separately self-authored regression shaders, with source/binary provenance in `fixture-report.json`; they contain no original game shader bytes.

The manually dispatched interpreter builds fetch BoxedVN/Boxedwine at commit `7b6e03575922967ca161f2b55c39846e242916f6`. That runtime is GPL-2.0-or-later, and its source remains in the upstream repository; the preparation scripts record our build overlays. The separate interpreter-runtime IPA now links that runtime and frontend and retains the upstream license; it is distinct from the original MIT diagnostic host. SDL2 and MoltenVK retain their upstream licenses and pinned download notices. No original game code or game data is included in those builds.
