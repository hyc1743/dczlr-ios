"""Prepare a pinned, source-only BoxedVN interpreter CPU experiment.

The checkout must be disposable: this changes its CMake configuration. The
experiment runs upstream CPU tests, not Wine, a game, or any user assets.
"""
import argparse
from pathlib import Path
import subprocess

PIN = "7b6e03575922967ca161f2b55c39846e242916f6"


def prepare(root):
    root = root.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if revision != PIN:
        raise ValueError("Upstream checkout does not match the reviewed revision")
    cmake = root / "CMakeLists.txt"
    source = cmake.read_text(encoding="utf-8")
    flag = "\n    BOXEDWINE_MAC_JIT\n"
    if source.count(flag) != 1:
        raise ValueError("JIT configuration changed; refusing an ambiguous patch")
    source = source.replace(flag, "\n")
    source += '''
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
    cmake.write_text(source, encoding="utf-8")
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
    prepare(parser.parse_args().checkout)
