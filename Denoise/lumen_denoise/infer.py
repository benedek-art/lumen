"""RAW -> denoised DNG.

python -m lumen_denoise.infer IN.ARW [IN2.RW2 ...] --out DIR [--strength 1.0] [--weights W.pt]
"""
import argparse, json, os, time
from pathlib import Path
import numpy as np
import rawpy
import torch
from . import raw as rawio, noise, dng
from .model import Denoiser
from .prepare import to_rggb, from_rggb
from .train import NoiseTable, std_map

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WEIGHTS = ROOT / "weights" / "lumen_denoise.pt"
DEFAULT_CALIB = ROOT / "weights" / "calib.json"
DEV = "mps" if torch.backends.mps.is_available() else "cpu"


class Engine:
    def __init__(self, weights=DEFAULT_WEIGHTS, calib=DEFAULT_CALIB, nf=None):
        self.net = Denoiser.from_state_dict(torch.load(weights, map_location="cpu")).eval().to(DEV).half()
        self.table = NoiseTable(calib) if Path(calib).exists() else None

    def noise_params(self, r, packed):
        if self.table and r.model in self.table.t:
            lo, hi = self.table.iso_range(r.model)
            return self.table.params(r.model, float(np.clip(r.iso, lo, hi)))
        return noise.estimate(packed)  # unknown camera: measure from the image itself

    @torch.no_grad()
    def denoise_packed(self, p, K, rv, tile=1024, ov=64):
        """p: (4,h,w) float32 RGGB normalized -> same shape, denoised. Feathered tiles."""
        _, h, w = p.shape
        out = np.zeros_like(p); wsum = np.zeros((1, h, w), np.float32)
        step = tile - 2 * ov
        ramp = np.minimum(np.arange(tile) + 1, ov).astype(np.float32) / ov
        for y in range(0, max(h - 2 * ov, 1), step):
            for x in range(0, max(w - 2 * ov, 1), step):
                y0, x0 = min(y, max(h - tile, 0)), min(x, max(w - tile, 0))
                t = p[:, y0:y0 + tile, x0:x0 + tile]
                th, tw = t.shape[1:]
                ph, pw = (-th) % 16, (-tw) % 16
                tt = torch.from_numpy(np.pad(t, ((0, 0), (0, ph), (0, pw)), mode="reflect"))[None].to(DEV).half()
                o = self.net(tt, std_map(tt, K, rv)).float()[0, :, :th, :tw].cpu().numpy()
                wy = np.minimum(ramp[:th], ramp[:th][::-1]) if th == tile else np.ones(th, np.float32)
                wx = np.minimum(ramp[:tw], ramp[:tw][::-1]) if tw == tile else np.ones(tw, np.float32)
                # edges of the full image get full weight (nothing to blend with)
                if y0 == 0: wy[: ov] = 1
                if y0 + th >= h: wy[-ov:] = 1
                if x0 == 0: wx[: ov] = 1
                if x0 + tw >= w: wx[-ov:] = 1
                wt = wy[:, None] * wx[None, :]
                out[:, y0:y0 + th, x0:x0 + tw] += o * wt
                wsum[:, y0:y0 + th, x0:x0 + tw] += wt
        return out / np.maximum(wsum, 1e-6)

    def denoise_file(self, src, out_path, strength=1.0):
        t0 = time.time()
        r = rawio.load(src)
        p = to_rggb(rawio.pack(r.cfa), r.pattern)
        K, rv = self.noise_params(r, p)
        d = self.denoise_packed(p, K, rv)
        d = strength * d + (1 - strength) * p
        cfa = r.cfa.copy()
        h2, w2 = d.shape[1] * 2, d.shape[2] * 2
        cfa[:h2, :w2] = rawio.unpack(from_rggb(d, r.pattern))
        t1 = time.time()
        with rawpy.imread(str(src)) as rr:
            colors = rr.raw_colors_visible
            bl = np.array(rr.black_level_per_channel, np.float32)[colors]
            scale = rr.white_level - np.mean(rr.black_level_per_channel)
            dn = np.clip(np.round(cfa * scale + bl), 0, rr.white_level).astype(np.uint16)
        dng.write_cfa_dng(src, dn, out_path)
        return {"file": str(src), "out": str(out_path), "iso": r.iso, "model": r.model,
                "K": K, "read_sd": rv ** 0.5, "denoise_s": round(t1 - t0, 2), "total_s": round(time.time() - t0, 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+"); ap.add_argument("--out", required=True)
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--weights", default=str(DEFAULT_WEIGHTS)); ap.add_argument("--calib", default=str(DEFAULT_CALIB))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    eng = Engine(a.weights, a.calib)
    for f in a.inputs:
        out = Path(a.out) / (Path(f).stem + "-Denoised.dng")
        if os.path.abspath(out).startswith("/Volumes/Offload Drive"):
            raise SystemExit("refusing to write onto the Offload Drive")
        print(json.dumps(eng.denoise_file(f, out, a.strength)), flush=True)


if __name__ == "__main__":
    main()
