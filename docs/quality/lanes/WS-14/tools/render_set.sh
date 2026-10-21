#!/bin/bash
# Render the identity and Texture/Clarity at a list of values, no dither.
# usage: render_set.sh INPUT.lfi OUTDIR PREFIX LONGEDGE
#   env: BIN   path to lumen-render (default: $(swift build -c release --show-bin-path)/lumen-render)
#        VALS  values (default "-100 -50 -25 25 50 100")
#        KEYS  controls (default "texture clarity")
#        PAR   parallel jobs (default 4)
#        EXTRA extra lumen-render args (e.g. "--set develop.tone.contrast=20")
# writes OUTDIR/PREFIX_id.png and OUTDIR/PREFIX_{t,c}<value>.png (+ .json metrics)
set -e
BIN=${BIN:-$(swift build -c release --show-bin-path)/lumen-render}
IN=$1; OUT=$2; P=$3; LE=$4
VALS=${VALS:--100 -50 -25 25 50 100}; KEYS=${KEYS:-texture clarity}
mkdir -p "$OUT"
{
echo "$BIN render --input $IN --long-edge $LE --no-dither $EXTRA --out $OUT/${P}_id.png --metrics $OUT/${P}_id.json"
for k in $KEYS; do for v in $VALS; do
echo "$BIN render --input $IN --long-edge $LE --no-dither $EXTRA --set develop.detail.$k=$v --out $OUT/${P}_${k:0:1}${v}.png --metrics $OUT/${P}_${k:0:1}${v}.json"
done; done
} | xargs -P ${PAR:-4} -I{} sh -c "{} > /dev/null"
