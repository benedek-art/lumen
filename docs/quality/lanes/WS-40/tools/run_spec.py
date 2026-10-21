#!/usr/bin/env python3
"""run_spec.py - render and measure every machine-checkable line of WS-40 SPEC.md.

    bash docs/quality/lanes/WS-40/tools/run_spec.sh [--out DIR] [--jobs 4] [--reuse]
                                                   [--sheets EVIDENCE_DIR --before-renders DIR]
                                                   [--unit-tests] [--json results.json]

Renders with the release lumen-render (--no-dither) into DIR/r, measures with
grain_metrics.py, and prints one row per spec line: the measured number, the threshold
and PASS/FAIL. Exit status 0 only if every evaluated line passes. Lines that are checked
elsewhere (macOS CI parity, unit tests unless --unit-tests) print CI / UNIT.

Frames (generated into DIR/frames when missing; scene-linear 0.18 grey, Rec.2020):
  strip  6000 x 1024   "6000 px equivalent": grain size is relative to the long edge, so
                       a 6000-long strip has exactly the grain of a 6000 px photo. All
                       its measurements use the 1024 x 1024 crop at x = 2488.
  g2048, g4096         flat grey at long edge 2048 / 4096 (preview/export scale test)
Corpus: corpus/synthetic/flat_grey.lfi (1024), grey_ramp.lfi (2800 x 400),
colorchecker.lfi (1368 x 920), and the RAW decodes corpus/lfi/{6929,2545,983,2348}_*.lfi
at their 2400 px decode, with the sidecar's asShotKelvin / asShotTint / captureISO.

--reuse keeps renders already in DIR/r (only for re-measuring; a verifier must not use it
after a rebuild). --sheets writes the evidence sheets SPEC.md names; with
--before-renders (the DIR/r of a run on the base commit) they show before | after.
Runs in ~4-5 min on 4 cores.
"""
import argparse
import concurrent.futures as cf
import glob
import json
import math
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../../../.."))
GM = os.path.join(HERE, "grain_metrics.py")
STRIP_CROP = "2488,0,1024,1024"
NEUTRAL = (6503.7072, 9.77, None)


def sidecar(pid):
    j = glob.glob(os.path.join(REPO, f"corpus/lfi/{pid}_*.json"))[0]
    h = json.load(open(j))["recipe_hint"]
    return j[:-5] + ".lfi", (h["asShotKelvin"], h["asShotTint"], h.get("captureISO"))


def make_flat(path, w, h):
    if os.path.exists(path):
        return
    hdr = np.array([w, h, 3], dtype="<u4").tobytes()
    with open(path + ".tmp", "wb") as f:
        f.write(b"LFI1" + hdr)
        row = np.full((w * 3,), 0.18, dtype="<f4").tobytes()
        for _ in range(h):
            f.write(row)
    os.replace(path + ".tmp", path)


def grain(amount, size=25, rough=50):
    return [f"look.grain.amount={amount}", f"look.grain.size={size}",
            f"look.grain.roughness={rough}"]


def stock(name, g=None):
    s = [f"look.filmLab.stock=lumen/{name}", "look.filmLab.amount=100"]
    return s + ([f"look.filmLab.grain.amount={g}"] if g is not None else [])


