#!/usr/bin/env python3
"""WS-06 rendered measurements (Contrast & Pivot), through lumen-render.

  measure.py BIN CORPUS WORK {ramp|colour|photos|all}

BIN     path to the release lumen-render
CORPUS  repository corpus/ directory (needs lfi/ and synthetic/)
WORK    scratch directory (renders are cached per BIN mtime; delete it to force)

Prints one line per SPEC item: `KEY value detail`. run_all.sh compares them with the
thresholds. Only numpy and Pillow are needed. Run with `python3 -I`.
"""
import glob, json, os, subprocess, sys
import numpy as np
from PIL import Image

BIN, CORPUS, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
WHAT = sys.argv[4] if len(sys.argv) > 4 else "all"
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mkframes import ramp_ev, RAMP_W, main as make_frames  # noqa: E402

PHOTOS = {  # id -> lfi stem
    "6929": "6929_sony-ilce-7m4", "2545": "2545_panasonic-dmc-gx85",
    "983": "983_canon-eos-5d-mark-iv", "2242": "2242_panasonic-dc-gx850",
    "2348": "2348_panasonic-dc-g9", "4694": "4694_canon-eos-r5",
    "1346": "1346_canon-eos-5d",
}


def out(key, value, detail=""):
    print(f"{key} {value:.6f} {detail}".rstrip(), flush=True)


# ---- OKLab (sRGB display output) --------------------------------------------------
def srgb_to_lin(v):
    v = v / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])


def oklch(rgb_codes):
    lab = np.cbrt(srgb_to_lin(rgb_codes) @ M1.T) @ M2.T
    L = lab[..., 0]; C = np.hypot(lab[..., 1], lab[..., 2])
    h = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360
    return L, C, h


def hdiff(a, b):
    return (a - b + 180) % 360 - 180


# ---- rendering ----------------------------------------------------------------------
def sidecar(path):
    # Synthetic frames written by mkframes.py have no sidecar; they are D65 like
    # corpus/synthetic.
    side = path[:-4] + ".json"
    hint = json.load(open(side)).get("recipe_hint", {}) if os.path.exists(side) else {}
    args = ["--as-shot-kelvin", str(hint.get("asShotKelvin", 6503.7072)),
            "--as-shot-tint", str(hint.get("asShotTint", 9.77))]
    if hint.get("captureISO"):
        args += ["--iso", str(hint["captureISO"])]
    return args


STAMP = str(int(os.path.getmtime(BIN)))


def sweep(name, lfi, key, values, extra=(), long_edge=1600, sets=(), dither=False):
    """Render a sweep; returns (metrics dict, {value_label: tile path})."""
    d = os.path.join(WORK, f"{name}_{STAMP}")
    js = d + ".json"
    if not os.path.exists(js):
        os.makedirs(d, exist_ok=True)
        cmd = [BIN, "sweep", "--input", lfi, "--key", key,
               "--values", ",".join(str(v) for v in values),
               "--long-edge", str(long_edge), "--out", d + ".png", "--metrics", js,
               "--tiles-dir", d] + sidecar(lfi) + list(extra)
        for s in sets:
            cmd += ["--set", s]
        if not dither:
            cmd.append("--no-dither")
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    m = json.load(open(js))
    tiles = {}
    for f in glob.glob(d + "/*.png"):
        tiles[float(os.path.basename(f)[:-4].split("_", 2)[2])] = f
    return m, tiles


def load(f):
    return np.asarray(Image.open(f).convert("RGB")).astype(float)


def tile_metric(m, value):
    for t in m["tiles"]:
        if abs(t["effectiveValue"] - value) < 1e-9:
            return t["metrics"]
    raise KeyError(value)


