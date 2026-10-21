#!/bin/bash
# run.sh <img-id> <outpng> [extra lumen-render args...]
# img-id: synthetic name (e.g. zone_plate) or corpus id (e.g. 6929_sony-ilce-7m4)
BIN=/home/user/lumen/.build/x86_64-unknown-linux-gnu/release/lumen-render
id=$1; out=$2; shift 2
if [ -f /home/user/lumen/corpus/synthetic/$id.lfi ]; then
  in=/home/user/lumen/corpus/synthetic/$id.lfi; flags=""
else
  in=/home/user/lumen/corpus/lfi/$id.lfi
  flags=$(python3 -c "import json;h=json.load(open('/home/user/lumen/corpus/lfi/$id.json'))['recipe_hint'];print('--as-shot-kelvin',h['asShotKelvin'],'--as-shot-tint',h['asShotTint'],'--iso',int(h['captureISO']))")
fi
[ -f "$out" ] && exit 0
$BIN render --input $in $flags --no-dither "$@" --out "$out" > "$out.log" 2>&1 || { echo "FAIL $out"; cat "$out.log"; }
