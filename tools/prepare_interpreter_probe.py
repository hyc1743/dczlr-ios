"""Prepare a pinned, source-only BoxedVN interpreter CPU experiment.

The checkout must be disposable: this changes its CMake configuration. The
experiment runs upstream CPU tests, not Wine, a game, or any user assets.
"""
import argparse
from pathlib import Path
import subprocess

PIN = "7b6e03575922967ca161f2b55c39846e242916f6"


def fix_interpreter_guard(source):
    # Upstream's selection telemetry uses variables declared in the preceding
    # JIT-only scope. Keep that telemetry inside the same conditional scope.
    old = "        }\n#endif\n        // Account for what a requested selection actually did."
    end = "        BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(memory->mutex);\n        op = memory->getDecodedOp(startIp);"
    if source.count(old) != 1 or source.count(end) != 1:
        raise ValueError("NormalCPU conditional guard changed; refusing an ambiguous patch")
    source = source.replace(old, "        }\n        // Account for what a requested selection actually did.")
    return source.replace(end, "#endif\n" + end)


def guard_diagnostic_function(source, signature, condition, fallback):
    if source.count(signature) != 1:
        raise ValueError("Diagnostic function changed: " + signature)
    start = source.index(signature)
    opening = source.index("{", start)
    closing = source.index("\n}", opening)
    original_body = source[opening + 1:closing]
    return (source[:opening + 1] + "\n#if " + condition + original_body +
            "\n#else\n" + fallback + "\n#endif" + source[closing:])


def fix_process_diagnostics(source):
    source = guard_diagnostic_function(
        source, "static mach_port_t nativePortForThread(KThread* thread)",
        "defined(BOXEDWINE_MULTI_THREADED)",
        "    (void)thread;\n    return MACH_PORT_NULL;")
    return guard_diagnostic_function(
        source, "static void describeNativePc(KProcess* process, uint64_t pc, char* out,",
        "defined(BOXEDWINE_JIT)",
        '    (void)process;\n    (void)pc;\n'
        '    snprintf(out, outSize, " mappedGuest=unavailable-interpreter");')


def fix_rusage_cache_scope(source):
    guard = "#if defined(BOXEDWINE_IOS) && defined(BOXEDWINE_MULTI_THREADED)"
    fields = ("    U64 cachedSelfRusageMicroseconds = 0;\n"
              "    U32 cachedSelfUserSeconds = 0;\n"
              "    U32 cachedSelfUserMicroSeconds = 0;\n"
              "    U32 cachedSelfKernelSeconds = 0;\n"
              "    U32 cachedSelfKernelMicroSeconds = 0;\n"
              "    bool hasCachedSelfRusage = false;\n")
    if source.count(fields) != 1 or source.count(guard) != 1:
        raise ValueError("Thread rusage cache declaration changed")
    source = source.replace(fields, "")
    return source.replace(guard, fields + guard)


def fix_single_thread_vulkan(source):
    begin = ("    DISPATCH_MAIN_THREAD_BLOCK_THIS_BEGIN_WITH_ARG2(\n"
             "        =, &result COMMA &offscreenMetalLayer)")
    end = ("    DISPATCH_MAIN_THREAD_BLOCK_END\n#else\n"
           "    DISPATCH_MAIN_THREAD_BLOCK_THIS_BEGIN\n"
           "    if (!screen->additionalSDLWindowFlags)")
    if source.count(begin) != 1 or source.count(end) != 1:
        raise ValueError("Vulkan creation dispatch scope changed")
    source = source.replace(begin,
        "#ifdef BOXEDWINE_MULTI_THREADED\n" + begin +
        "\n#else\n    [&]() -> U32 {\n#endif")
    source = source.replace(end,
        "#ifdef BOXEDWINE_MULTI_THREADED\n    DISPATCH_MAIN_THREAD_BLOCK_END\n"
        "#else\n    return 0;\n    }();\n#endif\n#else\n"
        "    DISPATCH_MAIN_THREAD_BLOCK_THIS_BEGIN\n"
        "    if (!screen->additionalSDLWindowFlags)")
    begin = ("#ifdef BOXEDWINE_IOS\n    DISPATCH_MAIN_THREAD_BLOCK_THIS_BEGIN\n"
             "    if (!removed.presentation)")
    end = "    DISPATCH_MAIN_THREAD_BLOCK_END\n#else\n    (void)removed;"
    if source.count(begin) != 1 or source.count(end) != 1:
        raise ValueError("Vulkan teardown dispatch scope changed")
    source = source.replace(begin,
        "#ifdef BOXEDWINE_IOS\n#ifdef BOXEDWINE_MULTI_THREADED\n"
        "    DISPATCH_MAIN_THREAD_BLOCK_THIS_BEGIN\n#else\n"
        "    [&]() -> U32 {\n#endif\n    if (!removed.presentation)")
    return source.replace(end,
        "#ifdef BOXEDWINE_MULTI_THREADED\n    DISPATCH_MAIN_THREAD_BLOCK_END\n"
        "#else\n    return 0;\n    }();\n#endif\n#else\n    (void)removed;")


