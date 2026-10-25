#!/usr/bin/env python3
# PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
# Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
#
# Applies the iOS patches to an azahar checkout (pinned commit
# 12bde376ce8fc2012af61ea791f94172a82e67e0). Every anchor must occur exactly once, otherwise the
# script stops without writing anything for that file. Idempotent: files that already contain
# the PlanetPort marker are skipped.
#
# Usage: python3 scripts/patch_azahar.py [path/to/azahar]

import shutil
import sys
from pathlib import Path

MARKER = "PlanetPort"

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_AZAHAR = ROOT / "third_party" / "azahar"
APPLE_UTILS_IOS = ROOT / "core-bridge" / "ios" / "apple_utils_ios.mm"

COMMON_CMAKE_OLD = """if (APPLE AND NOT ENABLE_LIBRETRO)
  target_sources(citra_common PUBLIC
    apple_authorization.h
    apple_authorization.cpp
    apple_utils.cpp
    apple_utils.h
    apple_utils.mm
  )
endif()
"""

COMMON_CMAKE_NEW = """if (APPLE AND NOT ENABLE_LIBRETRO)
  target_sources(citra_common PUBLIC
    apple_authorization.h
    apple_authorization.cpp
    apple_utils.cpp
    apple_utils.h
  )
  # PlanetPort: apple_utils.mm needs Cocoa; iOS uses a UIKit implementation.
  if (IOS)
    target_sources(citra_common PUBLIC apple_utils_ios.mm)
  else()
    target_sources(citra_common PUBLIC apple_utils.mm)
  endif()
endif()
"""

VK_INCLUDE_OLD = """#include "core/frontend/emu_window.h"
#include "video_core/renderer_vulkan/vk_platform.h"
"""

VK_INCLUDE_NEW = """#include "core/frontend/emu_window.h"
#include "video_core/renderer_vulkan/vk_platform.h"

#if defined(__APPLE__) // PlanetPort
#include <TargetConditionals.h>
#include <dlfcn.h>
#endif
"""

VK_LIBRARY_OLD = """#ifdef ANDROID
    // Android may override the Vulkan driver from the frontend.
    if (auto library = context->GetDriverLibrary(); library) {
        return library;
    }
#endif
"""

VK_LIBRARY_NEW = """#ifdef ANDROID
    // Android may override the Vulkan driver from the frontend.
    if (auto library = context->GetDriverLibrary(); library) {
        return library;
    }
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
    // PlanetPort: MoltenVK is linked statically on iOS, so there is no dylib to dlopen. The
    // frontend returns a handle to the image that contains it; otherwise use the main program
    // handle (dlsym on it also searches the libraries it depends on).
    if (context) {
        if (auto library = context->GetDriverLibrary(); library && library->IsLoaded()) {
            return library;
        }
    }
    return std::make_shared<Common::DynamicLibrary>(dlopen(nullptr, RTLD_NOW));
#endif
"""

SRC_CMAKE_OLD = """if (ENABLE_WEB_SERVICE)
    add_subdirectory(web_service)
endif()
"""

SRC_CMAKE_NEW = """if (ENABLE_WEB_SERVICE)
    add_subdirectory(web_service)
endif()

# PlanetPort: build the iOS bridge framework inside azahar's directory scope.
if (PLANETPORT_BRIDGE_DIR)
    add_subdirectory(${PLANETPORT_BRIDGE_DIR} ${CMAKE_BINARY_DIR}/planetport_bridge)
endif()
"""

PATCHES = [
    ("src/common/CMakeLists.txt", [(COMMON_CMAKE_OLD, COMMON_CMAKE_NEW)]),
    (
        "src/video_core/renderer_vulkan/vk_platform.cpp",
        [(VK_INCLUDE_OLD, VK_INCLUDE_NEW), (VK_LIBRARY_OLD, VK_LIBRARY_NEW)],
    ),
    ("src/CMakeLists.txt", [(SRC_CMAKE_OLD, SRC_CMAKE_NEW)]),
]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def patch_file(azahar: Path, relative: str, replacements) -> str:
    path = azahar / relative
    if not path.is_file():
        fail(f"{relative} not found (is {azahar} an azahar checkout?)")
    # newline="" keeps the original line endings so CRLF checkouts are detected and preserved.
    # (Path.write_text(newline=...) needs Python 3.10; Xcode's python3 is 3.9.)
    with path.open("r", encoding="utf-8", newline="") as handle:
        text = handle.read()
    if MARKER in text:
        return "already patched"
    crlf = "\r\n" in text
    if crlf:
        text = text.replace("\r\n", "\n")
    for old, new in replacements:
        count = text.count(old)
        if count != 1:
            fail(
                f"{relative}: anchor found {count} times (expected exactly 1). "
                "The azahar checkout does not match the pinned commit."
            )
        text = text.replace(old, new)
    if crlf:
        text = text.replace("\n", "\r\n")
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    return "patched"


def main() -> None:
    azahar = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_AZAHAR
    if not (azahar / "CMakeLists.txt").is_file():
        fail(f"{azahar} is not an azahar checkout (run scripts/fetch_azahar.sh first)")
    if not APPLE_UTILS_IOS.is_file():
        fail(f"missing {APPLE_UTILS_IOS}")

    for relative, replacements in PATCHES:
        status = patch_file(azahar, relative, replacements)
        print(f"  {relative}: {status}")

    destination = azahar / "src" / "common" / "apple_utils_ios.mm"
    shutil.copyfile(APPLE_UTILS_IOS, destination)
    print(f"  src/common/apple_utils_ios.mm: copied")
    print("azahar patched for iOS.")


if __name__ == "__main__":
    main()
