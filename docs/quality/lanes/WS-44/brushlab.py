#!/usr/bin/env python3
"""WS-44 brush lab: writes stroke fixtures, runs `lumen-render strokes`, measures planes.

    python3 docs/quality/lanes/WS-44/brushlab.py fixtures OUT_DIR
    python3 docs/quality/lanes/WS-44/brushlab.py measure OUT_DIR     (after `run`)
    python3 docs/quality/lanes/WS-44/brushlab.py run OUT_DIR [BIN]   (fixtures + render + measure)

Synthetic extent 1024x683 (3:2) unless a photo is given. Size is a diameter as a fraction
of the long edge, so size 0.08 at 1024 is a 41 px radius.
"""
import json, math, os, subprocess, sys
import numpy as np

W, H = 1024, 683

def stroke(points, size=0.08, feather=50, flow=100, density=100, erase=False, automask=False, pressure=None):
    pts = []
    for i, (x, y) in enumerate(points):
        p = 1.0 if pressure is None else pressure[i]
        pts.append([x / W, y / H, p, i * 8])
    s = {"points": pts, "size": size, "feather": feather, "flow": flow, "density": density}
    if erase: s["erase"] = True
    if automask: s["automask"] = True
    return s

def line(x0, y0, x1, y1, n):
    return [(x0 + (x1 - x0) * t / (n - 1), y0 + (y1 - y0) * t / (n - 1)) for t in range(n)]

def fixtures():
    f = {}
    # Feather profile: one straight horizontal stroke per feather value, densely sampled.
    for fe in (0, 25, 50, 75, 100):
        f[f"feather{fe}"] = [stroke(line(150, 340, 870, 340, 120), feather=fe)]
    # The single dab (a click), same sizes: the reference the stroke must match.
    for fe in (0, 50, 100):
        f[f"dab{fe}"] = [stroke([(512, 340)], feather=fe)]
    # Flow 50: two crossing passes. Density 60 cap: three passes at flow 100.
    f["flow50"] = [stroke(line(150, 260, 870, 260, 120), flow=50, feather=0),
                   stroke(line(400, 100, 400, 600, 120), flow=50, feather=0)]
    f["density60"] = [stroke(line(150, 260, 870, 260, 120), density=60, feather=0),
                      stroke(line(400, 100, 400, 600, 120), density=60, feather=0),
                      stroke(line(150, 260, 870, 260, 120), density=60, feather=0)]
    # Fast strokes: the same path recorded with only 6 events (a flick), small and large.
    for name, size in (("fast_small", 0.012), ("fast_large", 0.08)):
        pts = [(100 + 820 * t / 5, 340 + 180 * math.sin(t * 1.3)) for t in range(6)]
        f[name] = [stroke(pts, size=size, feather=50)]
    # A flick: two events across the frame, thin brush, Flow 30 (where stamps would bead).
    f["flick30"] = [stroke([(100, 340), (920, 340)], size=0.012, flow=30, feather=50)]
    # Self-overlap in ONE stroke at flow 50 (a scribble back over itself).
    f["scribble50"] = [stroke(line(150, 340, 870, 340, 60) + line(870, 340, 150, 345, 60), flow=50, feather=0)]
    # Erase: paint a band, erase across it at feather 50 and at flow 50.
    f["erase"] = [stroke(line(150, 340, 870, 340, 120), size=0.15, feather=0),
                  stroke(line(300, 100, 300, 600, 120), erase=True, feather=50),
                  stroke(line(650, 100, 650, 600, 120), erase=True, feather=0, flow=50)]
    # Pressure ramp 0.1 -> 1 along the stroke.
    n = 120
    f["pressure"] = [stroke(line(150, 340, 870, 340, n), feather=0, pressure=[0.1 + 0.9 * i / (n - 1) for i in range(n)])]
    return f

def write_fixtures(out):
    os.makedirs(out, exist_ok=True)
    for name, strokes in fixtures().items():
        json.dump({"version": 1, "strokes": strokes}, open(os.path.join(out, name + ".json"), "w"))

def read_pfm(path):
    with open(path, "rb") as fh:
        assert fh.readline().strip() == b"Pf"
        w, h = map(int, fh.readline().split())
        scale = float(fh.readline())
        a = np.frombuffer(fh.read(), dtype="<f4" if scale < 0 else ">f4").reshape(h, w)
    return np.flipud(a).astype(np.float64)

def profile_ref(rho, feather):
    """The single-dab radial profile the cursor promises: 1 inside the hardness radius,
    smoothstep shoulder to the rim."""
    h = 1 - feather / 100
    h = min(h, max(0.0, 1 - 1 / 41.0))
    if rho <= h: return 1.0
    if rho >= 1: return 0.0
    u = (rho - h) / (1 - h)
    return 1 - u * u * (3 - 2 * u)

