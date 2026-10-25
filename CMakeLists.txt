# PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
# Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
#
# PlanetCore.framework. This directory is NOT a standalone project: scripts/patch_azahar.py makes
# azahar's src/CMakeLists.txt call
#   add_subdirectory(${PLANETPORT_BRIDGE_DIR} ${CMAKE_BINARY_DIR}/planetport_bridge)
# so the target inherits azahar's include directories (src/), compile definitions
# (ENABLE_VULKAN, ...) and sees MOLTENVK_LIBRARY from azahar's top-level CMakeLists.txt.

if (NOT IOS)
    message(FATAL_ERROR "PlanetCore only supports iOS (configure with -DCMAKE_SYSTEM_NAME=iOS)")
endif()

if (NOT MOLTENVK_LIBRARY)
    message(FATAL_ERROR "MOLTENVK_LIBRARY is not set: azahar must be configured with "
                        "ENABLE_VULKAN=ON and ENABLE_LIBRETRO=OFF")
endif()

set(PLANETCORE_PUBLIC_HEADERS
    include/PlanetCore/PlanetCore.h
    include/PlanetCore/PPTypes.h
    include/PlanetCore/PPSettings.h
    include/PlanetCore/PPGameInfo.h
    include/PlanetCore/PPEmulator.h
    include/PlanetCore/PPMultiplayer.h
)

set(PLANETCORE_SOURCES
    src/PPApplets.mm
    src/PPCommon.mm
    src/PPEmulator.mm
    src/PPEmuWindow.h
    src/PPEmuWindow.mm
    src/PPGameInfo.mm
    src/PPInput.mm
    src/PPInternal.h
    src/PPJit.mm
    src/PPMultiplayer.mm
    src/PPSettings.mm
    src/PPSystem.mm
)

add_library(PlanetCore SHARED ${PLANETCORE_SOURCES} ${PLANETCORE_PUBLIC_HEADERS})

target_include_directories(PlanetCore PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_definitions(PlanetCore PRIVATE
    # Keep AssertMacros.h from defining check()/verify()/require() which clash with C++ code.
    __ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES=0
)

target_compile_options(PlanetCore PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

set_target_properties(PlanetCore PROPERTIES
    FRAMEWORK TRUE
    OUTPUT_NAME PlanetCore
    MACOSX_FRAMEWORK_IDENTIFIER org.planetport.PlanetCore
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0
    MACOSX_FRAMEWORK_BUNDLE_VERSION 1
    MACOSX_FRAMEWORK_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
    PUBLIC_HEADER "${PLANETCORE_PUBLIC_HEADERS}"
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED ON
    # Install name @rpath/PlanetCore.framework/PlanetCore so the app can embed it.
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
)

target_link_libraries(PlanetCore PRIVATE
    citra_common
    citra_core
    video_core
    audio_core
    input_common
    network
    # MoltenVK is a static archive; azahar never references Vulkan symbols directly
    # (VK_NO_PROTOTYPES), so load the whole archive.
    "-Wl,-force_load,${MOLTENVK_LIBRARY}"
    "-framework Foundation"
    "-framework CoreFoundation"
    "-framework UIKit"
    "-framework Metal"
    "-framework QuartzCore"
    "-framework IOSurface"
    "-framework CoreGraphics"
    "-framework AVFoundation"
    "-framework AudioToolbox"
    "-framework CoreAudio"
)

if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_link_options(PlanetCore PRIVATE "-Wl,-dead_strip")
endif()

# Swift imports the framework through its module map.
add_custom_command(TARGET PlanetCore POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:PlanetCore>/Modules"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/module.modulemap"
            "$<TARGET_BUNDLE_DIR:PlanetCore>/Modules/module.modulemap"
    COMMENT "Installing PlanetCore module map"
    VERBATIM
)
