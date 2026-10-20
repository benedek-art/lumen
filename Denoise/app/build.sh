#!/bin/bash
# Builds "Lumen Denoise.app" into app/dist/ (SwiftPM release build + hand-assembled bundle, ad-hoc signed),
# then runs the bundle's --selftest. See README.md for tests and the autotest smoke run.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="dist/Lumen Denoise.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LumenDenoise "$APP/Contents/MacOS/LumenDenoise"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lumen Denoise</string>
  <key>CFBundleDisplayName</key><string>Lumen Denoise</string>
  <key>CFBundleIdentifier</key><string>com.benedek.lumen-denoise</string>
  <key>CFBundleExecutable</key><string>LumenDenoise</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign -s - --force --deep "$APP"
# Smoke check of the built binary: output guard (Offload Drive, symlinks) + Core sanity checks. No UI, no side effects.
if ! LOG=$("$APP/Contents/MacOS/LumenDenoise" --selftest 2>&1); then
    echo "$LOG" | grep -v '^PASS' || true
    echo "selftest failed"; exit 1
fi
echo "Built: $PWD/$APP (selftest passed)"