def measure(out):
    res = {}
    r = 0.08 / 2 * W
    for fe in (0, 25, 50, 75, 100):
        p = os.path.join(out, f"feather{fe}.pfm")
        if not os.path.exists(p): continue
        a = read_pfm(p)
        col = a[:, 500]
        offs = np.arange(H) + 0.5 - 340
        ref = np.array([profile_ref(abs(d) / r, fe) for d in offs])
        err = float(np.max(np.abs(col - ref)))
        # where the stroke falls to 50 %, in radii
        above = offs[(col >= 0.5) & (offs > 0)]
        half = float(above.max() / r) if len(above) else 0.0
        refhalf = float(offs[(ref >= 0.5) & (offs > 0)].max() / r)
        # width between 10% and 90% (the visible soft edge), in radii
        def last(th):
            sel = offs[(col >= th) & (offs > 0)]
            return float(sel.max() / r) if len(sel) else 0.0
        res[f"feather{fe}"] = {"maxErrVsDabProfile": round(err, 4), "half_r": round(half, 3),
                               "ref_half_r": round(refhalf, 3),
                               "edge10_90_r": round(last(0.1) - last(0.9), 3),
                               "centre": round(float(col[340]), 4)}
    for fe in (0, 50, 100):
        p = os.path.join(out, f"dab{fe}.pfm")
        if not os.path.exists(p): continue
        a = read_pfm(p)
        row = a[340, :]
        offs = np.arange(W) + 0.5 - 512
        ref = np.array([profile_ref(abs(d) / r, fe) for d in offs])
        res[f"dab{fe}"] = {"maxErrVsProfile": round(float(np.max(np.abs(row - ref))), 4)}
    if os.path.exists(os.path.join(out, "flow50.pfm")):
        a = read_pfm(os.path.join(out, "flow50.pfm"))
        res["flow50"] = {"single": round(float(a[260, 700]), 4), "overlap": round(float(a[260, 400]), 4),
                         "expect_single": 0.5, "expect_overlap": 0.75}
    if os.path.exists(os.path.join(out, "density60.pfm")):
        a = read_pfm(os.path.join(out, "density60.pfm"))
        res["density60"] = {"max": round(float(a.max()), 4), "single": round(float(a[260, 700]), 4)}
    if os.path.exists(os.path.join(out, "scribble50.pfm")):
        a = read_pfm(os.path.join(out, "scribble50.pfm"))
        res["scribble50"] = {"centre": round(float(a[342, 500]), 4)}
    for name, size in (("fast_small", 0.012), ("fast_large", 0.08)):
        p = os.path.join(out, name + ".pfm")
        if not os.path.exists(p): continue
        a = read_pfm(p)
        rr = size / 2 * W
        # Walk the column maxima from x=120..900: along a gap-free stroke the peak of every
        # column is the full value; beading shows as dips. Edge ripple: width at 50 %.
        peaks = a[:, 130:900].max(axis=0)
        widths = (a[:, 130:900] >= 0.5).sum(axis=0)
        res[name] = {"radius_px": rr, "peakMin": round(float(peaks.min()), 4),
                     "peakMax": round(float(peaks.max()), 4),
                     "width50_min_px": int(widths.min()), "width50_max_px": int(widths.max())}
    if os.path.exists(os.path.join(out, "flick30.pfm")):
        a = read_pfm(os.path.join(out, "flick30.pfm"))
        c = a[340, 150:870]
        res["flick30"] = {"centreMin": round(float(c.min()), 4), "centreMax": round(float(c.max()), 4),
                          "ripple": round(float(c.max() - c.min()), 4)}
    if os.path.exists(os.path.join(out, "erase.pfm")):
        a = read_pfm(os.path.join(out, "erase.pfm"))
        res["erase"] = {"painted": round(float(a[340, 500]), 4), "erasedCentre": round(float(a[340, 300]), 4),
                        "eraseFlow50": round(float(a[340, 650]), 4)}
    if os.path.exists(os.path.join(out, "pressure.pfm")):
        a = read_pfm(os.path.join(out, "pressure.pfm"))
        xs = [160, 330, 510, 690, 860]
        # Under max-combine a pixel takes the strongest dab within its reach, so the
        # expected value at x is the pressure where the dab's flat core ends ahead of it.
        reach = r * (1 - 1 / r)
        def p_at(x): return 0.1 + 0.9 * min(max((x - 150) / 720, 0), 1)
        res["pressure"] = {"centre_at_x": {str(x): round(float(a[340, x]), 3) for x in xs},
                           "expected": {str(x): round(p_at(x + 0.5), 3) for x in xs},
                           "halfwidth_px": {str(x): int((a[:, x] >= 0.25).sum()) for x in xs}}
    json.dump(res, open(os.path.join(out, "measure.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))

def run(out, binary):
    write_fixtures(out)
    for name in fixtures():
        j = os.path.join(out, name + ".json")
        subprocess.run([binary, "strokes", "--strokes", j, "--width", str(W), "--height", str(H),
                        "--out", os.path.join(out, name + ".png"),
                        "--pfm-out", os.path.join(out, name + ".pfm"),
                        "--metrics", os.path.join(out, name + ".metrics.json")],
                       check=True, stdout=subprocess.DEVNULL)
    measure(out)

if __name__ == "__main__":
    cmd, out = sys.argv[1], sys.argv[2]
    if cmd == "fixtures": write_fixtures(out)
    elif cmd == "measure": measure(out)
    elif cmd == "run":
        binary = sys.argv[3] if len(sys.argv) > 3 else ".build/release/lumen-render"
        run(out, binary)
