#!/bin/bash
# render.sh <photo-stem> <recipe.json|-> <out.png> [long-edge]
cd "$(dirname "$0")/../../../../.."
BIN=$(swift build -c release --show-bin-path)/lumen-render
read K T I < <(python3 -c "import json;h=json.load(open('corpus/lfi/$1.json'))['recipe_hint'];print(h['asShotKelvin'],h['asShotTint'],int(h.get('captureISO',100)))")
R=(); [ "$2" != "-" ] && R=(--recipe "$2")
$BIN render --input corpus/lfi/$1.lfi "${R[@]}" --as-shot-kelvin $K --as-shot-tint $T --iso $I --long-edge ${4:-512} --out "$3" >/dev/null
