#!/usr/bin/env bash
# run_ws07.sh OUTDIR [--full]
# Renders every WS-07 measurement at Highlights -100 / Shadows +100 with the current
# lumen-render build and prints one line per SPEC measurement. --full adds the 6929
# native-size (7008 px) vs 1600 px consistency check (~4 min, ~6 GB RAM; needs the native
# decode: decode_raw.py --long-edge 0 corpus/raw/6929_sony-ilce-7m4.arw corpus/ws07/6929_full.lfi).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"; cd "$REPO"
OUT=$1; FULL=${2:-}; mkdir -p "$OUT"
B=.build/release/lumen-render
M="python3 docs/quality/lanes/WS-07/measure_tone_spatial.py"
HDR="--set develop.tone.highlights=-100 --set develop.tone.shadows=100"
[ -f corpus/ws07/step_1.5.lfi ] || $M mksynth corpus/ws07 >/dev/null
PHOTOS="983_canon-eos-5d-mark-iv 1840_nikon-d850 4213_nikon-z-7-2 6929_sony-ilce-7m4 2545_panasonic-dmc-gx85 1569_panasonic-dmc-gx80"
hint() { python3 -c "import json;h=json.load(open('$1'))['recipe_hint'];print('--as-shot-kelvin',h['asShotKelvin'],'--as-shot-tint',h['asShotTint'],'--iso',int(h.get('captureISO') or 100))"; }
pair() { # name input longedge extra...
  local n=$1 in=$2 le=$3; shift 3
  $B render --input "$in" --long-edge $le --no-dither "$@" --out "$OUT/${n}_base.png" >/dev/null
  $B render --input "$in" --long-edge $le --no-dither "$@" $HDR --out "$OUT/${n}_hdr.png" >/dev/null
}
for d in 0.75 1.5 3.0 5.0; do pair step_$d corpus/ws07/step_$d.lfi 1600 & done
pair noise04 corpus/ws07/noise04.lfi 1600 &
pair hard_edge corpus/synthetic/hard_edge.lfi 1600 &
wait
for id in $PHOTOS; do pair ${id%%_*} corpus/lfi/$id.lfi 1600 $(hint corpus/lfi/$id.json) & done
wait
for d in 0.75 1.5 3.0 5.0; do
  $M step "$OUT/step_${d}_base.png" "$OUT/step_${d}_hdr.png" --json "$OUT/step_$d.json" >/dev/null
  python3 -c "import json;d=json.load(open('$OUT/step_$d.json'));print('S1 step $d EV  peak %+.3f EV  width %.1f px  reversals %d'%(d['peakEV'],d['widthPx'],d['reversals']))"
done
for sp in -2 2; do
  $M halo corpus/synthetic/hard_edge.lfi "$OUT/hard_edge_base.png" "$OUT/hard_edge_hdr.png" --split $sp --json "$OUT/he$sp.json" >/dev/null
  python3 -c "
import json;d=json.load(open('$OUT/he$sp.json'))
o=[abs(d[s]['overshootEV']) for s in ('bright','dark') if d[s]]
print('S2 hard_edge split $sp  overshoot %.3f EV  reversal %.5f'%(max(o),d['reversal']['fraction']))"
done
for id in $PHOTOS; do n=${id%%_*}
  $M halo corpus/lfi/$id.lfi "$OUT/${n}_base.png" "$OUT/${n}_hdr.png" --json "$OUT/m_$n.json" >/dev/null
  python3 -c "
import json;d=json.load(open('$OUT/m_$n.json'));b=d['bright']
print('S3/S4/S5 $n  bright halo %+.3f EV w=%d px  dark %s  reversal %.5f  detail s1.5 %.3f s12 %.3f'%(b['signedPeakEV'],b['widthPx'],('%+.3f'%d['dark']['signedPeakEV']) if d['dark'] else 'n/a',d['reversal']['fraction'],d['detail']['s1.5'],d['detail']['s12']))"
done
python3 -c "
import json
v=[json.load(open('$OUT/m_'+n+'.json'))['detail']['s1.5'] for n in '983 1840 4213 6929 2545 1569'.split()]
print('S5 mean detail s1.5 %.3f'%(sum(v)/len(v)))"
$M noise "$OUT/noise04_base.png" "$OUT/noise04_hdr.png" --json "$OUT/noise.json" | python3 -c "import json,sys;d=json.load(sys.stdin);print('S6 noise gainStd5px %.4f EV  detail %.3f'%(d['gainStd5pxEV'],d['detail']))"
if [ "$FULL" = "--full" ]; then
  F=corpus/ws07/6929_full.lfi; H=$(hint corpus/lfi/6929_sony-ilce-7m4.json)
  $B render --input $F --long-edge 9000 --no-dither $H --out "$OUT/full_base.png" >/dev/null
  $B render --input $F --long-edge 9000 --no-dither $H $HDR --out "$OUT/full_hdr.png" >/dev/null
  $B render --input $F --long-edge 1600 --no-dither $H --out "$OUT/f1600_base.png" >/dev/null
  $B render --input $F --long-edge 1600 --no-dither $H $HDR --out "$OUT/f1600_hdr.png" >/dev/null
  $M scale "$OUT/f1600_hdr.png" "$OUT/full_hdr.png" "$OUT/f1600_base.png" "$OUT/full_base.png" --json "$OUT/scale.json" >/dev/null
  python3 -c "import json;d=json.load(open('$OUT/scale.json'))['gainDiffEV'];print('S7 6929 1600 vs 7008 gain diff mean %.4f p99 %.4f EV'%(d['mean'],d['p99']))"
fi
