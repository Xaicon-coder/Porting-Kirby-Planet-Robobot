#!/usr/bin/env bash
# PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
# Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
#
# Builds build/PlanetCore.framework (azahar core + Objective-C++ bridge) for iPhoneOS arm64.
#
#   bash scripts/build_core.sh [--no-fetch] [--clean] [--force]
#   BUILD_TYPE=Debug bash scripts/build_core.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AZAHAR_DIR="$ROOT/third_party/azahar"
BUILD_DIR="$ROOT/build/core"
OUTPUT_FRAMEWORK="$ROOT/build/PlanetCore.framework"
BUILD_TYPE="${BUILD_TYPE:-Release}"

NO_FETCH=0
CLEAN=0
FETCH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-fetch) NO_FETCH=1 ;;
        --clean) CLEAN=1 ;;
        --force) FETCH_ARGS+=("--force") ;;
        -h|--help)
            echo "Usage: $0 [--no-fetch] [--clean] [--force]   (env: BUILD_TYPE=Release|Debug)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "iOS builds require macOS with Xcode."
command -v xcrun >/dev/null 2>&1 || die "Xcode command line tools not found (xcode-select --install)."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "iPhoneOS SDK not found: install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app'."
command -v cmake >/dev/null 2>&1 || die "cmake not found (brew install cmake)."
command -v ninja >/dev/null 2>&1 || die "ninja not found (brew install ninja)."
command -v python3 >/dev/null 2>&1 || die "python3 not found (brew install python)."

cmake_version="$(cmake --version | head -n1 | awk '{print $3}')"
if [[ "$(printf '%s\n%s\n' "3.25.0" "$cmake_version" | sort -V | head -n1)" != "3.25.0" ]]; then
    die "cmake >= 3.25 required (found $cmake_version): brew upgrade cmake"
fi

if [[ $NO_FETCH -eq 0 ]]; then
    # Through bash: the execute bit may be missing when the project was copied as a zip.
    bash "$ROOT/scripts/fetch_azahar.sh" ${FETCH_ARGS[@]+"${FETCH_ARGS[@]}"}
fi
[[ -f "$AZAHAR_DIR/CMakeLists.txt" ]] || die "azahar sources missing: run scripts/fetch_azahar.sh"

echo "==> Applying iOS patches"
python3 "$ROOT/scripts/patch_azahar.py" "$AZAHAR_DIR"

if [[ $CLEAN -eq 1 ]]; then
    echo "==> Cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

echo "==> Configuring ($BUILD_TYPE, iphoneos arm64)"
cmake -S "$AZAHAR_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DENABLE_QT=OFF \
    -DENABLE_QT_TRANSLATION=OFF \
    -DENABLE_SDL2=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_ROOM=OFF \
    -DENABLE_WEB_SERVICE=OFF \
    -DENABLE_SCRIPTING=OFF \
    -DENABLE_GDBSTUB=OFF \
    -DENABLE_CUBEB=OFF \
    -DENABLE_LIBUSB=OFF \
    -DENABLE_OPENAL=ON \
    -DENABLE_VULKAN=ON \
    -DENABLE_OPENGL=OFF \
    -DENABLE_SOFTWARE_RENDERER=ON \
    -DENABLE_LIBRETRO=OFF \
    -DENABLE_BUILTIN_KEYBLOB=OFF \
    -DENABLE_LTO=OFF \
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
    -DCITRA_WARNINGS_AS_ERRORS=OFF \
    -DENABLE_OPT=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DPLANETPORT_BRIDGE_DIR="$ROOT/core-bridge"

echo "==> Building PlanetCore (the first build takes a while)"
cmake --build "$BUILD_DIR" --target PlanetCore

BUILT_FRAMEWORK="$BUILD_DIR/planetport_bridge/PlanetCore.framework"
if [[ ! -d "$BUILT_FRAMEWORK" ]]; then
    BUILT_FRAMEWORK="$(find "$BUILD_DIR" -maxdepth 4 -type d -name PlanetCore.framework | head -n1)"
fi
[[ -n "$BUILT_FRAMEWORK" && -d "$BUILT_FRAMEWORK" ]] || die "PlanetCore.framework not found in $BUILD_DIR"

mkdir -p "$OUTPUT_FRAMEWORK"
rsync -a --delete "$BUILT_FRAMEWORK/" "$OUTPUT_FRAMEWORK/"

echo
echo "==> Done: $OUTPUT_FRAMEWORK"
echo "    Next: (cd App && xcodegen generate) and open App/PlanetPort.xcodeproj"