# ---- ramp: R1 pivot fixed, R2 clean grey, R3 highlight separation, R4 midtone slope --
def ramp():
    frames = os.path.join(WORK, "frames")
    if not os.path.exists(os.path.join(frames, "ramp.lfi")):
        make_frames(frames)
    lfi = os.path.join(frames, "ramp.lfi")
    ev = ramp_ev(np.arange(RAMP_W))
    cs = [-100, -50, 0, 50, 100]
    rows = {}
    for p in [-4, -3, -2, 0, 2, 3, 4]:
        _, tiles = sweep(f"ramp_p{p}", lfi, "develop.tone.contrast", cs, long_edge=RAMP_W,
                         extra=["--lut-size", "65"], sets=[f"develop.tone.contrastPivot={p}"])
        for c in cs:
            rows[(p, c)] = load(tiles[c])[32, :, 1]
    code = lambda r, e: float(np.interp(e, ev, r))
    # R1: the rendered code at the pivot does not move (pivots inside the drag range)
    worst, at = 0.0, ""
    for p in [-3, -2, 0, 2, 3]:
        for c in cs:
            d = abs(code(rows[(p, c)], p) - code(rows[(p, 0)], p))
            if d > worst:
                worst, at = d, f"pivot {p} contrast {c}"
    out("R1_pivot_code_drift", worst, f"codes; worst {at}")
    # R2: no clipped and no reversed columns on grey, every pivot incl. +-4 (old recipes)
    inside = (ev >= -9) & (ev <= 4.5)
    bad = 0
    for (p, c), r in rows.items():
        bad += int(((r[inside] >= 255) | (r[inside] <= 0)).sum())
        bad += int((np.diff(r[inside]) < 0).sum())
    out("R2_grey_clipped_or_reversed_columns", bad, "over 7 pivots x 5 contrasts, -9..+4.5 EV")
    # R3: codes spanned by +2..+4 EV, relative to contrast 0 (pivot 0)
    span = lambda r: code(r, 4) - code(r, 2)
    out("R3_top_span_ratio_c+100", span(rows[(0, 100)]) / span(rows[(0, 0)]),
        f"codes {span(rows[(0, 100)]):.1f} of {span(rows[(0, 0)]):.1f}")
    out("R3_top_span_ratio_c+50", span(rows[(0, 50)]) / span(rows[(0, 0)]))
    # R4: display slope at the pivot (codes per EV over +-0.25 EV)
    sl = lambda r: (code(r, 0.25) - code(r, -0.25)) / 0.5
    out("R4_mid_slope_c+100", sl(rows[(0, 100)]), f"codes/EV (contrast 0: {sl(rows[(0, 0)]):.1f})")
    out("R4_mid_slope_c-100", sl(rows[(0, -100)]), "codes/EV")
    # info: rendered code at the pivot for each pivot (range decision)
    out("R5_info_pivot_codes", 0, " ".join(f"p{p}:{code(rows[(p, 0)], p):.0f}" for p in [-4, -3, -2, 0, 2, 3, 4]))


# ---- colour: C1 hue held, C2 saturation measured honestly ----------------------------
def colour():
    lfi = os.path.join(CORPUS, "synthetic", "colorchecker.lfi")
    truth = json.load(open(lfi[:-4] + ".json"))["truth"]["patches"]
    cs = [-100, -50, 0, 50, 100]
    _, tiles = sweep("checker65", lfi, "develop.tone.contrast", cs, long_edge=1368,
                     extra=["--lut-size", "65"])
    ims = {c: load(tiles[c]) for c in cs}
    s = ims[0].shape[1] / 1368
    stats = {c: [] for c in cs}
    for p in truth[:18]:
        x0, y0, w, h = p["rect"]
        ys = slice(int((y0 + 30) * s), int((y0 + h - 30) * s))
        xs = slice(int((x0 + 30) * s), int((x0 + w - 30) * s))
        for c in cs:
            stats[c].append(oklch(ims[c][ys, xs].reshape(-1, 3).mean(0)))
    base = stats[0]
    chrom = [i for i, v in enumerate(base) if v[1] > 0.04]
    worst_mean, worst_max = 0.0, 0.0
    for c in (-100, -50, 50, 100):
        dh = [abs(hdiff(stats[c][i][2], base[i][2])) for i in chrom]
        worst_mean, worst_max = max(worst_mean, np.mean(dh)), max(worst_max, np.max(dh))
    out("C1_hue_mean_abs_deg", worst_mean, f"worst over +-50,+-100, {len(chrom)} chromatic patches, 65 table")
    out("C1_hue_max_abs_deg", worst_max)
    for c in (100, 50, -100):
        sat = np.mean([100 * ((stats[c][i][1] / stats[c][i][0]) / (base[i][1] / base[i][0]) - 1) for i in chrom])
        dC = np.mean([100 * (stats[c][i][1] / base[i][1] - 1) for i in chrom])
        out(f"C2_sat_CL_pct_c{c:+d}", sat, f"mean OKLab C/L change; abs chroma {dC:+.1f}%")


