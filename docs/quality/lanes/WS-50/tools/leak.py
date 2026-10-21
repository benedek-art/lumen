"""R7: off-colour leak of Follow on the 8559 colour-range mask.
leak = alpha GAINED (summed) by pixels of a clearly different hue from the sample (OKLab hue
more than 60° away, chroma > 0.03: the green leaves, twigs and blue hose, not the can's own
shadow side) that were unselected (< 0.05) before Follow. usage: leak.py ROOT [ROOT2 ...]"""
import sys, numpy as np, mtool, gfproto
SAMPLE = np.array([0.3388, 0.1529, 0.1717])
for root in sys.argv[1:]:
    base = f'{root}/ref8559_C'
    rgb = mtool.read_lfi(f'{base}/_source.lfi').astype(np.float64)
    lab = gfproto.lab(rgb); ref = gfproto.lab(SAMPLE[None, None, :])[0, 0]
    hue = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])); href = np.degrees(np.arctan2(ref[2], ref[1]))
    dh = np.abs((hue - href + 180) % 360 - 180); chroma = np.hypot(lab[..., 1], lab[..., 2])
    far = (dh > 60) & (chroma > 0.03)
    a0 = mtool.read_f32(f'{base}/feather_0.f32')
    m = far & (a0 < 0.05)
    out = []
    for f in [10, 25, 50, 75, 100]:
        a = mtool.read_f32(f'{base}/feather_{f}.f32')
        out.append(f'F{f} {np.clip(a - a0, 0, None)[m].sum() / 1e3:8.1f}k')
    print(root.split('/')[-1], 'off-colour alpha gained (sum, k px·alpha):', '  '.join(out))
