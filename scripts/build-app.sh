#!/bin/sh
# Build a runnable Lumen.app bundle from the SPM executable (dev convenience;
# the signed ship-to-self release process arrives with Phase 1's exit — docs/16).
#
# Usage:  scripts/build-app.sh          -> dist/Lumen.app (release build)
#         open dist/Lumen.app

set -eu

cd "$(dirname "$0")/.."

echo "Building LumenApp (release)…"
swift build -c release --product LumenApp

BIN=".build/release/LumenApp"
APP="dist/Lumen.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/Lumen"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Lumen</string>
    <key>CFBundleDisplayName</key>     <string>Lumen</string>
    <key>CFBundleIdentifier</key>      <string>dev.lumenapp.lumen</string>
    <key>CFBundleExecutable</key>      <string>Lumen</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.photography</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper allows a locally built bundle to launch.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
echo "Launch with:  open $APP"
