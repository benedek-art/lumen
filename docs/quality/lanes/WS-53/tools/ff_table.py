import sys,os
sys.path.insert(0,os.path.dirname(__file__))
from diff import stats
ims=open('ims.txt').read().split()
print(f"{'image':28s} {'ctrl':9s} {'v':>5s} | L-vs-G maxc meanc p99c %>2 maxlin meanlin | effect(G-vs-none) meanc | effect(L-vs-none) meanc")
for c in ['texture','clarity','dehaze','sharpness']:
  for im in ims:
    for v in [-100,-50,50,100]:
      L=f'r/ff/{im}_L_{c}_{v}.png'; G=f'r/ff/{im}_G_{c}_{v}.png'; N=f'r/ff/{im}_none.png'
      eL=stats(N,L)
      if os.path.exists(G):
        s=stats(L,G); eG=stats(N,G)
        print(f"{im:28s} {c:9s} {v:5d} | {s['maxc']:4.0f} {s['meanc']:6.3f} {s['p99c']:4.0f} {s['pct_gt2']:6.2f} {s['maxl']:.4f} {s['meanl']:.5f} | {eG['meanc']:6.3f} | {eL['meanc']:6.3f}")
      else:
        print(f"{im:28s} {c:9s} {v:5d} | (no global)                                     |        | {eL['meanc']:6.3f}")
