#!/bin/bash
# Identity and continuity at 0.
# usage: identity.sh INPUT.lfi OUTDIR LONGEDGE      (env BIN as in render_set.sh)
# Renders: unset; texture=0 & clarity=0; texture=0 & clarity=0 with dehaze=10 (decomposition built);
# texture=+-1; clarity=+-1. Prints IDENTITY byte-identical yes/no for the two zero renders vs unset,
# and the max / mean |code| change of the +-1 renders.
set -e
BIN=${BIN:-$(swift build -c release --show-bin-path)/lumen-render}
IN=$1; OUT=$2; LE=$3; mkdir -p "$OUT"
R="$BIN render --input $IN --long-edge $LE --no-dither"
$R --out $OUT/unset.png > /dev/null
$R --set develop.detail.texture=0 --set develop.detail.clarity=0 --out $OUT/zero.png > /dev/null
$R --set develop.detail.dehaze=10 --out $OUT/dh.png > /dev/null
$R --set develop.detail.dehaze=10 --set develop.detail.texture=0 --set develop.detail.clarity=0 --out $OUT/dh_zero.png > /dev/null
for k in texture clarity; do for v in -1 1; do $R --set develop.detail.$k=$v --out $OUT/${k}_$v.png > /dev/null; done; done
cmp -s $OUT/unset.png $OUT/zero.png && echo "IDENTITY zero==unset: byte-identical yes" || echo "IDENTITY zero==unset: byte-identical NO"
cmp -s $OUT/dh.png $OUT/dh_zero.png && echo "IDENTITY (dehaze on) zero==unset: byte-identical yes" || echo "IDENTITY (dehaze on) zero==unset: byte-identical NO"
python3 - "$OUT" <<'PY'
import sys, numpy as np
from PIL import Image
d = sys.argv[1]
a = np.asarray(Image.open(f"{d}/unset.png").convert("RGB")).astype(int)
for k in ("texture", "clarity"):
    for v in ("-1", "1"):
        b = np.asarray(Image.open(f"{d}/{k}_{v}.png").convert("RGB")).astype(int)
        dl = np.abs(b - a)
        print(f"CONTINUITY {k}={v:>2}: max {dl.max()} codes  mean {dl.mean():.3f}")
PY