def jobs(frames):
    """name -> (input, (kelvin, tint, iso), long_edge, [--set ...])"""
    J = {}
    st, g2, g4 = frames["strip"], frames["g2048"], frames["g4096"]
    fg = os.path.join(REPO, "corpus/synthetic/flat_grey.lfi")
    ramp = os.path.join(REPO, "corpus/synthetic/grey_ramp.lfi")
    cc = os.path.join(REPO, "corpus/synthetic/colorchecker.lfi")

    def add(n, inp, le, sets, wb=NEUTRAL):
        J[n] = (inp, wb, le, sets)

    add("st_base", st, 6000, [])
    add("st_a0x", st, 6000, grain(0, 80, 10))          # amount 0, non-default size/rough
    for a in (25, 50, 75, 100):
        add(f"st_a{a}", st, 6000, grain(a, 25))
    add("st_a100_again", st, 6000, grain(100, 25))
    for s in (0, 25, 50, 75, 100):
        add(f"st_s{s}", st, 6000, grain(100, s))        # roughness 50
    for s in (0, 50, 100):
        for r in (0, 100):
            add(f"st_s{s}_r{r}", st, 6000, grain(100, s, r))
    for r in (25, 75):
        add(f"st_s50_r{r}", st, 6000, grain(100, 50, r))
    for sk in ("portra400", "trix400"):
        add(f"st_{sk}_base", st, 6000, stock(sk))
        add(f"st_{sk}", st, 6000, stock(sk, 100))
    add("st_portra400_g0", st, 6000, stock("portra400", 0))
    add("st_portra400_again", st, 6000, stock("portra400", 100))
    add("fg_base", fg, 1024, [])
    add("fg_a0x", fg, 1024, grain(0, 80, 10))
    for s in (0, 50, 100):
        add(f"fg_s{s}", fg, 1024, grain(100, s))
        add(f"g2k_s{s}", g2, 2048, grain(100, s))
        add(f"g4k_s{s}", g4, 4096, grain(100, s))
    add("g2k_base", g2, 2048, [])
    add("g4k_base", g4, 4096, [])
    add("fg_portra400_base", fg, 1024, stock("portra400"))
    add("fg_portra400", fg, 1024, stock("portra400", 100))
    add("ramp_base", ramp, 2800, [])
    add("ramp_a100", ramp, 2800, grain(100, 25))
    add("cc_base", cc, 1368, [])
    add("cc_a100", cc, 1368, grain(100, 100))
    for pid in ("6929", "2545", "983", "2348"):
        inp, wb = sidecar(pid)
        add(f"p{pid}_base", inp, 2400, [], wb)
        add(f"p{pid}_a50", inp, 2400, grain(50, 25), wb)
    inp, wb = sidecar("6929")
    add("p6929_a50_s50", inp, 2400, grain(50, 50), wb)
    add("p6929_portra400_base", inp, 2400, stock("portra400"), wb)
    add("p6929_portra400", inp, 2400, stock("portra400", 100), wb)
    return J


def render(binary, rdir, name, job, reuse):
    out = os.path.join(rdir, name + ".png")
    if reuse and os.path.exists(out):
        return name, None
    inp, (k, t, iso), le, sets = job
    cmd = [binary, "render", "--input", inp, "--as-shot-kelvin", str(k),
           "--as-shot-tint", str(t), "--no-dither", "--long-edge", str(le), "--out", out]
    if iso:
        cmd += ["--iso", str(int(iso))]
    for s in sets:
        cmd += ["--set", s]
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    return name, (None if p.returncode == 0 else p.stderr[-2000:])


class M:
    """Cached grain_metrics measurements."""

    def __init__(self, rdir):
        self.r, self.c = rdir, {}

    def p(self, n):
        return os.path.join(self.r, n + ".png")

    def check(self, g, b, crop=None):
        key = (g, b, crop)
        if key not in self.c:
            cmd = [sys.executable, GM, "check", self.p(g), self.p(b)]
            if crop:
                cmd += ["--crop", crop]
            self.c[key] = json.loads(subprocess.check_output(cmd))
        return self.c[key]

    def st(self, g, b="st_base"):
        return self.check(g, b, STRIP_CROP)

    def scale(self, g1, b1, g2, b2, f):
        out = os.path.join(self.r, f"scale_{g2}.json")
        subprocess.check_output([sys.executable, GM, "scale", self.p(g1), self.p(b1),
                                 self.p(g2), self.p(b2), "--factor", str(f), "--json", out])
        return json.load(open(out))

    def envelope(self, g, b):
        return json.loads(subprocess.check_output(
            [sys.executable, GM, "envelope", self.p(g), self.p(b), "--json"]))

    def same_bytes(self, a, b):
        from PIL import Image
        A = np.asarray(Image.open(self.p(a)).convert("RGB")).astype(int)
        B = np.asarray(Image.open(self.p(b)).convert("RGB")).astype(int)
        return int(np.abs(A - B).max()) if A.shape == B.shape else 999


ROWS = []


