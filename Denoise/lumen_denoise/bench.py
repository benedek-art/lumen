"""Synthetic benchmark on held-out clean frames: PSNR/SSIM in perceptual (tone) space.

python -m lumen_denoise.bench --val data/gt_val --methods noisy,bm3d,net:runs/x/best.pt
Each method: f(noisy (4,h,w) np.float32, K, r) -> (4,h,w).
"""
import argparse, json, math, time
from pathlib import Path
import numpy as np
import torch
from skimage.metrics import structural_similarity
from .train import NoiseTable, std_map, add_noise, tone, DEV
from .model import Denoiser


def m_noisy(x, K, r):
    return x


def m_bm3d(x, K, r):
    import bm3d
    # generalized Anscombe: Poisson-Gaussian -> unit-variance Gaussian
    a = 2 / K * np.sqrt(np.clip(K * x + 3 / 8 * K * K + r, 0, None))
    out = np.stack([bm3d.bm3d(c, 1.0) for c in a])
    # closed-form approximate inverse (Makitalo-Foi)
    y = (out * K / 2) ** 2 / K - 3 / 8 * K - r / K
    return np.clip(y.astype(np.float32), 0, None)


def m_net(path, nf=32):
    net = Denoiser.from_state_dict(torch.load(path, map_location="cpu")).to(DEV).eval()

    @torch.no_grad()
    def f(x, K, r):
        t = torch.from_numpy(x)[None].to(DEV)
        return net(t, std_map(t, K, r))[0].cpu().numpy()
    return f


def get(name):
    if name == "noisy": return m_noisy
    if name == "bm3d": return m_bm3d
    if name.startswith("net:"):
        p = name[4:].split("@")
        return m_net(p[0], int(p[1]) if len(p) > 1 else 32)
    raise ValueError(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--val", default="data/gt_val"); ap.add_argument("--meta", default="data/gt_meta.json")
    ap.add_argument("--calib", default="data/calib.json")
    ap.add_argument("--methods", default="noisy,bm3d"); ap.add_argument("--isos", default="1600,6400,25600")
    ap.add_argument("--ps", type=int, default=384); ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--out", default="reports/bench.json")
    a = ap.parse_args()
    meta, table = json.load(open(a.meta)), NoiseTable(a.calib)
    files = sorted(Path(a.val).glob("*.npy"))[: a.n or None]
    res = {}
    for name in a.methods.split(","):
        f = get(name)
        res[name] = {}
        for iso in map(int, a.isos.split(",")):
            ps_, ss_, t_ = [], [], 0
            for i, fp in enumerate(files):
                g = np.load(fp, mmap_mode="r")
                _, h, w = g.shape
                c = np.array(g[:, (h - a.ps) // 2:(h + a.ps) // 2, (w - a.ps) // 2:(w + a.ps) // 2], np.float32)
                cam = meta[fp.stem]
                K, r = table.params(cam, min(iso, table.iso_range(cam)[1]))
                torch.manual_seed(i * 7919 + iso)
                x = add_noise(torch.from_numpy(c), K, r).numpy()
                t = time.time(); y = f(x, K, r); t_ += time.time() - t
                ty, tc = tone(torch.from_numpy(y)).numpy(), tone(torch.from_numpy(c)).numpy()
                ps_.append(-10 * math.log10(np.mean((ty - tc) ** 2)))
                ss_.append(np.mean([structural_similarity(ty[k], tc[k], data_range=1.0) for k in range(4)]))
            res[name][iso] = {"psnr": round(float(np.mean(ps_)), 3), "ssim": round(float(np.mean(ss_)), 4),
                              "sec_per_crop": round(t_ / len(files), 3)}
            print(name, iso, res[name][iso], flush=True)
    Path(a.out).parent.mkdir(exist_ok=True)
    old = json.load(open(a.out)) if Path(a.out).exists() else {}
    old.update(res); json.dump(old, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
