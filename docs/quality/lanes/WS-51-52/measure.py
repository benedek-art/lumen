#!/usr/bin/env python3
"""Local-vs-global parity harness for WS-51/52.

Renders a frame twice through lumen-render (no dither): once with a global control,
once with the same control inside a full-frame radial mask, and reports CIEDE2000
between the two outputs. Usage:

  measure.py parity  <input.lfi> <global-set> <local-set> [--as-shot-kelvin K ...]
  measure.py suite   <input.lfi> [--global-temp K T]
                     # every control's parity, as-shot from sidecar; CASES="a|b" selects
  measure.py feather <input.lfi> <global-set> <local-set> [out.png]
                     # radial r=0.3 feather 60: overshoot and monotonicity across the ramp

Sets are semicolon-separated key=value lists (values may be JSON); global-set FULL
means "the same local adjustment through a full-frame mask"; local keys are relative to masks.0.adjust.
"""
import json, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image

BIN = os.environ.get("BIN", ".build/release/lumen-render")
TMP = tempfile.mkdtemp()

def recipe(local=None, radial=None, extra_mask=None):
    r = {}
    if local is not None:
        comp = {"op": "add", "kind": "radial", "amount": 100, "invert": False,
                "center": [0.5, 0.5], "radii": [5, 5], "rotation": 0, "feather": 0}
        if radial: comp.update(radial)
        m = {"id": "6f000000-0000-0000-0000-000000000001", "name": "M", "enabled": True,
             "invert": False, "amount": 100, "blend": "normal",
             "components": [comp], "adjust": local}
        if extra_mask: m.update(extra_mask)
        r["masks"] = [m]
    return r

def parse(s):
    out = {}
    for kv in filter(None, s.split(";")):
        k, v = kv.split("=", 1)
        try: v = json.loads(v)
        except Exception: pass
        out[k] = v
    return out

def render(inp, rec, sets=(), extra=(), le=768):
    # Non-scalar global values (point-colour swatches, wheels) go into the recipe tree.
    rec = json.loads(json.dumps(rec)); flat = []
    for k, v in sets:
        if isinstance(v, (list, dict)):
            node = rec; parts = k.split(".")
            for part in parts[:-1]: node = node.setdefault(part, {})
            node[parts[-1]] = v
        else:
            flat.append((k, v))
    sets = flat
    rp = os.path.join(TMP, f"r{abs(hash(json.dumps(rec)+str(sets)))}.json")
    out = rp.replace(".json", ".png")
    json.dump(rec, open(rp, "w"))
    cmd = [BIN, "render", "--input", inp, "--recipe", rp, "--no-dither",
           "--long-edge", str(le), "--out", out]
    for k, v in sets: cmd += ["--set", f"{k}={v}"]
    cmd += list(extra)
    subprocess.run(cmd, check=True, capture_output=True)
    return np.asarray(Image.open(out).convert("RGB")).astype(np.float64) / 255.0, out

def srgb_to_lab(rgb):
    c = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    M = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = c @ M.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], -1)

