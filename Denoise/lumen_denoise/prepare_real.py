"""Cut random crops from REAL noisy RAWs for self-supervised fine-tuning (selfsup.py).

python -m lumen_denoise.prepare_real <list.txt> <outdir> [--crops 4 --ps 512 --workers 6]

Unlike prepare.py there is NO downsampling: the noise itself is the training signal and must stay
exactly as the sensor made it. Each crop: float16 .npy (4, ps, ps) RGGB normalized black=0 white=1,
named <stem>_c<k>.npy; meta JSON (default <outdir>/real_meta.json): {crop_stem: {model, iso, frame}}.
Disk: 4*ps*ps*2 B per crop = 2 MiB at ps 512 -> 8 MiB/frame with 4 crops -> ~40 GiB for 5,000
frames (--crops 2: 20 GiB; --ps 384: 4.5 MiB/frame, 22 GiB). Re-runs skip finished frames.
Crops that are mostly clipped or black are rejected (no usable noise statistics: clipped noise is
not zero-mean; pure black teaches only the read floor), except a keep_dark share so night scenes
still contribute.
"""
import argparse, json, random, zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from . import raw
from .prepare import to_rggb


def _box(x, b):
    h, w = x.shape[0] // b * b, x.shape[1] // b * b
    return x[:h, :w].reshape(h // b, b, w // b, b).mean((1, 3))


def crop_ok(c, clip=0.98, max_clip=0.05, dark=0.002, pct=90):
    """(ok, why). Clipped: share of packed px with any channel >= clip. Dark: the pct-th percentile of
    the 8x8-box-mean luminance below `dark` (normalized; ~30 DN on the A7 IV's 14-bit scale)."""
    if (c.max(0) >= clip).mean() > max_clip:
        return False, "clipped"
    if np.percentile(_box(c.mean(0), 8), pct) < dark:
        return False, "dark"
    return True, ""


def pick_crops(p, n, ps, rng, tries=40, keep_dark=0.15, **kw):
    """Up to n non-overlapping-ish random (y0, x0) crop corners of the packed frame p (4,H,W)."""
    _, H, W = p.shape
    if H < ps or W < ps:
        return []
    out = []
    for _ in range(tries):
        if len(out) >= n:
            break
        y0, x0 = rng.randrange(H - ps + 1), rng.randrange(W - ps + 1)
        if any(abs(y0 - a) < ps // 2 and abs(x0 - b) < ps // 2 for a, b in out):
            continue  # mostly overlapping an earlier crop: wasted disk
        ok, why = crop_ok(p[:, y0:y0 + ps, x0:x0 + ps], **kw)
        if ok or (why == "dark" and rng.random() < keep_dark):
            out.append((y0, x0))
    return out


def one(args):
    src, outdir, n, ps = args
    stem = Path(src).stem
    done = sorted(Path(outdir).glob(f"{stem}_c*.npy"))
    if done:
        return stem, None, [f.stem for f in done], 0
    r = raw.load(src)
    p = to_rggb(raw.pack(r.cfa), r.pattern)
    rng = random.Random(zlib.crc32(stem.encode()))  # deterministic per frame
    names, nbytes = [], 0
    for k, (y0, x0) in enumerate(pick_crops(p, n, ps, rng)):
        c = p[:, y0:y0 + ps, x0:x0 + ps].astype(np.float16)
        f = Path(outdir) / f"{stem}_c{k}.npy"
        np.save(f, c); names.append(f.stem); nbytes += f.stat().st_size
    return stem, {"model": r.model, "iso": float(r.iso), "frame": stem}, names, nbytes


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("list"); ap.add_argument("outdir")
    ap.add_argument("--crops", type=int, default=4); ap.add_argument("--ps", type=int, default=512)
    ap.add_argument("--workers", type=int, default=6); ap.add_argument("--meta")
    a = ap.parse_args(argv)
    files = [l.strip() for l in open(a.list) if l.strip()]
    out = Path(a.outdir); out.mkdir(parents=True, exist_ok=True)
    mp = Path(a.meta or out / "real_meta.json")
    meta = json.load(open(mp)) if mp.exists() else {}
    tot, nnew = 0, 0
    jobs = [(f, str(out), a.crops, a.ps) for f in files]
    ex = ProcessPoolExecutor(a.workers) if a.workers > 1 else None
    for i, (stem, m, names, nb) in enumerate((ex.map if ex else map)(one, jobs)):
        if m:
            for s in names:
                meta[s] = m
            tot += nb; nnew += 1
        print(i, stem, len(names), "crops", f"{nb / 2**20:.1f} MiB", flush=True)
        if i % 50 == 0:
            json.dump(meta, open(mp, "w"))
    json.dump(meta, open(mp, "w"), indent=0)
    if nnew:
        per = tot / nnew
        print(f"{per / 2**20:.1f} MiB/frame -> {per * 5000 / 2**30:.1f} GiB per 5,000 frames")
    return meta


if __name__ == "__main__":
    main()
