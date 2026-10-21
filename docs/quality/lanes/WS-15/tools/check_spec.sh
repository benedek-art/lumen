#!/usr/bin/env bash
# WS-15 Dehaze: render everything SPEC.md measures, then check every measurable line.
# Usage: tools/check_spec.sh [WORKDIR] [--no-render] [--swift] [--only IDS]
#   WORKDIR defaults to docs/quality/lanes/WS-15/spec-work/current
#   BIN=... overrides the renderer (default .build/x86_64-unknown-linux-gnu/release/lumen-render)
# ~3 min render (4 cores) + ~2 min measure; --swift adds `swift test --filter WS15`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$HERE/../spec-work/current
if [[ $# -gt 0 && $1 != --* ]]; then WORK=$1; shift; fi
RENDER=1; ARGS=()
for a in "$@"; do if [[ $a == --no-render ]]; then RENDER=0; else ARGS+=("$a"); fi; done
if [[ $RENDER == 1 ]]; then python3 "$HERE/spec_render.py" "$WORK"; fi
python3 "$HERE/check_spec.py" "$WORK" --json "$WORK/spec_results.json" "${ARGS[@]+"${ARGS[@]}"}"
