#!/bin/bash
# Generate every WS-14 probe frame and render every image SPEC.md measures.
# usage: bash docs/quality/lanes/WS-14/tools/render_all.sh OUT [group ...]     (run from repo root)
#   groups: frames pink steps hardedge ramps blobs noise skin synth photos native   (default: all)
#   env: BIN (lumen-render), PAR (parallel jobs, default 4)
# Layout: OUT/frames/*.lfi  OUT/<group>/<prefix>_{id,t<v>,c<v>}.png
# Cost on 4 cores: about 25-35 min for everything; native ~10 min, photos ~8 min.
set -e
OUT=$1; shift
G=${*:-frames pink steps hardedge ramps blobs noise skin synth photos native}
T=$(cd "$(dirname "$0")" && pwd)
export BIN=${BIN:-$(swift build -c release --show-bin-path)/lumen-render}
RS="$T/render_set.sh"
F=$OUT/frames
has() { [[ " $G " == *" $1 "* ]]; }
if has frames || [ ! -f $F/blobs_6000.lfi ]; then python3 $T/gen_frames.py $F; fi
if has pink; then
  $RS $F/pink_6000.lfi $OUT/pink p6000 6000
  $RS $F/pink_6000.lfi $OUT/pink p3200 3200
  $RS $F/pink_6000.lfi $OUT/pink p1600 1600
  VALS="-100 100" $RS $F/pink_6000.lfi $OUT/pink p1024 1024
fi
if has steps; then
  VALS="-100 50 100" $RS $F/steps_6000.lfi $OUT/steps s6000 6000
  VALS="-100 50 100" $RS $F/steps_6000.lfi $OUT/steps s1600 1600
fi
if has hardedge; then VALS="-100 100" $RS corpus/synthetic/hard_edge.lfi $OUT/he he 1600; fi
if has ramps; then
  VALS="-100 -50 50 100" $RS $F/ramp_tex.lfi $OUT/ramp r 2400
  VALS="-100 100" KEYS=clarity $RS $F/ramp_tex0.lfi $OUT/ramp r0 2400
  VALS="-100 50 100" $RS $F/ramp_lo.lfi $OUT/ramp rl 2400
fi
if has blobs; then
  VALS="-100 50 100" $RS $F/blobs_6000.lfi $OUT/blobs b6000 6000
  VALS="-100 50 100" $RS $F/blobs_6000.lfi $OUT/blobs b1600 1600
fi
if has noise; then VALS="-100 100" $RS $F/noise_6000.lfi $OUT/noise n6000 6000; fi
if has skin; then VALS="-100 -50 50 100" $RS $F/skin_6000.lfi $OUT/skin k6000 6000; fi
if has synth; then
  for s in flat_grey grey_ramp colorchecker skin_tones; do
    VALS="-100 100" $RS corpus/synthetic/$s.lfi $OUT/synth $s 1600
  done
fi
if has photos; then
  for p in 6929_sony-ilce-7m4 6933_sony-ilce-7m4 2545_panasonic-dmc-gx85 1569_panasonic-dmc-gx80 \
           983_canon-eos-5d-mark-iv 2348_panasonic-dc-g9 4694_canon-eos-r5 3437_canon-eos-rebel-t7i; do
    $RS corpus/lfi/$p.lfi $OUT/photos ${p%%_*} 1600
  done
fi
if has native; then
  # full-width strips of the native decodes (long edge kept = full-size radii)
  python3 $T/lfi_strip.py corpus/native/6929_sony-ilce-7m4.lfi $F/n6929.lfi 1700 2700
  python3 $T/lfi_strip.py corpus/native/2545_panasonic-dmc-gx85.lfi $F/n2545.lfi 400 1300
  python3 $T/lfi_strip.py corpus/native/983_canon-eos-5d-mark-iv.lfi $F/n983.lfi 700 1700
  for n in 6929 2545 983; do
    VALS="-100 -25 25 50 100" PAR=${PAR:-3} $RS $F/n$n.lfi $OUT/native ${n}_full 99999
    VALS="-100 -25 25 50 100" $RS $F/n$n.lfi $OUT/native ${n}_1600 1600
  done
fi
echo "render_all done -> $OUT"