def row(line, what, value, ok, threshold):
    ROWS.append({"line": line, "what": what, "value": value, "threshold": threshold,
                 "status": ok if isinstance(ok, str) else ("PASS" if ok else "FAIL")})


def f3(v):
    return "-" if v is None else (f"{v:.3g}" if abs(v) < 1e4 else f"{v:.2e}")


def evaluate(m, unit_tests):
    L1 = [f"st_s{s}" + ("" if r == 50 else f"_r{r}") for s in (0, 50, 100) for r in (0, 50, 100)]
    stocks = ["st_portra400", "st_trix400"]
    stock_base = {"st_portra400": "st_portra400_base", "st_trix400": "st_trix400_base"}
    pre = ["fg_s0", "fg_s50", "fg_s100"]

    def chk(n):
        if n in stock_base:
            return m.st(n, stock_base[n])
        if n.startswith("fg_"):
            return m.check(n, "fg_base")
        return m.st(n)

    allg = L1 + stocks + pre
    # 1 no period
    worst = lambda key: max(allg, key=lambda n: abs(chk(n)["acf_beyond"][key] or 0))
    n = worst("ring_absmax"); v = chk(n)["acf_beyond"]["ring_absmax"]
    row("1a", f"max |ring-mean acf| at lags >= 3 cl (worst: {n})", f3(v), v < 0.05, "< 0.05")
    n = worst("axis_absmax"); v = chk(n)["acf_beyond"]["axis_absmax"]
    row("1b", f"max |acf_x|,|acf_y| at 64/128/256/512 (worst: {n})", f3(v), v < 0.05, "< 0.05")
    n = worst("max2d"); v = chk(n)["acf_beyond"]["max2d"]
    row("1c", f"max acf at any 2D lag 3cl..512 (worst: {n} at "
        f"{chk(n)['acf_beyond']['max2d_lag']})", f3(v), v < 0.15, "< 0.15")
    # 2 spikes
    n = max(allg, key=lambda k: chk(k)["spike2d_interp"]); v = chk(n)["spike2d_interp"]
    row("2a", f"2D spectrum spike / smooth radial power (worst: {n}, period "
        f"{f3(chk(n)['spike2d_interp_period_px'])} px; white ~12)", f3(v), v < 60, "< 60")
    n = max(allg, key=lambda k: chk(k)["radial_spike"]); v = chk(n)["radial_spike"]
    row("2b", f"radial spectrum spike (worst: {n} at f={f3(chk(n)['radial_spike_freq'])})",
        f3(v), v < 2.0, "< 2.0")
    # 3 amount
    amts = [0, 25, 50, 75, 100]
    stds = [0.0] + [m.st(f"st_a{a}")["std"] for a in amts[1:]]
    mono = all(b > a for a, b in zip(stds, stds[1:]))
    A = np.array(amts, float); S = np.array(stds)
    k, c0 = np.polyfit(A, S, 1)
    r2 = 1 - ((S - (k * A + c0)) ** 2).sum() / ((S - S.mean()) ** 2).sum()
    row("3a", "std vs Amount 0/25/50/75/100 (Size 25, 6000 eq) strictly increasing",
        " / ".join(f"{s:.2f}" for s in stds), mono, "monotonic")
    row("3b", "R^2 of linear fit std(Amount)", f"{r2:.4f}", r2 > 0.99, "> 0.99")
    d = max(m.same_bytes("st_a0x", "st_base"), m.same_bytes("fg_a0x", "fg_base"))
    row("3c", "Amount 0 (Size 80, Rough 10) vs no grain: max |code diff|", d, d == 0, "== 0")
    d = m.same_bytes("st_portra400_g0", "st_portra400_base")
    row("3d", "Portra grain 0 vs stock without grain: max |code diff|", d, d == 0, "== 0")
    # 4 amplitude / visibility
    v = m.st("st_a100")["std"]
    row("4a", "std, Amount 100 Size 25, mid grey, 6000 eq (codes)", f3(v), 10 <= v <= 14, "10..14")
    a = m.check("p6929_a50", "p6929_base"); b = m.check("p6929_a50_s50", "p6929_base")
    row("4b", "6929 @2400, Amount 50 Size 25: std (codes) / cl (px)",
        f"{a['std']:.2f} / {a['cl']:.2f}", a["std"] >= 2.5 and a["cl"] <= 1.5, ">= 2.5 / <= 1.5")
    row("4c", "6929 @2400, Amount 50 Size 50: std (codes) / cl (px)",
        f"{b['std']:.2f} / {b['cl']:.2f}", b["std"] >= 3.0 and b["cl"] <= 1.5, ">= 3.0 / <= 1.5")
    # 5 envelope
    e = m.envelope("ramp_a100", "ramp_base")
    row("5a", f"grey_ramp per-bin std vs sqrt(p(1-p)) shape, max |dev| ({e['bins_used']} bins)",
        f3(e["max_abs_dev"]), e["max_abs_dev"] <= 0.20, "<= 0.20")
    ok = 64 <= e["peak_lo"] < 192 and e["first_over_peak"] <= 0.25 and e["last_over_peak"] <= 0.5
    row("5b", "peak bin code / bin 0-16 over peak / bin 239-255 over peak",
        f"{e['peak_lo']:.0f} / {e['first_over_peak']:.2f} / {e['last_over_peak']:.2f}", ok,
        "64..191 / <= 0.25 / <= 0.50")
    # 6 size
    cls = [m.st(f"st_s{s}")["cl"] for s in (0, 25, 50, 75, 100)]
    ratios = [b / a for a, b in zip(cls, cls[1:])]
    row("6a", "corr length (px, 6000 eq) Size 0/25/50/75/100; min adjacent ratio",
        " / ".join(f"{c:.2f}" for c in cls) + f"; {min(ratios):.2f}", min(ratios) > 1.15, "> 1.15")
    bands = {0: (0.6, 0.9), 25: (1.0, 1.5), 50: (1.6, 2.5), 100: (4.0, 5.5)}
    got = dict(zip((0, 25, 50, 75, 100), cls))
    ok = all(lo <= got[s] <= hi for s, (lo, hi) in bands.items())
    row("6b", "corr length in band at Size 0 / 25 / 50 / 100",
        " / ".join(f"{got[s]:.2f}" for s in bands), ok, "0.6-0.9 / 1.0-1.5 / 1.6-2.5 / 4.0-5.5")
    # 7 roughness
    rn = ["st_s50_r0", "st_s50_r25", "st_s50", "st_s50_r75", "st_s50_r100"]
    rs = [m.st(n) for n in rn]
    s50 = rs[2]["std"]
    dev = max(abs(r["std"] / s50 - 1) for r in rs)
    row("7a", "Roughness 0..100 (Size 50): max |std / std(r50) - 1|", f3(dev), dev < 0.15, "< 0.15")
    ku = [r["kurtosis"] for r in rs]
    ok = all(b >= a - 0.02 for a, b in zip(ku, ku[1:])) and ku[-1] - ku[0] >= 0.25
    row("7b", "kurtosis r0/25/50/75/100 (monotonic, r100 - r0 >= 0.25)",
        " / ".join(f"{k:.2f}" for k in ku), ok, "rise >= 0.25")
    ec = [r["energy_cv"] for r in rs]
    ok = all(b >= a * 0.98 for a, b in zip(ec, ec[1:])) and ec[-1] / ec[0] >= 1.2
    row("7c", "local-energy CV (8x8) r0..r100 (monotonic, r100/r0 >= 1.2)",
        " / ".join(f"{k:.3f}" for k in ec), ok, "ratio >= 1.2")
    # 8 scale
    for s in (0, 50, 100):
        for big, f in (("g2k", 2), ("g4k", 4)):
            sc = m.scale(f"fg_s{s}", "fg_base", f"{big}_s{s}", f"{big}_base", f)
            hn = sc["half_nyquist"]
            ok = (0.9 <= sc["std_ratio"] <= 1.1 and 0.85 <= hn["bin_ratio_min"]
                  and hn["bin_ratio_max"] <= 1.15 and 0.9 <= hn["band_ratio"] <= 1.1)
            row("8", f"Size {s}: {big}/{f} vs 1024: std ratio; bin ratio range; band ratio",
                f"{sc['std_ratio']:.3f}; {hn['bin_ratio_min']:.2f}-{hn['bin_ratio_max']:.2f}; "
                f"{hn['band_ratio']:.3f}", ok, "0.9-1.1; 0.85-1.15; 0.9-1.1")
    # 9 isotropy
    iso = [(n, chk(n)["clx"] / chk(n)["cly"]) for n in allg + ["st_s25", "st_s75"]]
    lo = min(iso, key=lambda t: t[1]); hi = max(iso, key=lambda t: t[1])
    row("9", f"cl_x / cl_y range (min {lo[0]}, max {hi[0]})", f"{lo[1]:.3f}..{hi[1]:.3f}",
        lo[1] >= 0.9 and hi[1] <= 1.1, "0.9..1.1")
    # 10 chroma
    cg = [m.st("st_a100"), m.check("fg_s50", "fg_base")]
    v = max(max(c["chroma_rg"], c["chroma_bg"]) for c in cg)
    row("10a", "creative: std(dR-dG), std(dB-dG) / luma std on grey", f3(v), v < 0.10, "< 0.10")
    c = m.check("cc_a100", "cc_base")
    v = max(c["logchroma_rg"], c["logchroma_bg"])
    row("10b", "creative on colorchecker: std(ln R'/R - ln G'/G) / std(ln Y'/Y), RG|BG",
        f3(v), v < 0.10, "< 0.10")
    for n in ("st_portra400", "fg_portra400"):
        c = m.st(n, "st_portra400_base") if n.startswith("st") else m.check(n, "fg_portra400_base")
        hi_ = max(c["chroma_rg"], c["chroma_bg"]); lo_ = min(c["chroma_rg"], c["chroma_bg"])
        row("10c", f"Portra 400 grain 100 ({'6000 eq' if n.startswith('st') else '1024'}): "
            "chroma RG, BG / luma std", f"{c['chroma_rg']:.2f}, {c['chroma_bg']:.2f}",
            hi_ <= 0.5 and lo_ >= 0.1, "0.10..0.50")
    c = m.st("st_trix400", "st_trix400_base")
    v = max(c["chroma_rg"], c["chroma_bg"])
    row("10d", "Tri-X 400 (mono) chroma / luma std", f3(v), v < 0.10, "< 0.10")
    # 11 determinism
    d = max(m.same_bytes("st_a100", "st_a100_again"),
            m.same_bytes("st_portra400", "st_portra400_again"))
    row("11a", "two renders of the same recipe (creative, Portra): max |code diff|", d, d == 0, "== 0")
    # unit tests (3e float identity, 11b seed)
    if unit_tests:
        p = subprocess.run(["swift", "test", "--filter", "LumenCoreTests.GrainSpecTests"],
                           cwd=REPO, capture_output=True, text=True)
        tail = (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]
        row("3e/11b", "swift test --filter LumenCoreTests.GrainSpecTests", tail[0][:60],
            p.returncode == 0, "exit 0")
    else:
        row("3e/11b", "unit tests GrainSpecTests (run with --unit-tests)", "-", "UNIT", "exit 0")
    row("12", "GPU/CPU grain parity (KernelGoldenTests, macOS CI)", "-", "CI", "max diff < 1e-3")
    # 13 no plate / tiling code
    pat = ("GrainPlateMemo|plateEncodeScale|latticeValue|plateSize|FilmGrainProfile\\.sample\\("
           "|FilmGrainProfile\\.plate\\(|\\.plate\\(channel|renderPixelsPerCell|defaultPersistence")
    hits = subprocess.run(["grep", "-rnE", pat, "Sources", "Tests"], cwd=REPO,
                          capture_output=True, text=True).stdout.splitlines()
    hits += subprocess.run(["grep", "-nE", "affineTile", "Sources/LumenPipeline/RenderGraph.swift"],
                           cwd=REPO, capture_output=True, text=True).stdout.splitlines()
    hits += subprocess.run(["grep", "-niE", "octave|persistence",
                            "Sources/LumenCore/Engine/FilmLab.swift"],
                           cwd=REPO, capture_output=True, text=True).stdout.splitlines()
    row("13", "plate / tiling / octave code left (grep hits)", len(hits), len(hits) == 0, "== 0")


