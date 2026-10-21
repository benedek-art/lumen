#!/usr/bin/env bash
# Render WS-15 dehaze sweeps. Usage: run_sweeps.sh OUTDIR [BIN]
# Writes OUTDIR/<id>_sheet.png, <id>_m.json, <id>_tiles/ (1024 px, 7 values)
# and OUTDIR/<id>_fine_* (512 px, -100..100 step 10) for smoothness.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../../../.." && pwd)
OUT=${1:?outdir}; BIN=${2:-$ROOT/.build/x86_64-unknown-linux-gnu/release/lumen-render}
mkdir -p "$OUT"
FRAMES="983_canon-eos-5d-mark-iv 1840_nikon-d850 4213_nikon-z-7-2 3437_canon-eos-rebel-t7i 2545_panasonic-dmc-gx85 6929_sony-ilce-7m4"
SYN="hard_edge flat_grey colorchecker hue_wheel grey_ramp"
ws() { python3 -c "import json,sys;h=json.load(open(sys.argv[1])).get('recipe_hint',{});print(h.get('asShotKelvin',5500),h.get('asShotTint',0))" "$1"; }
one() { local lfi=$1 id=$2; read K Tn < <(ws "${lfi%.lfi}.json")
  "$BIN" sweep --input "$lfi" --key develop.detail.dehaze --values -100,-50,-25,0,25,50,100 \
    --long-edge 1024 --as-shot-kelvin "$K" --as-shot-tint "$Tn" --out "$OUT/${id}_sheet.png" \
    --metrics "$OUT/${id}_m.json" --tiles-dir "$OUT/${id}_tiles" >/dev/null
  "$BIN" sweep --input "$lfi" --key develop.detail.dehaze --values $(seq -s, -100 10 100) \
    --long-edge 512 --columns 7 --as-shot-kelvin "$K" --as-shot-tint "$Tn" --out "$OUT/${id}_fine_sheet.png" \
    --metrics "$OUT/${id}_fine_m.json" >/dev/null; echo "done $id"; }
for f in $FRAMES; do one "$ROOT/corpus/lfi/$f.lfi" "${f%%_*}" & done; wait
for s in $SYN; do one "$ROOT/corpus/synthetic/$s.lfi" "$s" & done; wait
