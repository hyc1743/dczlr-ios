# Third-Party and Asset Boundary

The MIT license in this repository applies only to original PortLab host code, tooling, workflows, tests and documentation created for this repository.

The supplied Windows executable, DLLs, embedded resources, `Data` directory, save files and any generated `.dczdata` resource parts are not relicensed by this repository. Their copyright, distribution and use remain subject to the rights and permission of their respective owners. Do not publish those files unless you have permission to distribute them.

The iOS experiment uses Apple system frameworks such as MetalKit, AVFoundation and CryptoKit. Xcode and the Apple SDK remain governed by Apple's terms. GitHub Actions uses third-party actions pinned by major version; each action retains its own license and terms.

The planned D3DX effect parser and shader converter must preserve the license of the selected upstream implementation. A parser reference in the research notes is not bundled or copied into this repository.

The manually dispatched interpreter builds fetch BoxedVN/Boxedwine at commit `7b6e03575922967ca161f2b55c39846e242916f6`. That runtime is GPL-2.0-or-later, and its source remains in the upstream repository; the preparation scripts record our build overlays. The separate interpreter-runtime IPA now links that runtime and frontend and retains the upstream license; it is distinct from the original MIT diagnostic host. SDL2 and MoltenVK retain their upstream licenses and pinned download notices. No original game code or game data is included in those builds.