def fix_optional_fairness_statistics(source):
    start_marker = "    static U64 lastThrottleUs = 0;"
    end_marker = "\n    // What the guest spent inside the host's present path"
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError("Vulkan fairness diagnostics changed")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    body = source[start:end]
    source = source[:start] + "#ifdef BOXEDWINE_MULTI_THREADED\n" + body + '''
#else
    klog_fmt("iOS guest performance: %.1f Vulkan frames/sec and %.1f X11 "
             "patches/sec over %u ms; host CPU %.2f cores busy; "
             "native-thread fairness counters do not apply to this interpreter",
             (double)frames / wallSeconds,
             (double)x11PatchDelta / wallSeconds, elapsed, coresBusy);
#endif
''' + source[end:]
    update = ("    lastThrottleUs = throttleUs;\n"
              "    lastThrottleCount = throttleCount;\n"
              "    lastGetrusage = getrusage;\n"
              "    lastSchedYield = schedYield;")
    if source.count(update) != 1:
        raise ValueError("Fairness diagnostic update changed")
    return source.replace(update, "#ifdef BOXEDWINE_MULTI_THREADED\n" + update + "\n#endif")


def prepare(root, mode="cpu-probe"):
    root = root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if revision != PIN:
        raise ValueError("Upstream checkout does not match the reviewed revision")
    cmake = root / "CMakeLists.txt"
    source = cmake.read_text(encoding="utf-8")
    flag = "\n    BOXEDWINE_MAC_JIT\n"
    if source.count(flag) != 1:
        raise ValueError("JIT configuration changed; refusing an ambiguous patch")
    normal_cpu = root / "source/emulation/cpu/normal/normalCPU.cpp"
    fixed_normal_cpu = fix_interpreter_guard(normal_cpu.read_text(encoding="utf-8"))
    process = root / "source/kernel/kprocess.cpp"
    fixed_process = fix_process_diagnostics(process.read_text(encoding="utf-8"))
    thread = root / "include/kthread.h"
    fixed_thread = fix_rusage_cache_scope(thread.read_text(encoding="utf-8"))
    vulkan = root / "platform/sdl/kvulkanSDL.cpp"
    fixed_vulkan = fix_optional_fairness_statistics(
        fix_single_thread_vulkan(vulkan.read_text(encoding="utf-8")))
    source = source.replace(flag, "\n")
    cpu_cmake = '''
# PortLab experiment: the interpreter is selected by omitting the JIT define.
# __TEST enables the upstream CPU test functions; this is not a shipping app.
file(GLOB_RECURSE PORTLAB_CPU_TESTS CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/source/test/*.cpp")
target_sources(boxedwine_core PRIVATE ${PORTLAB_CPU_TESTS})
target_compile_definitions(boxedwine_core PUBLIC __TEST)
add_executable(portlab_cpu_probe
    "${CMAKE_CURRENT_SOURCE_DIR}/portlab_cpu_probe.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ios/support/src/macos_host_platform.mm")
target_link_libraries(portlab_cpu_probe PRIVATE
    -Wl,-force_load $<TARGET_FILE:boxedwine_core> boxedwine_core)
foreach(name Cocoa CoreGraphics Carbon IOKit ForceFeedback GameController
             CoreHaptics Metal QuartzCore CoreVideo OpenGL CoreMIDI AudioUnit
             UniformTypeIdentifiers)
    find_library(PORTLAB_FRAMEWORK_${name} ${name})
    if(PORTLAB_FRAMEWORK_${name})
        target_link_libraries(portlab_cpu_probe PRIVATE "${PORTLAB_FRAMEWORK_${name}}")
    endif()
endforeach()
'''
    core_cmake = '''
# Compile-time backend assertion is part of the actual iOS core archive.
target_sources(boxedwine_core PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/portlab_interpreter_backend.cpp")
'''
    source += cpu_cmake if mode == "cpu-probe" else core_cmake
    cmake.write_text(source, encoding="utf-8")
    normal_cpu.write_text(fixed_normal_cpu, encoding="utf-8")
    process.write_text(fixed_process, encoding="utf-8")
    thread.write_text(fixed_thread, encoding="utf-8")
    vulkan.write_text(fixed_vulkan, encoding="utf-8")
    if mode == "ios-core":
        (root / "portlab_interpreter_backend.cpp").write_text('''
#include "boxedwine.h"
#ifdef BOXEDWINE_JIT
#error "The iOS interpreter core must not contain a JIT backend"
#endif
extern "C" const char *PortLabInterpreterBackendName() { return "interpreter"; }
''', encoding="utf-8")
        print("Prepared iOS interpreter core at pinned revision " + PIN)
        return
    (root / "portlab_cpu_probe.cpp").write_text('''
#include "boxedwine.h"
#include <cstdio>
#ifdef BOXEDWINE_JIT
#error "This experiment must not compile a JIT backend"
#endif
int runTestTestsFromArgs(int argc, char **argv);
int main(int argc, char **argv) {
    std::puts("PortLab CPU experiment: interpreter, no JIT backend compiled");
    return runTestTestsFromArgs(argc, argv);
}
''', encoding="utf-8")
    print("Prepared interpreter-only CPU experiment at pinned revision " + PIN)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--mode", choices=["cpu-probe", "ios-core"], default="cpu-probe")
    arguments = parser.parse_args()
    prepare(arguments.checkout, arguments.mode)