# ---- photos: P1 shadow crush, P2 highlight clip, P3 smoothness, P4 symmetry, P5 identity
def photos():
    L = lambda pid: os.path.join(CORPUS, "lfi", PHOTOS[pid] + ".lfi")
    for pid in ("1346", "4694", "2348"):
        m, _ = sweep(f"crush_{pid}", L(pid), "develop.tone.contrast", [0, 100], dither=True)
        a = tile_metric(m, 0)["clipping"]["shadowsPct"]["any"]
        b = tile_metric(m, 100)["clipping"]["shadowsPct"]["any"]
        out(f"P1_code0_pct_c+100_{pid}", b, f"% pixels with a channel at code 0 (contrast 0: {a:.3f}%)")
    m, _ = sweep("clip_983_e1.5", L("983"), "develop.tone.contrast", [0, 100], dither=True,
                 sets=["develop.tone.exposure=1.5"])
    out("P2_code255_pct_983_exp+1.5_c+100", tile_metric(m, 100)["clipping"]["highlightsPct"]["any"],
        f"(contrast 0: {tile_metric(m, 0)['clipping']['highlightsPct']['any']:.3f}%)")
    vals = list(range(-100, 101, 10))
    for pid in ("6929", "2545"):
        _, tiles = sweep(f"steps_{pid}", L(pid), "develop.tone.contrast", vals, long_edge=1024)
        Y, CL = [], []
        for v in vals:
            a = load(tiles[v])
            Y.append(a @ [0.2126, 0.7152, 0.0722])
            Lk, Ck, _ = oklch(a[::4, ::4])
            CL.append(float((Ck / np.maximum(Lk, 1e-3)).mean()))
        step = np.array([np.abs(Y[i] - Y[i - 1]).mean() for i in range(1, len(vals))])
        rms = np.array([y.std() for y in Y])
        adj = step[1:] / step[:-1]
        out(f"P3_step_ratio_{pid}", step.max() / step.min(),
            f"max/min per-10 mean|dLuma| ({step.max():.2f}/{step.min():.2f})")
        out(f"P3_adjacent_step_ratio_{pid}", max(adj.max(), 1 / adj.min()),
            "worst neighbouring-step ratio (>=1)")
        out(f"P3_rms_nonincreasing_{pid}", int((np.diff(rms) <= 0).sum()),
            f"RMS luma -100/0/+100: {rms[0]:.1f}/{rms[10]:.1f}/{rms[20]:.1f}")
        out(f"P4_sym_100_{pid}", (rms[20] - rms[10]) / (rms[10] - rms[0]), "dRMS(+100)/|dRMS(-100)|")
        out(f"P4_sym_50_{pid}", (rms[15] - rms[10]) / (rms[10] - rms[5]), "dRMS(+50)/|dRMS(-50)|")
        out(f"C2_photo_CL_change_pct_{pid}", 100 * max(abs(CL[0] / CL[10] - 1), abs(CL[20] / CL[10] - 1)),
            f"mean C/L at -100/0/+100: {CL[0]:.4f}/{CL[10]:.4f}/{CL[20]:.4f}")
    # P5: contrast 0 is the default render byte for byte, at any pivot
    d = os.path.join(WORK, f"identity_{STAMP}"); os.makedirs(d, exist_ok=True)
    ref = os.path.join(d, "default.png")
    common = ["--input", L("6929"), "--long-edge", "1024"] + sidecar(L("6929"))
    if not os.path.exists(ref):
        subprocess.run([BIN, "render"] + common + ["--out", ref], check=True, stdout=subprocess.DEVNULL)
    diff = 0
    for p in (-4, -1.3, 2.37, 4):
        f = os.path.join(d, f"p{p}.png")
        if not os.path.exists(f):
            subprocess.run([BIN, "render"] + common + ["--set", "develop.tone.contrast=0",
                           "--set", f"develop.tone.contrastPivot={p}", "--out", f],
                           check=True, stdout=subprocess.DEVNULL)
        diff += int(open(f, "rb").read() != open(ref, "rb").read())
    out("P5_identity_png_mismatches", diff, "6929, contrast 0 at pivots -4,-1.3,2.37,4 vs default recipe")


if __name__ == "__main__":
    os.makedirs(WORK, exist_ok=True)
    if WHAT in ("ramp", "all"):
        ramp()
    if WHAT in ("colour", "all"):
        colour()
    if WHAT in ("photos", "all"):
        photos()
