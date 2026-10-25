#!/usr/bin/env bash
# PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
# Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
#
# Clones azahar at the pinned commit (with every submodule) into third_party/azahar.
# Idempotent. Use --force to discard local changes in an existing checkout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AZAHAR_DIR="$ROOT/third_party/azahar"
AZAHAR_REPO="https://github.com/azahar-emu/azahar.git"
AZAHAR_COMMIT="12bde376ce8fc2012af61ea791f94172a82e67e0"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            echo "Usage: $0 [--force]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "error: git not found (xcode-select --install)" >&2; exit 1; }

mkdir -p "$ROOT/third_party"

if [[ ! -d "$AZAHAR_DIR/.git" ]]; then
    echo "==> Cloning azahar @ ${AZAHAR_COMMIT:0:8}"
    git init -q "$AZAHAR_DIR"
    git -C "$AZAHAR_DIR" remote add origin "$AZAHAR_REPO"
    if ! git -C "$AZAHAR_DIR" fetch --depth 1 origin "$AZAHAR_COMMIT"; then
        echo "==> Shallow fetch by commit refused, fetching full history"
        git -C "$AZAHAR_DIR" fetch origin
    fi
    git -C "$AZAHAR_DIR" checkout -q --detach "$AZAHAR_COMMIT"
else
    # Empty when a previous first fetch failed (repository without HEAD).
    current="$(git -C "$AZAHAR_DIR" rev-parse -q --verify HEAD || true)"
    if [[ "$current" != "$AZAHAR_COMMIT" ]]; then
        if [[ -n "$current" && $FORCE -eq 0 ]]; then
            # Our own patches are expected local changes: revert them before moving.
            git -C "$AZAHAR_DIR" checkout -q -- src/CMakeLists.txt src/common/CMakeLists.txt \
                src/video_core/renderer_vulkan/vk_platform.cpp 2>/dev/null || true
        fi
        if [[ -n "$(git -C "$AZAHAR_DIR" status --porcelain --untracked-files=no)" && $FORCE -eq 0 ]]; then
            echo "error: $AZAHAR_DIR has local changes and is not at the pinned commit." >&2
            echo "       Re-run with --force to reset it." >&2
            exit 1
        fi
        echo "==> Moving azahar to ${AZAHAR_COMMIT:0:8}"
        git -C "$AZAHAR_DIR" fetch --depth 1 origin "$AZAHAR_COMMIT" || git -C "$AZAHAR_DIR" fetch origin
        git -C "$AZAHAR_DIR" checkout -q --force --detach "$AZAHAR_COMMIT"
    elif [[ $FORCE -eq 1 ]]; then
        echo "==> Resetting local changes (--force)"
        git -C "$AZAHAR_DIR" reset -q --hard "$AZAHAR_COMMIT"
    else
        echo "==> azahar already at ${AZAHAR_COMMIT:0:8}"
    fi
fi

echo "==> Updating submodules (this downloads a few hundred MB the first time)"
git -C "$AZAHAR_DIR" submodule sync --recursive >/dev/null
if ! git -C "$AZAHAR_DIR" submodule update --init --recursive --depth 1 --jobs 8; then
    echo "==> Shallow submodule update failed, retrying with full history"
    git -C "$AZAHAR_DIR" submodule update --init --recursive --jobs 8
fi
if [[ $FORCE -eq 1 ]]; then
    git -C "$AZAHAR_DIR" submodule foreach --recursive --quiet 'git reset -q --hard'
fi

echo "==> azahar ready in $AZAHAR_DIR"
