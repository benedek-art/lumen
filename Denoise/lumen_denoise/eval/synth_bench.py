"""THE synthetic benchmark: clean held-out frames + calibrated Poisson-Gaussian noise, scored per
camera x ISO x region kind (dark / flat / detail / mid / centre) with fixed seeds.

python -m lumen_denoise.eval.synth_bench --methods noisy,wiener,net:runs/A/best.pt [--synthetic]
Falls back to procedural scenes when data/gt_val is missing. Writes JSON + .md, prints the table.
PSNR/SSIM are in common.tone space (same as train.validate); the "centre" region is the same
512 centre crop train.validate scores, so its PSNR column lines up with training logs
(noise realisation differs: numpy seeds here, torch seeds there).
"""
import argparse, json, math, time
from pathlib import Path
import numpy as np
from skimage.metrics import structural_similarity
from . import common
from .regions import pick_regions, cut

ISOS = (400, 1600, 6400, 25600)
# --- release-gate thresholds (tone-space dB unless noted) ---
MIN_MEAN_GAIN_DB = 0.0        # per camera x ISO, mean PSNR must never be below the baseline: a release must not regress
MAX_REGION_LOSS_DB = 0.3      # on any region kind/ISO the model may lose at most this to baseline (~noise of a 2-frame mean)
MAX_CRITICAL_LOSS_DB = 0.15   # stricter for dark/detail: shadow blotches and smeared texture are what users notice first
CRITICAL = ("dark", "detail")
MIN_GAIN_OVER_NOISY_DB = {1600: 1.0, 6400: 3.0, 25600: 5.0}  # must clearly beat doing nothing; even a 5x5 Wiener clears these
MAX_SSIM_DROP = 0.002         # mean SSIM per ISO vs baseline: tiny tolerance, SSIM differences below this are invisible


def psnr(a, b):
    mse = float(np.mean((a - b) ** 2))
    return 99.0 if mse <= 1e-12 else -10 * math.log10(mse)


def ssim(a, b):
    """Mean of per-channel SSIM (Wang et al. 2004, skimage defaults, 7x7 window), data_range=1."""
    w = min(7, *a.shape[1:]); w -= 1 - w % 2  # tiny crops: largest odd window that fits
    if w < 3: return float("nan")
    return float(np.mean([structural_similarity(a[k], b[k], data_range=1.0, win_size=w) for k in range(a.shape[0])]))


def _extra():
    try:
        from .detail import crop_metrics  # written by the detail module; optional
        return crop_metrics
    except (ImportError, AttributeError):
        return None


def run(methods, frames, table, isos=ISOS, regions_per_kind=1, kinds=None, extra=True, log=None):
    """methods: {name: f(noisy, K, r)}. Returns one row per method x frame x region x ISO.
    Noise is generated once per (frame, region, ISO) from common.crop_seed and shared by all methods."""
    xm = _extra() if extra else None
    rows = []
    for fi, fr in enumerate(frames):
        # seed index from the unfiltered list: a region's noise does not depend on the kinds filter
        regs = list(enumerate(pick_regions(fr.clean, n_per_kind=regions_per_kind)))
        if kinds: regs = [(i, g) for i, g in regs if g["kind"] in kinds]
        lo, hi = table.iso_range(fr.camera)
        for ri, reg in regs:
            c = cut(fr.clean, reg)
            tc = common.tone(c)
            for iso in isos:
                ie = float(min(max(iso, lo), hi))
                K, r = table.params(fr.camera, ie)
                x = common.add_noise(c, K, r, common.crop_seed(fi, ri, iso))
                for name, f in methods.items():
                    t = time.time()
                    y = common.run_padded(f, x, K, r)
                    sec = time.time() - t
                    ty = common.tone(y)
                    row = dict(method=name, frame=fr.name, camera=fr.camera, iso=int(iso), iso_eff=ie,
                               region=reg["kind"], y=reg["y"], x=reg["x"], size=reg["size"],
                               psnr=psnr(ty, tc), ssim=ssim(ty, tc), sec=sec)
                    if xm is not None:
                        try:
                            row.update({k: float(v) for k, v in xm(c, x, y, K, r).items()})
                        except Exception as e:  # a broken extra metric must not kill the benchmark
                            row["extra_error"] = repr(e)[:200]; xm = None
                    rows.append(row)
                    if log: log(row)
    return rows


def _mean(rs, k):
    v = [r[k] for r in rs if isinstance(r.get(k), (int, float))]
    return float(np.mean(v)) if v else None


