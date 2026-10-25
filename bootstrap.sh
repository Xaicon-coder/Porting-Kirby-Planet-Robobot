#!/usr/bin/env bash
# PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
# Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
#
# One command from a fresh checkout to an Xcode project:
#   fetch azahar -> patch -> build PlanetCore.framework -> xcodegen.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

missing=()
for tool in xcodebuild cmake ninja git python3 xcodegen rsync; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing tools: ${missing[*]}" >&2
    echo "Install them with:  brew install cmake ninja xcodegen git python" >&2
    echo "and Xcode from the App Store (then: sudo xcode-select -s /Applications/Xcode.app)." >&2
    exit 1
fi

chmod +x "$ROOT/scripts/"*.sh 2>/dev/null || true

bash "$ROOT/scripts/build_core.sh" "$@"

echo "==> Generating App/PlanetPort.xcodeproj"
(cd "$ROOT/App" && xcodegen generate)

cat <<EOF

PlanetPort is ready.
  1. open "$ROOT/App/PlanetPort.xcodeproj"
  2. Target PlanetPort > Signing & Capabilities: choose your Team
     (change the bundle id org.planetport.app if Xcode says it is taken).
  3. Connect your iPhone/iPad, select it and press Run.
  4. In the app: Importa your decrypted Kirby: Planet Robobot dump.
EOF
