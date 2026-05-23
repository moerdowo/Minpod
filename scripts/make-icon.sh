#!/usr/bin/env bash
# Generate the README cover and the macOS app icon (with rounded corners) from a
# source image.  usage: scripts/make-icon.sh <source-image>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: make-icon.sh <source-image>}"

swift "$ROOT/scripts/round-icon.swift" "$SRC" "$ROOT"
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ROOT/build/Minpod.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns and assets/cover.png"