def _metric_keys(rows):
    skip = {"iso", "iso_eff", "y", "x", "size"}
    return [k for k in rows[0] if k not in skip and isinstance(rows[0][k], (int, float))] if rows else []


def summarize(rows):
    """{"by_iso": {method: {camera: {iso: {metric: mean}}}},
        "by_region": {method: {iso: {region: {metric: mean}}}},
        "overall": {method: {iso: {metric: mean}}}}  (means over frames and regions)"""
    keys = _metric_keys(rows)
    out = {"by_iso": {}, "by_region": {}, "overall": {}, "n_rows": len(rows)}
    def agg(rs): return {k: _mean(rs, k) for k in keys} | {"n": len(rs)}
    for m in dict.fromkeys(r["method"] for r in rows):
        rm = [r for r in rows if r["method"] == m]
        isos = sorted({r["iso"] for r in rm})
        out["overall"][m] = {i: agg([r for r in rm if r["iso"] == i]) for i in isos}
        out["by_iso"][m] = {c: {i: agg([r for r in rm if r["camera"] == c and r["iso"] == i])
                                for i in isos if any(r["camera"] == c and r["iso"] == i for r in rm)}
                            for c in dict.fromkeys(r["camera"] for r in rm)}
        out["by_region"][m] = {i: {g: agg([r for r in rm if r["iso"] == i and r["region"] == g])
                                   for g in dict.fromkeys(r["region"] for r in rm if r["iso"] == i)}
                               for i in isos}
    return out


def _f(v, d=2):
    return "-" if v is None else f"{v:.{d}f}"


def to_markdown(summary):
    s, L = summary, []
    methods = list(s["overall"])
    isos = sorted({i for m in methods for i in s["overall"][m]})
    L += ["### Tone PSNR / SSIM per camera x ISO (mean over frames and regions)", "",
          "| method | camera | " + " | ".join(f"ISO {i}" for i in isos) + " |",
          "|---|---|" + "---|" * len(isos)]
    for m in methods:
        for c, d in s["by_iso"][m].items():
            L.append(f"| {m} | {c} | " + " | ".join(
                f"{_f(d[i]['psnr'])} / {_f(d[i]['ssim'], 4)}" if i in d else "-" for i in isos) + " |")
        o = s["overall"][m]
        L.append(f"| {m} | **all** | " + " | ".join(
            f"**{_f(o[i]['psnr'])}** / {_f(o[i]['ssim'], 4)}" if i in o else "-" for i in isos) + " |")
    regs = list(dict.fromkeys(g for m in methods for i in s["by_region"][m] for g in s["by_region"][m][i]))
    L += ["", "### Tone PSNR per region kind", "", "| method | ISO | " + " | ".join(regs) + " |",
          "|---|---|" + "---|" * len(regs)]
    for m in methods:
        for i, d in s["by_region"][m].items():
            L.append(f"| {m} | {i} | " + " | ".join(_f(d[g]["psnr"]) if g in d else "-" for g in regs) + " |")
    extra = [k for k in (next(iter(next(iter(s["overall"].values())).values()), {}) if methods else {})
             if k not in ("psnr", "ssim", "sec", "n")]
    if extra:
        L += ["", "### Extra metrics (mean over cameras/regions)", "",
              "| method | ISO | " + " | ".join(extra) + " |", "|---|---|" + "---|" * len(extra)]
        for m in methods:
            for i, d in s["overall"][m].items():
                L.append(f"| {m} | {i} | " + " | ".join(_f(d.get(k), 4) for k in extra) + " |")
    L += ["", "sec/crop: " + ", ".join(f"{m} {_f(np.mean([d['sec'] for d in s['overall'][m].values()]), 3)}"
                                       for m in methods)]
    return "\n".join(L) + "\n"


# ------------------------------------------------------------------ gate ----
def region_losses(rows, iso, model="model", ref="baseline"):
    """{(camera, region): mean tone-PSNR(model) - mean tone-PSNR(ref)} at one ISO."""
    acc = {}
    for r in rows:
        if r["iso"] == iso and r["method"] in (model, ref):
            acc.setdefault((r["camera"], r["region"]), {}).setdefault(r["method"], []).append(r["psnr"])
    return {k: float(np.mean(v[model]) - np.mean(v[ref])) for k, v in acc.items() if model in v and ref in v}


