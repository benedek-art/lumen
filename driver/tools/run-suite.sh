#!/bin/bash
# Build the app once, run driver scenarios against it, collect the results.
#
#   driver/tools/run-suite.sh [scenario.json | glob-under-driver/scenarios]...
#
# Environment: CONFIG=release|debug (release) · OUT=dir (driver-out) ·
# PHASE=build|run|all · APP_CACHE=dir holding or receiving the built binary ·
# STRICT=1 fails the run on a failed expectation, not only on a driver error ·
# RAW_DIR=dir of real RAW files for scenarios with "fixture": "raw".
# macOS only. See driver/README.md.

set -u
cd "$(dirname "$0")/../.."
ROOT=$PWD
CONFIG=${CONFIG:-release}
OUT=${OUT:-$ROOT/driver-out}
WORK=${RUNNER_TEMP:-/tmp}/lumen-driver-work
APP=$WORK/LumenDriver.app
mkdir -p "$OUT" "$WORK"

PHASE=${PHASE:-all}   # build: only build · run: only run · all

# --- scenarios -----------------------------------------------------------------------
scenarios=()
for arg in "$@"; do
  if [ -f "$arg" ]; then
    scenarios+=("$arg")
  else
    for match in driver/scenarios/$arg; do
      [ -f "$match" ] && scenarios+=("$match")
    done
  fi
