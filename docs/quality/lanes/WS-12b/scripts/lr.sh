#!/bin/bash
# usage: lr.sh <render|sweep> <input.lfi> [args...]  -- adds as-shot flags from the sidecar
cmd=$1; in=$2; shift 2
j="${in%.lfi}.json"
read K T I < <(python3 -c "import json;h=json.load(open('$j'))['recipe_hint'];print(h['asShotKelvin'],h['asShotTint'],int(h.get('captureISO') or 0))")
iso=""; [ "$I" != "0" ] && iso="--iso $I"
exec /home/user/lumen/.build/x86_64-unknown-linux-gnu/release/lumen-render $cmd --input "$in" --as-shot-kelvin $K --as-shot-tint $T $iso "$@"
