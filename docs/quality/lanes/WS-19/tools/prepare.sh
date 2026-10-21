#!/usr/bin/env bash
# Builds every input measure.py reads, under corpus/ws19/ (git-ignored with corpus/).
# Needs: scripts/proof/cloud-setup.sh, scripts/proof/fetch_corpus.sh already run; scipy.
# About 15 minutes, mostly LibRaw decodes at native resolution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
HERE="$ROOT/docs/quality/lanes/WS-19/tools"
OUT="$ROOT/corpus/ws19"; RAW="$ROOT/corpus/raw"
mkdir -p "$OUT/native" "$OUT/crops" "$OUT/sim"
python3 -c "import scipy" 2>/dev/null || pip install -q scipy
# 1. native decodes of the eight high-ISO frames (profile check) and the five spec frames
for f in 2348_panasonic-dc-g9.rw2 2062_canon-eos-kiss-x9.cr2 2242_panasonic-dc-gx850.rw2 \
         1192_fujifilm-x-t10.raf 4144_sony-ilce-7c.arw 1332_canon-eos-77d.cr2 \
         832_nikon-d7200.nef 6933_sony-ilce-7m4.arw; do
  b="${f%.*}"
  [ -f "$OUT/native/$b.lfi" ] || python3 "$ROOT/scripts/proof/decode_raw.py" "$RAW/$f" "$OUT/native/$b.lfi" --long-edge 0 &
done
wait
# 2. 640 px crops of the five spec frames
python3 "$HERE/measure.py" crops
# 3. ground-truth sims (clean + mosaic-noise twin) and the hot-pixel sim
cd "$HERE"
[ -f "$OUT/sim/6929_noisy.lfi" ] || python3 sim.py "$RAW/6929_sony-ilce-7m4.arw" "$OUT/sim/6929" 7e-4 4e-6 &
[ -f "$OUT/sim/4694_noisy.lfi" ] || python3 sim.py "$RAW/4694_canon-eos-r5.cr3" "$OUT/sim/4694" 7e-4 4e-6 &
[ -f "$OUT/sim/2545_noisy.lfi" ] || python3 sim.py "$RAW/2545_panasonic-dmc-gx85.rw2" "$OUT/sim/2545" 7e-4 4e-6 &
[ -f "$OUT/sim/hot_spec.lfi" ] || python3 simhot.py "$RAW/4694_canon-eos-r5.cr3" "$OUT/sim/hot" &
wait
[ -f "$OUT/sim/hot_star07.lfi" ] || { python3 simhot.py "$RAW/4694_canon-eos-r5.cr3" "$OUT/sim/hot07" "[0.7,1.0,1.4]" "['star']" && mv "$OUT/sim/hot07_star.lfi" "$OUT/sim/hot_star07.lfi"; }
swift build -c release --package-path "$HERE/nrtool"
echo "prepare: done -> $OUT"
