#!/usr/bin/env bash
# Build Minpod and assemble a native .app bundle (non-sandboxed so it can read
# and write the iPod's removable volume).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/build/Minpod.app"
CONTENTS="$APP/Contents"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Minpod"

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Minpod"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Minpod</string>
    <key>CFBundleDisplayName</key><string>Minpod</string>
    <key>CFBundleIdentifier</key><string>com.minpod.app</string>
    <key>CFBundleExecutable</key><string>Minpod</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle has a stable identity for TCC prompts.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Done: $APP"