def gate_checks(model, baseline, ctx):
    C, S = common.Check, "synthetic"
    frames = ctx.frames[:2] if ctx.quick else ctx.frames
    if not frames:
        return [C(S, "synth_bench", None, "frames", "SKIP", "no clean frames")]
    rows = run({"model": model, "baseline": baseline, "noisy": common.m_identity}, frames, ctx.table,
               isos=tuple(ctx.isos), extra=False)
    s = summarize(rows)
    o = s["overall"]
    bc = s["by_iso"]
    def cam_gain(ref, iso):  # worst camera: a gain on the A7 IV must not hide a GX85 regression
        g = {c: bc["model"][c][iso]["psnr"] - bc[ref][c][iso]["psnr"] for c in bc["model"] if iso in bc["model"][c]}
        w = min(g, key=lambda c: g[c])
        return g[w], ", ".join(f"{c} {v:+.2f}" for c, v in g.items())
    out = []
    for iso in sorted(o["model"]):
        g, per = cam_gain("baseline", iso)
        out.append(C(S, f"psnr_gain_vs_baseline@{iso}", round(g, 3), f">= {MIN_MEAN_GAIN_DB:+.2f} dB every camera",
                     common.status(g >= MIN_MEAN_GAIN_DB), f"{ctx.model_name} vs {ctx.baseline_name}: {per}"))
        need = next((v for k, v in sorted(MIN_GAIN_OVER_NOISY_DB.items(), reverse=True) if iso >= k), None)
        gn, per = cam_gain("noisy", iso)
        out.append(C(S, f"psnr_gain_vs_noisy@{iso}", round(gn, 3),
                     f">= {need:+.1f} dB every camera" if need is not None else "info",
                     common.status(gn >= need) if need is not None else "INFO", f"model vs untouched input: {per}"))
        loss = region_losses(rows, iso)  # per (camera, region): pooling cameras lets one body hide the other's loss
        lim = {k: MAX_CRITICAL_LOSS_DB if k[1] in CRITICAL else MAX_REGION_LOSS_DB for k in loss}
        worst = min(loss, key=lambda k: loss[k] + lim[k])  # closest to (or furthest past) its own limit
        out.append(C(S, f"worst_region_vs_baseline@{iso}", round(loss[worst], 3),
                     f">= -{MAX_CRITICAL_LOSS_DB} dB dark/detail, -{MAX_REGION_LOSS_DB} other, every camera",
                     common.status(loss[worst] >= -lim[worst]), f"worst={worst[0]}/{worst[1]} (limit -{lim[worst]})"))
        ds = o["model"][iso]["ssim"] - o["baseline"][iso]["ssim"]
        out.append(C(S, f"ssim_vs_baseline@{iso}", round(ds, 4), f">= -{MAX_SSIM_DROP}",
                     common.status(ds >= -MAX_SSIM_DROP)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--methods", default="noisy,wiener")
    ap.add_argument("--val", default="data/gt_val"); ap.add_argument("--meta", default="data/gt_meta.json")
    ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    ap.add_argument("--isos", default=",".join(map(str, ISOS)))
    ap.add_argument("--synthetic", action="store_true", help="force procedural scenes")
    ap.add_argument("--n", type=int, default=0, help="max frames (0 = all)")
    ap.add_argument("--per-kind", type=int, default=1, help="crops per region kind per frame")
    ap.add_argument("--no-extra", action="store_true", help="skip eval.detail metrics")
    ap.add_argument("--out", default="reports/synth_bench.json")
    a = ap.parse_args()
    table = common.NoiseTable(a.calib)
    frames = common.clean_frames(a.val, a.meta, a.n, True if a.synthetic else None)
    print(f"{len(frames)} frames ({'synthetic' if frames and frames[0].synthetic else 'real held-out'})", flush=True)
    methods = {common.short_name(m): common.get_method(m) for m in a.methods.split(",")}
    rows = run(methods, frames, table, tuple(map(int, a.isos.split(","))), a.per_kind, extra=not a.no_extra)
    s = summarize(rows)
    md = to_markdown(s)
    out = Path(a.out); out.parent.mkdir(parents=True, exist_ok=True)
    json.dump({"methods": a.methods.split(","), "synthetic": bool(frames and frames[0].synthetic),
               "summary": s, "rows": rows}, open(out, "w"), indent=1, default=str)
    out.with_suffix(".md").write_text(md)
    print(md)
    print("wrote", out, out.with_suffix(".md"))


if __name__ == "__main__":
    main()
