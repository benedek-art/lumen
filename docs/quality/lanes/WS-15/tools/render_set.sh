#!/usr/bin/env bash
# Render one frame at fixed dehaze values and long edges, as-shot WB from the sidecar.
# Usage: render_set.sh LFI OUTDIR LONG_EDGE "v1 v2 ..." [extra lumen-render args]
# Output: OUTDIR/<id>_L<edge>_d<value>.png (undithered)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../../../.." && pwd)
BIN=${BIN:-$ROOT/.build/x86_64-unknown-linux-gnu/release/lumen-render}
LFI=$1; OUT=$2; LE=$3; VALS=$4; shift 4
id=$(basename "$LFI" .lfi); id=${id%%_*}; mkdir -p "$OUT"
read K Tn < <(python3 -c "import json,sys;h=json.load(open(sys.argv[1])).get('recipe_hint',{});print(h.get('asShotKelvin',5500),h.get('asShotTint',0))" "${LFI%.lfi}.json")
for v in $VALS; do
  "$BIN" render --input "$LFI" --set develop.detail.dehaze=$v --long-edge $LE --no-dither \
     --as-shot-kelvin $K --as-shot-tint $Tn --out "$OUT/${id}_L${LE}_d${v}.png" "$@" >/dev/null &
done; wait
