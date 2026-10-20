"""Fine-tune / train the raw denoiser on own-camera ground truth + calibrated synthetic noise.

python -m lumen_denoise.train --gt data/gt --val data/gt_val --calib data/calib.json \
    --out runs/x [--init weights.pt] [--iters 8000] [--nf 32]
"""
import argparse, json, math, random, time
from pathlib import Path
import numpy as np
import torch
import torch.nn.functional as F
from .model import Denoiser

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
CAM_WEIGHTS = {"ILCE-7M4": 0.7, "DMC-GX85": 0.3}


class NoiseTable:
    """Per-camera (ISO -> K, read_var), log-log interpolated."""

    def __init__(self, path):
        self.t = {m: np.array(sorted(v)) for m, v in json.load(open(path)).items()}

    def params(self, model, iso):
        a = self.t[model]
        li = np.log(iso)
        K = math.exp(np.interp(li, np.log(a[:, 0]), np.log(a[:, 1])))
        r = math.exp(np.interp(li, np.log(a[:, 0]), np.log(a[:, 2])))
        return K, r

    def iso_range(self, model):
        a = self.t[model]
        return a[0, 0], a[-1, 0]


def std_map(noisy, K, r):
    """Expected noise std per pixel, from the noisy image itself (same at inference)."""
    sig = F.avg_pool2d(noisy.mean(1, keepdim=True).clamp(min=0), 3, 1, 1)
    return torch.sqrt(K * sig + r)


def add_noise(clean, K, r):
    shot = torch.poisson(clean.clamp(min=0) / K) * K
    return shot + torch.randn_like(clean) * torch.as_tensor(r, device=clean.device, dtype=clean.dtype).sqrt()


def tone(x):
    # gamma-ish perceptual space; eps keeps gradients finite at black
    return (x.clamp(min=0) + 1e-3) ** (1 / 2.2)


def loss_fn(pred, gt):
    return F.l1_loss(tone(pred), tone(gt)) + F.l1_loss(pred, gt) * 4


class Data:
    def __init__(self, gt_dir, meta, mix=False):
        self.mix = mix
        self.iso_min = 400
        self.star_p = 0.0
        self.files = sorted(Path(gt_dir).glob("*.npy"))
        self.meta = meta  # stem -> camera model
        self.arr = [np.load(f, mmap_mode="r") for f in self.files]

    def batch(self, n, ps, table):
        xs, ys, ks, rs = [], [], [], []
        for _ in range(n):
            i = random.randrange(len(self.files))
            a = self.arr[i]
            _, h, w = a.shape
            y0, x0 = random.randrange(h - ps), random.randrange(w - ps)
            c = torch.from_numpy(np.array(a[:, y0:y0 + ps, x0:x0 + ps], np.float32))
            if random.random() < 0.5:  # transpose keeps RGGB valid if the two greens swap
                c = c.transpose(1, 2)[[0, 2, 1, 3]]
            c = c * math.exp(random.uniform(math.log(0.15), 0))  # darker scenes / pushed shots
            # scene content is camera-agnostic: apply either camera's noise to any clean scene
            model = random.choices(list(CAM_WEIGHTS), list(CAM_WEIGHTS.values()))[0] if self.mix else self.meta[self.files[i].stem]
            lo, hi = table.iso_range(model)
            iso = math.exp(random.uniform(math.log(max(lo, self.iso_min)), math.log(hi)))
            K, r = table.params(model, iso)
            K *= random.uniform(0.85, 1.15); r *= math.exp(random.uniform(math.log(0.5), math.log(2.0)))
            if random.random() < self.star_p:
                c = add_stars(c, K, r)
            ys.append(c); ks.append(K); rs.append(r)
        y = torch.stack(ys).to(DEV)
        K = torch.tensor(ks, device=DEV).view(-1, 1, 1, 1)
        r = torch.tensor(rs, device=DEV).view(-1, 1, 1, 1)
        x = add_noise(y, K, r).clamp(max=1)  # sensor clips at white like a real raw
        return x, y, K, r


def load_init(net, path):
    """Load our own or published UNetSeeInDark weights (any key prefix); extra input
    channels (noise map) start at zero so pretrained behaviour is preserved."""
    sd = torch.load(path, map_location="cpu", weights_only=False)
    for k in ("state_dict", "model", "netG", "params", "params_ema"):
        if isinstance(sd, dict) and k in sd and isinstance(sd[k], dict):
            sd = sd[k]
    own = net.state_dict()
    out = {}
    for k, v in sd.items():
        k = k.replace("module.", "")
        key = k if k in own else "net." + k
        if key not in own:
            continue
        if v.shape != own[key].shape and v.dim() == 4 and v.shape[1] < own[key].shape[1]:
            w = torch.zeros_like(own[key]); w[:, : v.shape[1]] = v; v = w
        if v.shape == own[key].shape:
            out[key] = v
    net.load_state_dict(out, strict=False)
    return f"{len(out)}/{len(own)} tensors loaded"


