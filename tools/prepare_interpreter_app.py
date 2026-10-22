"""Stage the genuine upstream iOS frontend with an interpreter-only launch path.

Works on a disposable checkout pinned by prepare_interpreter_probe. No game
files or user data are copied. Upstream GPL notices remain in that checkout.
"""
import argparse
from pathlib import Path
import plistlib
import re

from prepare_interpreter_probe import prepare


def replace_once(source, old, new, description):
    if source.count(old) != 1:
        raise ValueError(description + " changed in the pinned source")
    return source.replace(old, new)


def prune_missing_optional_sources(source, ios_directory):
    def select(match):
        block = match.group(0)
        if re.search(r"(?m)^\s+optional:\s+true\s*$", block):
            relative = match.group(1).strip().strip("'\"")
            if not (ios_directory / relative).exists():
                print("Omitted missing optional resource: " + relative)
                return ""
        return block
    return re.sub(r"(?m)^      - path: ([^\n]+)\n(?:        [^\n]*\n)*", select, source)


def stage(root):
    root = root.resolve()
    prepare(root, "ios-core")

    cmake = root / "ios/runtime/CMakeLists.txt"
    text = replace_once(cmake.read_text(encoding="utf-8"),
                        "\n    BOXEDWINE_JIT\n", "\n", "Runtime JIT definition")
    cmake.write_text(text, encoding="utf-8")

    runtime = root / "ios/runtime/src/BVNRuntime.mm"
    text = runtime.read_text(encoding="utf-8")
    start = text.index("    const BVNJITReport jit = probeJitWithTimeout();")
    end = text.index("\n    if (useFEX64) {", start)
    original = text[start:end]
    text = text[:start] + "#ifdef BOXEDWINE_JIT\n" + original + '''
#else
    if (useFEX64) {
        error = "This interpreter build supports only the 32-bit backend.";
        return boxedvn::LaunchPreflightOutcome::Rejected;
    }
    BVNLogWrite(BVNLogLevelInfo, "cpu",
                "Interpreter backend selected; JIT preparation is not required.");
#endif
''' + text[end:]
    start = text.index("    const BVNJITReport startupJIT = BVNJITProbeStatus();")
    end = text.index("\n    setState(BVNRuntimeStateIdle);", start)
    original = text[start:end]
    text = text[:start] + "#ifdef BOXEDWINE_JIT\n" + original + '''
#else
    BVNLogWrite(BVNLogLevelInfo, "cpu", "Interpreter build; no executable-memory request.");
#endif
''' + text[end:]
    runtime.write_text(text, encoding="utf-8")

    header = root / "ios/runtime/include/BVNRuntime.h"
    text = replace_once(header.read_text(encoding="utf-8"),
                        "void BVNGuestPointerSettingsSet(BVNPointerSettings settings);",
                        "void BVNGuestPointerSettingsSet(BVNPointerSettings settings);\n"
                        "const char *PortLabInterpreterBackendName(void);",
                        "Backend marker declaration point")
    header.write_text(text, encoding="utf-8")

    sources = root / "ios/app/Sources"
    (sources / "PortLabBackend.swift").write_text('''
import Foundation

extension AppModel {
    var runtimeNeedsJIT: Bool {
        String(cString: PortLabInterpreterBackendName()) != "interpreter"
    }
    var cpuBackendReady: Bool { !runtimeNeedsJIT || jit.isUsable }
    var cpuBackendStatus: String {
        runtimeNeedsJIT ? (jit.isUsable ? "JIT ready" : "JIT unavailable") : "Interpreter (no JIT)"
    }
}
''', encoding="utf-8")

    views = sources / "Views.swift"
    text = replace_once(views.read_text(encoding="utf-8"),
                        'Text(model.jit.isUsable ? "JIT ready" : "JIT unavailable")',
                        "Text(model.cpuBackendStatus)", "Backend status label")
    text = text.replace("model.jit.isUsable", "model.cpuBackendReady")
    text = replace_once(text,
                        "            JITStatusSection()\n            JITHintSection()",
                        '''            if model.runtimeNeedsJIT {
                JITStatusSection()
                JITHintSection()
            } else {
                Section("CPU backend") {
                    Text("x86 interpreter")
                    Text("This build does not require enabling JIT.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }''', "JIT setup section")
    views.write_text(text, encoding="utf-8")

    spec = root / "ios/project.yml"
    text = replace_once(spec.read_text(encoding="utf-8"),
                        "PRODUCT_BUNDLE_IDENTIFIER: org.boxedwine.boxedvn",
                        "PRODUCT_BUNDLE_IDENTIFIER: org.example.portlab", "Bundle identity")
    text = prune_missing_optional_sources(text, root / "ios")
    spec.write_text(text, encoding="utf-8")
    info = root / "ios/app/Info.plist"
    document = plistlib.loads(info.read_bytes())
    document["CFBundleDisplayName"] = "PortLab Interpreter"
    info.write_bytes(plistlib.dumps(document))
    print("Staged real 32-bit interpreter app; no game files or Wine rootfs bundled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    stage(parser.parse_args().checkout)