done
if [ ${#scenarios[@]} -eq 0 ] && [ "$PHASE" != "build" ]; then
  echo "no scenarios matched: $*" >&2
  exit 2
fi

# --- build ---------------------------------------------------------------------------
# APP_CACHE: a directory holding a previously built binary for exactly these sources
# (the workflow keys it by a hash of them). A hit skips the build.
BIN=.build/$CONFIG/LumenApp
if [ -n "${APP_CACHE:-}" ] && [ -x "$APP_CACHE/LumenApp-$CONFIG" ]; then
  BIN=$APP_CACHE/LumenApp-$CONFIG
  echo "using the cached build $BIN"
elif [ -z "${SKIP_BUILD:-}" ]; then
  echo "::group::swift build -c $CONFIG"
  build_started=$(date +%s)
  if ! swift build -c "$CONFIG" --product LumenApp > "$OUT/build.log" 2>&1; then
    grep -E "error:" "$OUT/build.log" | sed "s#$ROOT/##" | sort -u | head -80
    echo "::endgroup::"
    echo "build failed" >&2
    exit 2
  fi
  grep -E "warning:.*Driver/" "$OUT/build.log" | sed "s#$ROOT/##" | sort -u | head -40
  echo "built in $(( $(date +%s) - build_started ))s"
  echo "::endgroup::"
  if [ -n "${APP_CACHE:-}" ]; then
    mkdir -p "$APP_CACHE"
    cp "$BIN" "$APP_CACHE/LumenApp-$CONFIG"
  fi
fi

if [ "$PHASE" = "build" ]; then
  exit 0
fi

# A bundle of its own, with its own identifier: preferences written during a run go to
# dev.lumenapp.lumen.driver, never to the real app's domain.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Lumen"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lumen</string>
  <key>CFBundleIdentifier</key><string>dev.lumenapp.lumen.driver</string>
  <key>CFBundleExecutable</key><string>Lumen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LumenBuildCommit</key><string>$(git rev-parse HEAD 2>/dev/null || echo unknown)</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" || { echo "codesign failed" >&2; exit 2; }
defaults delete dev.lumenapp.lumen.driver > /dev/null 2>&1
# On a CI runner, keep the Dock from covering the bottom of the window.
if [ -n "${CI:-}" ]; then
  defaults write com.apple.dock autohide -bool true && killall Dock > /dev/null 2>&1
  sleep 2
fi

# --- fixtures ------------------------------------------------------------------------
FIXTURES=$WORK/fixtures
mkdir -p "$FIXTURES/fiducial"
python3 driver/tools/make_fiducial.py "$FIXTURES/fiducial" || exit 2
mv "$FIXTURES/fiducial/fiducial.json" "$OUT/fiducial.json"
if [ -n "${RAW_DIR:-}" ] && grep -lsE '"fixture"[[:space:]]*:[[:space:]]*"raw"' "${scenarios[@]}" > /dev/null; then
  driver/tools/fetch-raw.sh "$RAW_DIR" || echo "RAW fixtures incomplete" >&2
  ln -sfn "$RAW_DIR" "$FIXTURES/raw"
fi

# --- run -----------------------------------------------------------------------------
infra=0
failed=0
for scenario in "${scenarios[@]}"; do
  name=$(basename "$scenario" .json)
  out=$OUT/$name
  rm -rf "$out"
  mkdir -p "$out"
  cp "$scenario" "$out/scenario.json"
  fixture=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("fixture","fiducial"))' "$scenario" 2>/dev/null)
  limit=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("timeoutSeconds",300))+90)' "$scenario" 2>/dev/null)
  [ -n "$limit" ] || limit=390

  # Each scenario edits its own copy of the photos, so no run sees another's sidecars.
  photos=$WORK/photos-$name
  rm -rf "$photos"
  mkdir -p "$photos"
  if [ -d "$FIXTURES/$fixture" ]; then
    cp -cR "$FIXTURES/$fixture/." "$photos/" 2>/dev/null || cp -RL "$FIXTURES/$fixture/." "$photos/"
  else
    echo "$name: fixture '$fixture' is not available" | tee "$out/app.log"
    echo 2 > "$out/exit.txt"
    infra=1
    continue
  fi

  # Every scenario starts from the app's defaults, not from what the last one saved.
  defaults delete dev.lumenapp.lumen.driver > /dev/null 2>&1 || true

  echo "::group::$name"
  started=$(date +%s)
  touch "$out/.started"
  LUMEN_DRIVER=$out/scenario.json LUMEN_DRIVER_OUT=$out LUMEN_DRIVER_PHOTOS=$photos \
    "$APP/Contents/MacOS/Lumen" > "$out/app.log" 2>&1 &
  pid=$!
  # The app's own watchdog should end a stuck run; this is the backstop for a process
  # too far gone to run it.
  status=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ $(( $(date +%s) - started )) -gt "$limit" ]; then
      echo "outer timeout after ${limit}s — sampling and killing"
      sample "$pid" 2 -file "$out/outer-timeout-sample.txt" > /dev/null 2>&1
      kill -9 "$pid" 2>/dev/null
      status=124
      break
    fi
    sleep 1
  done
  if [ -z "$status" ]; then
    wait "$pid"
    status=$?
  fi
  echo "$status" > "$out/exit.txt"
  echo "exit $status after $(( $(date +%s) - started ))s"
  if [ "$status" -ge 128 ] || [ "$status" -eq 124 ]; then
    sleep 3
    find "$HOME/Library/Logs/DiagnosticReports" -name 'Lumen*' -newer "$out/.started" \
      -exec cp {} "$out/" \; 2>/dev/null
  fi
  tail -5 "$out/app.log"
  rm -rf "$photos"

  if [ -f "$out/report.json" ] && [ -f driver/tools/witness.py ]; then
    python3 driver/tools/witness.py "$out" --map "$OUT/fiducial.json" > "$out/witness.log" 2>&1 \
      || tail -5 "$out/witness.log"
  fi
  echo "::endgroup::"

  case "$status" in
    0) ;;
    1) failed=1 ;;
    *) infra=1 ;;
  esac
done

python3 driver/tools/summarize.py "$OUT" | tee "$OUT/summary.txt"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$OUT/summary.md" ]; then
  cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi

[ "$infra" -eq 0 ] || exit 2
if [ -n "${STRICT:-}" ] && [ "$STRICT" != "0" ] && [ "$STRICT" != "false" ]; then
  # The witness can fail a scenario the app itself passed.
  python3 -c 'import json,sys; sys.exit(0 if all(r["verdict"]=="PASS" for r in json.load(open(sys.argv[1]))) else 1)' "$OUT/summary.json" || failed=1
  [ "$failed" -eq 0 ] || exit 1
fi
exit 0