def add_stars(c, K, r, n_max=60, ret=False, sigmas=(2.0, 60)):
    """Paint point sources onto a clean packed patch (4,h,w) so the net learns to KEEP them.
    Real stars span several raw px (PSF) and all 4 Bayer channels; noise spikes don't.
    Peak brightness 2.5-60x the local noise std; slight elongation mimics trailing."""
    _, h, w = c.shape
    n = random.randint(5, n_max)
    pos = []
    yy, xx = torch.meshgrid(torch.arange(-5, 6.0), torch.arange(-5, 6.0), indexing="ij")
    for _ in range(n):
        y, x = random.uniform(5, h - 6), random.uniform(5, w - 6)
        iy, ix = int(y), int(x)
        # packed px; real sharp astro frames have stars down to ~0.2 (compact = most at risk)
        sx = math.exp(random.uniform(math.log(0.2), math.log(1.2))); sy = sx * random.uniform(1.0, 2.0)
        th = random.uniform(0, math.pi)
        dx, dy = xx - (x - ix), yy - (y - iy)
        u = dx * math.cos(th) + dy * math.sin(th); v = -dx * math.sin(th) + dy * math.cos(th)
        psf = torch.exp(-0.5 * ((u / sx) ** 2 + (v / sy) ** 2))
        bg = float(c[:, iy, ix].mean().clamp(min=0))
        k = math.exp(random.uniform(math.log(sigmas[0]), math.log(sigmas[1])))
        peak = k * math.sqrt(K * bg + r)
        col = torch.tensor([random.uniform(0.6, 1.4), 1.0, 1.0, random.uniform(0.6, 1.4)]).view(4, 1, 1)
        c[:, iy - 5:iy + 6, ix - 5:ix + 6] += peak * col * psf
        pos.append((iy, ix, k))
    c = c.clamp(max=1)
    return (c, pos) if ret else c


def psnr(a, b):
    return -10 * torch.log10(F.mse_loss(a, b)).item()


@torch.no_grad()
def validate(net, val, table, isos=(400, 1600, 6400, 25600), ps=512):
    net.eval()
    g = torch.Generator().manual_seed(0)
    out = {}
    for iso in isos:
        vals = []
        for i, a in enumerate(val.arr):
            _, h, w = a.shape
            c = torch.from_numpy(np.array(a[:, (h - ps) // 2:(h + ps) // 2, (w - ps) // 2:(w + ps) // 2], np.float32))[None]
            K, r = table.params(val.meta[val.files[i].stem], min(iso, table.iso_range(val.meta[val.files[i].stem])[1]))
            torch.manual_seed(i + iso)
            x = add_noise(c, K, r).to(DEV); c = c.to(DEV)
            y = net(x, std_map(x, K, r))
            vals.append(psnr(tone(y), tone(c)))
        out[iso] = float(np.mean(vals))
    net.train()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt", required=True); ap.add_argument("--val", required=True)
    ap.add_argument("--meta", default="data/gt_meta.json")
    ap.add_argument("--calib", default="data/calib.json")
    ap.add_argument("--out", required=True); ap.add_argument("--init")
    ap.add_argument("--iters", type=int, default=8000); ap.add_argument("--bs", type=int, default=8)
    ap.add_argument("--ps", type=int, default=256); ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--nf", type=int, default=32)
    ap.add_argument("--residual", action="store_true")
    ap.add_argument("--no-zero-init", action="store_true")
    ap.add_argument("--stars", type=float, default=0.0, help="fraction of patches with synthetic stars")
    ap.add_argument("--iso-min", type=float, default=400)
    ap.add_argument("--duty", type=float, default=1.0, help="fraction of time the GPU works (<1 keeps the Mac usable)")
    a = ap.parse_args()
    torch.set_num_threads(2)  # leave the CPU to the user
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    meta, table = json.load(open(a.meta)), NoiseTable(a.calib)
    tr, val = Data(a.gt, meta, mix=True), Data(a.val, meta)
    tr.iso_min = a.iso_min; tr.star_p = a.stars
    net = Denoiser(nf=a.nf, residual=a.residual, zero_init=not a.no_zero_init).to(DEV)
    if a.init:
        print("init:", load_init(net, a.init))
    opt = torch.optim.AdamW(net.parameters(), a.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, a.lr, total_steps=a.iters, pct_start=0.05)
    best, t0, log = -1, time.time(), open(out / "log.txt", "a")
    v = validate(net, val, table); print("val@0", v, flush=True); log.write(f"0 val {v}\n")
    for it in range(1, a.iters + 1):
        ti = time.time()
        x, y, K, r = tr.batch(a.bs, a.ps, table)
        loss = loss_fn(net(x, std_map(x, K, r)), y)
        opt.zero_grad(set_to_none=True); loss.backward()
        torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
        opt.step(); sched.step()
        if a.duty < 1:
            torch.mps.synchronize(); time.sleep((time.time() - ti) * (1 - a.duty) / a.duty)
        if it % 100 == 0:
            msg = f"{it} loss {loss.item():.5f} {time.time() - t0:.0f}s"
            print(msg, flush=True); log.write(msg + "\n"); log.flush()
        if it % 1000 == 0 or it == a.iters:
            v = validate(net, val, table)
            m = float(np.mean(list(v.values())))
            msg = f"{it} val {v} mean {m:.3f}"
            print(msg, flush=True); log.write(msg + "\n"); log.flush()
            torch.save(net.state_dict(), out / "last.pt")
            if m > best:
                best = m; torch.save(net.state_dict(), out / "best.pt")


if __name__ == "__main__":
    main()