def de2000(l1, l2):
    L1, a1, b1 = np.moveaxis(l1, -1, 0); L2, a2, b2 = np.moveaxis(l2, -1, 0)
    C1 = np.hypot(a1, b1); C2 = np.hypot(a2, b2); Cb = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cb**7 / (Cb**7 + 25**7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360; h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1; dCp = C2p - C1p
    dh = h2p - h1p; dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(C1p * C2p == 0, 0, dh)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lbp = (L1 + L2) / 2; Cbp = (C1p + C2p) / 2
    hs = h1p + h2p
    hbp = np.where(C1p * C2p == 0, hs, np.where(np.abs(h1p - h2p) <= 180, hs / 2,
                   np.where(hs < 360, (hs + 360) / 2, (hs - 360) / 2)))
    T = (1 - 0.17 * np.cos(np.radians(hbp - 30)) + 0.24 * np.cos(np.radians(2 * hbp))
         + 0.32 * np.cos(np.radians(3 * hbp + 6)) - 0.20 * np.cos(np.radians(4 * hbp - 63)))
    dth = 30 * np.exp(-((hbp - 275) / 25) ** 2)
    Rc = 2 * np.sqrt(Cbp**7 / (Cbp**7 + 25**7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / np.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp; Sh = 1 + 0.015 * Cbp * T
    Rt = -np.sin(np.radians(2 * dth)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2
                   + Rt * (dCp / Sc) * (dHp / Sh))

def de(a, b):
    return de2000(srgb_to_lab(a), srgb_to_lab(b))

def stats(d):
    return {"mean": round(float(d.mean()), 3), "p95": round(float(np.percentile(d, 95)), 3),
            "max": round(float(d.max()), 3)}

def as_shot(inp):
    j = inp[:-4] + ".json"
    if os.path.exists(j):
        h = json.load(open(j)).get("recipe_hint") or {}
        if "asShotKelvin" in h:
            return float(h["asShotKelvin"]), float(h.get("asShotTint", 0))
    return 5500.0, 0.0

PC = {"sample": [0.06, 0.10, 0.03], "range": 70, "variance": 0,
      "shift": {"h": 40, "s": 40, "l": -10}}
WH = {"shadows": {"hue": 210, "sat": 0.35, "lum": 0}, "mid": {"hue": 40, "sat": 0.2, "lum": 0},
      "high": {"hue": 50, "sat": 0.25, "lum": 0}}

def suite_cases(K, T, base_g=None):
    """(name, global-set, local-set) with the local slider's documented global meaning."""
    base_g = dict(base_g or {})
    bk, bt = base_g.get("develop.raw.temp", K), base_g.get("develop.raw.tint", T)
    def wb(t, g):
        mired = min(max(1e6 / bk - 0.5 * t, 20.0), 500.0)   # the engine's own clamp
        return {**base_g, "develop.raw.temp": 1e6 / mired,
                "develop.raw.tint": bt + 1.5 * g}
    c = [("exposure+1", {"develop.tone.exposure": 1}, {"exposure": 1}),
         ("exposure-1.5", {"develop.tone.exposure": -1.5}, {"exposure": -1.5}),
         ("temp+100", wb(100, 0), {"temp": 100}), ("temp-100", wb(-100, 0), {"temp": -100}),
         ("tint+100", wb(0, 100), {"tint": 100}), ("tint-60", wb(0, -60), {"tint": -60}),
         ("temp+40,tint-30", wb(40, -30), {"temp": 40, "tint": -30}),
         ("kelvin=3800", {**base_g, "develop.raw.temp": 3800}, {"kelvin": 3800}),
         ("sat+50", {"develop.color.saturation": 50}, {"sat": 50}),
         ("sat-100", {"develop.color.saturation": -100}, {"sat": -100}),
         ("vibrance+60", {"develop.color.vibrance": 60}, {"vibrance": 60}),
         ("pointColour", {"develop.pointColors": [PC]}, {"pointColors": [PC]}),
         ("wheels", {"look.wheels": WH}, {"wheels": WH}),
         ("contrast+50", {"develop.tone.contrast": 50}, {"contrast": 50}),
         ("highlights-80", {"develop.tone.highlights": -80}, {"highlights": -80}),
         ("shadows+80", {"develop.tone.shadows": 80}, {"shadows": 80}),
         ("whites+50", {"develop.tone.whites": 50}, {"whites": 50}),
         ("blacks-50", {"develop.tone.blacks": -50}, {"blacks": -50})]
    out = []
    for name, g, l in c:
        if base_g and "develop.raw.temp" not in g: g = {**base_g, **g}
        out.append((name, g, l))
    return out

def radial_t(inp, g, l, extra, base_sets=()):
    """Per-pixel fraction of the global move the local render made, binned by radius."""
    bi, _ = render(inp, recipe(), sets=list(base_sets), extra=extra)
    if g == "FULL":
        gi, _ = render(inp, recipe(local=l), sets=list(base_sets), extra=extra)
    else:
        gi, _ = render(inp, recipe(), sets=list(g.items()), extra=extra)
    li, lp = render(inp, recipe(local=l, radial={"radii": [0.3, 0.3], "feather": 60}),
                    sets=list(base_sets), extra=extra)
    return bi, gi, li, lp

def main():
    mode, inp = sys.argv[1], sys.argv[2]
    if mode == "parity":
        g, l = parse(sys.argv[3]), parse(sys.argv[4]); extra = sys.argv[5:]
        gi, _ = render(inp, recipe(), sets=list(g.items()), extra=extra)
        li, _ = render(inp, recipe(local=l), extra=extra)
        base, _ = render(inp, recipe(), extra=extra)
        print(json.dumps({"input": os.path.basename(inp), "global": g, "local": l,
                          "dE_local_vs_global": stats(de(gi, li)),
                          "dE_global_vs_base": stats(de(gi, base))}))

    if mode == "suite":
        K, T = as_shot(inp)
        extra = ["--as-shot-kelvin", str(K), "--as-shot-tint", str(T)] + sys.argv[3:]
        base_g = {}
        if "--global-temp" in extra:
            i = extra.index("--global-temp"); base_g = {"develop.raw.temp": float(extra[i + 1]),
                                                        "develop.raw.tint": float(extra[i + 2])}
            del extra[i:i + 3]
        base_sets = [(k, v) for k, v in base_g.items()]
        bi, _ = render(inp, recipe(), sets=base_sets, extra=extra)
        only = os.environ.get("CASES")
        for name, g, l in suite_cases(K, T, base_g):
            if only and name not in only.split("|"): continue
            gi, _ = render(inp, recipe(), sets=list(g.items()), extra=extra)
            li, _ = render(inp, recipe(local=l), sets=base_sets, extra=extra)
            moved = stats(de(gi, bi))
            # A control that did not move the picture makes parity vacuous (SPEC).
            print(json.dumps({"input": os.path.basename(inp), "asShot": [K, T], "case": name,
                              "dE_local_vs_global": stats(de(gi, li)),
                              "dE_global_vs_base": moved,
                              "vacuous": moved["mean"] <= 0.5}), flush=True)
    if mode == "feather":
        g = "FULL" if sys.argv[3] == "FULL" else parse(sys.argv[3])
        l = parse(sys.argv[4])
        K, T = as_shot(inp)
        extra = ["--as-shot-kelvin", str(K), "--as-shot-tint", str(T)]
        bi, gi, li, lp = radial_t(inp, g, l, extra)
        h, w, _ = bi.shape
        yy, xx = np.mgrid[0:h, 0:w]
        # radial radii are source-normalized per axis: r = 1 at the ellipse.
        r = np.hypot((xx + 0.5) / w - 0.5, (yy + 0.5) / h - 0.5) / 0.3
        lo, hi = np.minimum(bi, gi), np.maximum(bi, gi)
        over = np.maximum(lo - li, li - hi).max(-1) * 255     # codes outside [base, global]
        # Distance of local from base, relative to global from base, per pixel (ΔE).
        d_lb, d_gb = de(li, bi), de(gi, bi)
        sel = d_gb > 2
        bins = np.linspace(0, 2, 41)
        prof = []
        for a, b in zip(bins[:-1], bins[1:]):
            m = sel & (r >= a) & (r < b)
            if m.sum() > 50:
                prof.append((round(float((a + b) / 2), 3),
                             round(float(np.median(d_lb[m] / d_gb[m])), 3)))
        mono = all(p2[1] <= p1[1] + 0.03 for p1, p2 in zip(prof, prof[1:]))
        # Chroma dip: OKLab-ish via CIELAB C*, local below both ends by more than 2.
        lab_b, lab_g, lab_l = srgb_to_lab(bi), srgb_to_lab(gi), srgb_to_lab(li)
        # A halo is a ring lighter or darker than both sides: L* outside [base, full].
        Lb, Lg, Ll = lab_b[..., 0], lab_g[..., 0], lab_l[..., 0]
        halo = np.maximum(np.minimum(Lb, Lg) - Ll, Ll - np.maximum(Lb, Lg))
        cb, cg, cl = (np.hypot(x[..., 1], x[..., 2]) for x in (lab_b, lab_g, lab_l))
        ring = (r > 0.4) & (r < 1.6)
        dip = (np.minimum(cb, cg) - cl)[ring]
        print(json.dumps({"input": os.path.basename(inp), "global": g, "local": l,
                          "overshoot_codes_p999": round(float(np.percentile(over, 99.9)), 2),
                          "overshoot_codes_max": round(float(over.max()), 2),
                          "halo_L_p999": round(float(np.percentile(halo, 99.9)), 2),
                          "halo_L_max": round(float(halo.max()), 2),
                          "chroma_dip_p99": round(float(np.percentile(dip, 99)), 2),
                          "monotone": mono, "profile": prof[::4]}))
        if len(sys.argv) > 5:
            Image.open(lp).save(sys.argv[5])

if __name__ == "__main__":
    main()
