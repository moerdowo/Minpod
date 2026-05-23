#!/usr/bin/env bash
# Build Minpod.app and package it into a (non-notarized) drag-to-install .dmg.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/bundle.sh" release

APP="$ROOT/build/Minpod.app"
STAGING="$ROOT/build/dmg-staging"
DMG="$ROOT/build/Minpod.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Minpod.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Minpod" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
