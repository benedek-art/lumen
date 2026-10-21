#!/usr/bin/env bash
# WS-06 visual claims V1-V3: render the contrast sweeps a human judges.
#
#   bash docs/quality/lanes/WS-06/measure/sheets.sh BIN OUTDIR [CORPUS]
#
# Writes, at long edge 1024 (full resolution, for judging at 100%):
#   OUTDIR/V1_6929/         tiles + sheet.png   Contrast -100,-50,0,+50,+100   (A7 IV)
#   OUTDIR/V2_1346/         tiles + sheet.png   Contrast -100,-50,0,+50,+100   (Passport, dark surround)
#   OUTDIR/V3_983_exp1.5/   tiles + sheet.png   Contrast -100,-50,0,+50,+100 at Exposure +1.5
#   OUTDIR/V4_2545/         tiles + sheet.png   Contrast -100,-50,0,+50,+100   (GX85)
# Render once with the base-commit binary (OUTDIR=.../before) and once with the change
# (OUTDIR=.../after), then build the committed evidence with compose.py.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
BIN="$1"; OUT="$2"; CORPUS="${3:-$REPO/corpus}"
VALUES=-100,-50,0,50,100
one() {  # name stem extra-args...
    local name="$1" stem="$2"; shift 2
    local lfi="$CORPUS/lfi/$stem.lfi"
    read -r K T I < <(python3 -I -c "import json,sys; h=json.load(open(sys.argv[1]))['recipe_hint']; print(h['asShotKelvin'], h['asShotTint'], h.get('captureISO') or 0)" "${lfi%.lfi}.json")
    local iso=(); [ "$I" != "0" ] && iso=(--iso "$I")
    mkdir -p "$OUT/$name"
    "$BIN" sweep --input "$lfi" --key develop.tone.contrast --values "$VALUES" --columns 5 \
        --long-edge 1024 --as-shot-kelvin "$K" --as-shot-tint "$T" "${iso[@]}" "$@" \
        --out "$OUT/$name/sheet.png" --metrics "$OUT/$name/sweep.json" --tiles-dir "$OUT/$name" > /dev/null
    echo "$OUT/$name/sheet.png"
}
one V1_6929 6929_sony-ilce-7m4
one V2_1346 1346_canon-eos-5d
one V3_983_exp1.5 983_canon-eos-5d-mark-iv --set develop.tone.exposure=1.5
one V4_2545 2545_panasonic-dmc-gx85
