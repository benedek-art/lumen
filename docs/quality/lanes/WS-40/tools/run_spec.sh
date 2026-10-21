#!/bin/bash
# WS-40 grain acceptance spec: render + measure every machine-checkable SPEC.md line.
# Usage: bash docs/quality/lanes/WS-40/tools/run_spec.sh [run_spec.py options]
#   e.g. bash docs/quality/lanes/WS-40/tools/run_spec.sh --out /tmp/ws40-after \
#          --sheets docs/quality/lanes/WS-40/evidence --before-renders /tmp/ws40-before/r
# Builds the release lumen-render first (no-op when up to date).
set -euo pipefail
export PATH=/opt/swift/usr/bin:$PATH
ROOT=$(cd "$(dirname "$0")/../../../../.." && pwd)
cd "$ROOT"
swift build -c release --product lumen-render >/dev/null
BIN=$(swift build -c release --show-bin-path)/lumen-render
exec python3 "$ROOT/docs/quality/lanes/WS-40/tools/run_spec.py" --bin "$BIN" "$@"
