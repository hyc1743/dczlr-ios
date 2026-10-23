"""Prepare a real no-JIT macOS host for a bounded Wine console boot test."""
import argparse
from pathlib import Path
from prepare_interpreter_probe import prepare


def stage(root):
    root = root.resolve()
    prepare(root, "macos-core")
    with (root / "CMakeLists.txt").open("a", encoding="utf-8") as output:
        output.write('''
# No video is requested by this console probe. The shipping iOS Vulkan path
# remains enabled in the separate iOS build.
add_executable(portlab_wine_host
    "${CMAKE_CURRENT_SOURCE_DIR}/portlab_wine_host.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ios/support/src/macos_host_platform.mm")
target_link_libraries(portlab_wine_host PRIVATE
    -Wl,-force_load $<TARGET_FILE:boxedwine_core> boxedwine_core)
foreach(name Cocoa CoreGraphics Carbon IOKit ForceFeedback GameController
             CoreHaptics Metal QuartzCore CoreVideo OpenGL CoreMIDI AudioUnit
             UniformTypeIdentifiers)
    find_library(PORTLAB_FRAMEWORK_${name} ${name})
    if(PORTLAB_FRAMEWORK_${name})
        target_link_libraries(portlab_wine_host PRIVATE "${PORTLAB_FRAMEWORK_${name}}")
    endif()
endforeach()
''')
    (root / "portlab_wine_host.cpp").write_text('''
#include "boxedwine.h"
#ifdef BOXEDWINE_JIT
#error "The Wine console boot probe requires the actual interpreter"
#endif
// The real main() comes from Boxedwine's knativesystem.cpp, not a test stub.
''', encoding="utf-8")
    print("Prepared the real macOS interpreter host for Wine console execution")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    stage(parser.parse_args().checkout)
