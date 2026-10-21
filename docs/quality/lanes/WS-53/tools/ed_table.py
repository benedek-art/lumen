import sys,os
sys.path.insert(0,os.path.dirname(__file__))
from diff import stats
f=lambda s:f"maxc={s['maxc']:.0f} meanc={s['meanc']:.3f} p99c={s['p99c']:.0f} %>2={s['pct_gt2']:.2f} maxlin={s['maxl']:.4f}"
for im in ['zone_plate','6929_sony-ilce-7m4','2545_panasonic-dmc-gx85','983_canon-eos-5d-mark-iv']:
  N=f'r/ed/{im}_none.png'
  for c in ['texture','clarity','dehaze','sharpness']:
    vals=[100] if c=='sharpness' else [-100,100]
    for v in vals:
      L=f'r/ed/{im}_L_{c}_{v}.png';G=f'r/ed/{im}_G_{c}_{v}.png'
      print(f"{im:26s} {c:9s} {v:5d} L-vs-G {f(stats(L,G))} | effG meanc={stats(N,G)['meanc']:.3f}")
    G100=f'r/ed/{im}_G_{c}_100.png'; GL=f'r/ed/{im}_GL50_{c}.png'
    print(f"{im:26s} {c:9s} G50+L50 vs G100 {f(stats(GL,G100))}")
  print(f"{im:26s} sharp-params(r2,m60) L100 vs G100 {f(stats(f'r/ed/{im}_Lp_sharpness_100.png',f'r/ed/{im}_Gp_sharpness_100.png'))}")