SHEETS = [
    # file, items [(label, render, base)], pos, size, zoom
    ("01_flatgrey_6000eq_a100_s25.png", [("a100 s25", "st_a100", "st_base")], "200,200", 320, 1),
    ("02_p6929_wall_a50_s25.png", [("a50 s25", "p6929_a50", "p6929_base")], "140,1100", 384, 1),
    ("03_p2545_grass_a50_s25.png", [("a50 s25", "p2545_a50", "p2545_base")], "1050,1050", 384, 1),
    ("04_p983_trees_snow_a50_s25.png", [("a50 s25", "p983_a50", "p983_base")], "890,258", 384, 1),
    ("05_p2348_jacket_a50_s25.png", [("a50 s25", "p2348_a50", "p2348_base")], "400,1265", 384, 1),
    ("06_size_sweep_6000eq.png", [(f"s{s}", f"st_s{s}", "st_base") for s in (0, 25, 50, 75, 100)],
     "200,200", 160, 2),
    ("07_roughness_sweep_6000eq.png",
     [(f"r{r}", n, "st_base") for r, n in zip((0, 25, 50, 75, 100),
                                               ("st_s50_r0", "st_s50_r25", "st_s50",
                                                "st_s50_r75", "st_s50_r100"))], "200,200", 160, 2),
    ("08_stocks_6000eq.png", [("portra400 g100", "st_portra400", "st_portra400_base"),
                              ("trix400 g100", "st_trix400", "st_trix400_base")], "200,200", 256, 1),
]


