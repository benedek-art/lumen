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

# Stamp the build's identity into the bundle BEFORE signing (the signature seals the
# plist). The in-app updater compares these against the rolling dev release; a build
# without them (someone hand-rolling the plist) simply never offers updates.
SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
NOW="$(date -u +%s)"
/usr/libexec/PlistBuddy -c "Add :LumenBuildCommit string ${SHA}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LumenBuildDate integer ${NOW}" "$APP/Contents/Info.plist"

# Ad-hoc signature. NOT optional and NOT allowed to fail quietly: on Apple Silicon an
# unsigned binary does not launch at all, so `|| true` here would hand back a bundle
# that cannot start, with the failure hidden and nothing to read. If signing breaks,
# that is the thing to fix — a build that says it succeeded and produces an app which
# refuses to open is worse than one that stops.
if ! codesign --force --sign - "$APP"; then
    echo "codesign failed — an unsigned bundle will not launch on Apple Silicon." >&2
    exit 1
fi

# Prove it: verification catches a signature that was written but is not valid, which
# presents to the user as the same "damaged" dialog as no signature at all.
if ! codesign --verify --deep --strict "$APP"; then
    echo "the signature did not verify — the bundle would be refused at launch." >&2
    exit 1
fi

echo "Built $APP"
echo "Launch with:  open $APP"
echo
echo "If this bundle travels through a download (CI artifact, AirDrop, zip from"
echo "another machine) macOS attaches a quarantine flag, and an ad-hoc signature"
echo "plus quarantine reports as \"Lumen is damaged\" — which right-click → Open"
echo "does NOT get past. Clear it with:"
echo "    xattr -dr com.apple.quarantine $APP"
