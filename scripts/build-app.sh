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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Lumen"

# THE ICON, compiled from the geometry in scripts/make-appicon.py.
#
# Until this existed the app shipped with no icon at all, so macOS drew the blank white
# document placeholder — which is what the owner was looking at in the Dock. The artwork
# is a slanted white field with an upright cross cut out of it, rendered to a full
# .iconset by that script and compiled here by `iconutil`, which is macOS's own tool and
# the only thing that produces a well-formed .icns.
#
# NOT ALLOWED TO FAIL QUIETLY, for the same reason the signature below is not: an app
# that builds "successfully" and comes out looking like an unsaved TextEdit document is a
# failure nobody reads a log to diagnose. If the iconset is missing, the build says so.
ICONSET="resources/Lumen.iconset"
if [ ! -d "$ICONSET" ]; then
    echo "$ICONSET is missing — run: python3 scripts/make-appicon.py" >&2
    exit 1
fi
if ! iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "iconutil failed on $ICONSET — the app would ship with no icon." >&2
    exit 1
fi

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

    <!-- The half of the icon that lives in the plist. `AppIcon.icns` is written into
         Contents/Resources above; without this key the file is present and ignored, and
         the Dock still draws the blank placeholder. Declaration and file are one change:
         either alone is inert, which is why `IconTests` asserts both. -->
    <key>CFBundleIconFile</key>        <string>AppIcon</string>

    <!-- WHAT THE SYSTEM MAY HAND US. Without this the bundle declared no document
         types at all, so "Open With ▸ Lumen" never appeared in Finder, a drop on the
         dock icon did nothing, and double-clicking a RAW could never reach Lumen —
         three doors that looked like they should work and silently did not.

         `public.camera-raw-image` is the parent every vendor RAW conforms to, so one
         line covers the Hasselblad and Phase One files `PhotoFormats.raw` was widened
         for; `public.image` covers the rendered half.

         RANK ALTERNATE, DELIBERATELY. A development build must not become the system
         handler for every JPEG on the machine the first time it is launched — this
         offers Lumen in the Open With list and leaves the default where the
         photographer put it. `LumenAppDelegate.application(_:open:)` is what receives
         the open; the declaration and that method are one change, and either alone is
         inert. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>    <string>Photograph</string>
            <key>CFBundleTypeRole</key>    <string>Editor</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.camera-raw-image</string>
                <string>public.image</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>    <string>Folder</string>
            <key>CFBundleTypeRole</key>    <string>Viewer</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
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

# On CI, the run number is the human-readable "version": the Lumen menu shows it
# (BuildStamp), and CFBundleVersion carries it so the standard About panel agrees.
# Local script builds have no number and show commit + date instead.
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :LumenBuildNumber integer ${GITHUB_RUN_NUMBER}" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER}" \
        "$APP/Contents/Info.plist"
fi

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