def sheets(rdir, before, out):
    os.makedirs(out, exist_ok=True)
    for fn, items, pos, size, zoom in SHEETS:
        args = []
        for lab, g, b in items:
            for tag, d in (("before", before), ("after", rdir)):
                if d and os.path.exists(os.path.join(d, g + ".png")):
                    args.append(f"{tag} {lab}={os.path.join(d, g + '.png')}|"
                                f"{os.path.join(d, b + '.png')}")
        cols = 4 if len(args) > 1 else 2
        subprocess.run([sys.executable, GM, "sheet", "--out", os.path.join(out, fn), "--pos", pos,
                        "--size", str(size), "--zoom", str(zoom), "--columns", str(cols)] + args,
                       check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "ws40-spec"))
    ap.add_argument("--bin", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--unit-tests", action="store_true")
    ap.add_argument("--sheets")
    ap.add_argument("--before-renders")
    ap.add_argument("--json")
    a = ap.parse_args()
    fdir, rdir = os.path.join(a.out, "frames"), os.path.join(a.out, "r")
    os.makedirs(fdir, exist_ok=True); os.makedirs(rdir, exist_ok=True)
    frames = {"strip": (6000, 1024), "g2048": (2048, 2048), "g4096": (4096, 4096)}
    for k, (w, h) in frames.items():
        make_flat(os.path.join(fdir, f"{k}.lfi"), w, h)
    frames = {k: os.path.join(fdir, f"{k}.lfi") for k in frames}
    J = jobs(frames)
    # big frames first so the pool stays busy
    order = sorted(J, key=lambda n: -J[n][2])
    errs = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for name, err in ex.map(lambda n: render(a.bin, rdir, n, J[n], a.reuse), order):
            if err:
                errs.append((name, err))
    if errs:
        for n, e in errs:
            print(f"RENDER FAILED {n}: {e}")
        sys.exit(2)
    m = M(rdir)
    evaluate(m, a.unit_tests)
    w = max(len(r["what"]) for r in ROWS)
    for r in ROWS:
        print(f"{r['status']:<5} {r['line']:<6} {r['what']:<{w}}  {str(r['value']):<36} "
              f"{r['threshold']}")
    if a.json:
        json.dump(ROWS, open(a.json, "w"), indent=1)
    if a.sheets:
        sheets(rdir, a.before_renders, a.sheets)
    fails = [r for r in ROWS if r["status"] == "FAIL"]
    print(f"\n{len(ROWS) - len(fails)}/{len(ROWS)} rows not failing; {len(fails)} FAIL")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
