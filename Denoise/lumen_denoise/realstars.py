"""Real-star check on a night shot: per detected star, how much peak height and 3x3 flux the
denoiser keeps vs the original. Stars are located on a smoothed copy so noise spikes don't bias it.
python -m lumen_denoise.realstars FILE.ARW --methods bm3d,net:runs/A/best.pt [--box y0,x0,size]"""
import argparse
import numpy as np
from .eval.stars import sky_box, detect_real_stars, measure_real


def load(file, calib, box=""):
    """-> (packed sky crop, K, r, model, iso, y0, x0, s). --box 'y0,x0,size' or darkest-variance 768 box."""
    from . import raw as rawio
    from .prepare import to_rggb
    from .eval.common import NoiseTable  # same log-log interpolation as train.NoiseTable, no torch
    r = rawio.load(file); p = to_rggb(rawio.pack(r.cfa), r.pattern)
    K, rv = NoiseTable(calib).params(r.model, r.iso)
    if box:
        y0, x0, s = map(int, box.split(","))
    else:  # darkest-variance 768px region = sky
        y0, x0, s = sky_box(p, 768)
    return p[:, y0:y0 + s, x0:x0 + s], K, rv, r.model, r.iso, y0, x0, s


def main(argv=None):
    ap = argparse.ArgumentParser(); ap.add_argument("file"); ap.add_argument("--methods", required=True)
    ap.add_argument("--box", default=""); ap.add_argument("--calib", default="data/calib.json")
    a = ap.parse_args(argv)
    from .bench import get
    p, K, rv, model, iso, y0, x0, s = load(a.file, a.calib, a.box)
    ys, xs = detect_real_stars(p, K, rv)
    print(f"{model} ISO{iso:.0f} box {y0},{x0} size {s}: {len(ys)} stars")
    for name in a.methods.split(","):
        f = get(name); hh, ww = (-p.shape[1]) % 16, (-p.shape[2]) % 16
        y = f(np.pad(p, ((0, 0), (0, hh), (0, ww)), mode="reflect"), K, rv)[:, :p.shape[1], :p.shape[2]]
        m = measure_real(p, y, ys, xs)
        print(f"  {name}: flux kept {m['flux_kept']:.2f} (faint half {m['flux_kept_faint']:.2f}), "
              f"peak kept {m['peak_kept']:.2f}, stars lost (<30% flux) {m['lost'] * 100:.0f}%")


if __name__ == "__main__":
    main()
