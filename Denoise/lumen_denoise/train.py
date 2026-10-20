"""Fine-tune / train the raw denoiser on own-camera ground truth + calibrated synthetic noise.

python -m lumen_denoise.train --gt data/gt --val data/gt_val --calib data/calib.json \
    --out runs/x [--init weights.pt] [--iters 8000] [--nf 32]

Every option below defaults to the B4 recipe (same model, noise, sampling, loss, RNG draws):
  --noise-ext SPEC        richer synthetic noise (noise_ext.py): row,col,gain,fpn,hot,quant,dualgain,heavy|all
  --noise-ext-params J    calibrate_rows.py JSON (absolute magnitudes); without it literature-scale defaults
  --val-noise-ext SPEC    noise used by validation ("" = plain Poisson-Gaussian, comparable to B4)
  --val-isos A,B,..       validation ISOs; best.pt = highest MEAN tone-PSNR over these (per-ISO values logged)
  --loss SPEC             losses.make_loss, e.g. base,fft:0.05,grad:0.1 ("base" = loss_fn)
  --iso-sampling MODE     loguniform | high[:f] | bands:w1,.. | adaptive (per-octave loss feedback)
  --arch unet|nafnet      backbone (+ --nafnet-*), nafnet is residual / noise-unit like --residual UNet
  --ema D                 EMA weights (0 = off); validation + best.pt/last.pt then use the EMA weights
  --selfsup r2r|n2n       self-supervised term on REAL noisy crops (--real, prepare_real.py), see selfsup.py
Crash / pause safety: <out>/ckpt.pt (net, opt, sched, EMA, step, best, RNGs, ISO sampler) is written
every --ckpt-every steps, at each validation and on SIGTERM / SIGINT / SIGUSR1 (`kill -USR1 <pid>`
= pause: save and exit). Rerun the SAME command with --resume to continue. If ckpt.pt exists and
neither --resume nor --fresh is given the run refuses to start, so nothing is overwritten by accident.
"""
import argparse, contextlib, json, math, random, time
from pathlib import Path
import numpy as np
import torch
import torch.nn.functional as F
from .model import Denoiser

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
CAM_WEIGHTS = {"ILCE-7M4": 0.7, "DMC-GX85": 0.3}
VAL_ISOS = (400, 1600, 6400, 25600)


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
        self.iso_mode, self.iso_state = "loguniform", None  # losses.sample_iso mode / AdaptiveIsoSampler
        self.noise_opts, self.noise_params = None, None     # noise_ext.NoiseOpts / ExtParams (None = add_noise)
        self.last_iso, self.last_model = [], []             # per-sample ISO / camera of the last batch
        self.files = sorted(Path(gt_dir).glob("*.npy"))
        self.meta = meta  # stem -> camera model
        self.arr = [np.load(f, mmap_mode="r") for f in self.files]

    def batch(self, n, ps, table):
        xs, ys, ks, rs, isos, models = [], [], [], [], [], []
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
            if self.iso_mode == "loguniform":
                iso = math.exp(random.uniform(math.log(max(lo, self.iso_min)), math.log(hi)))
            else:
                from .losses import sample_iso
                iso = sample_iso(max(lo, self.iso_min), hi, self.iso_mode, random, self.iso_state)
            K, r = table.params(model, iso)
            K *= random.uniform(0.85, 1.15); r *= math.exp(random.uniform(math.log(0.5), math.log(2.0)))
            if random.random() < self.star_p:
                c = add_stars(c, K, r)
            ys.append(c); ks.append(K); rs.append(r); isos.append(iso); models.append(model)
        y = torch.stack(ys).to(DEV)
        K = torch.tensor(ks, device=DEV).view(-1, 1, 1, 1)
        r = torch.tensor(rs, device=DEV).view(-1, 1, 1, 1)
        self.last_iso, self.last_model = isos, models
        o = self.noise_opts
        if o is not None and o.any():
            from .noise_ext import add_noise_ext
            x = add_noise_ext(y, K, r, isos, models, o, self.noise_params).clamp(max=1)
        else:
            x = add_noise(y, K, r).clamp(max=1)  # sensor clips at white like a real raw
        return x, y, K, r


_ID_BUFFERS = ("arch_code", "arch_cfg", "residual_flag")


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
        if key not in own or key in _ID_BUFFERS:  # identity buffers describe THIS net (else best.pt
            continue                              # would carry the init's arch_cfg / tlc to infer.py)
        o = own[key]
        if (v.shape != o.shape and v.dim() == 4 and v.shape[0] == o.shape[0] and v.shape[2:] == o.shape[2:]
                and v.shape[1] < o.shape[1]):
            w = torch.zeros_like(o); w[:, : v.shape[1]] = v; v = w
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
def validate(net, val, table, isos=VAL_ISOS, ps=512, noise=None):
    """Seeded tone-PSNR per ISO on centre crops. noise=(NoiseOpts, ExtParams) validates against the
    richer noise instead; None (default) = plain Poisson-Gaussian, the protocol B4 was measured with."""
    net.eval()
    g = torch.Generator().manual_seed(0)
    out = {}
    for iso in isos:
        vals = []
        for i, a in enumerate(val.arr):
            _, h, w = a.shape
            c = torch.from_numpy(np.array(a[:, (h - ps) // 2:(h + ps) // 2, (w - ps) // 2:(w + ps) // 2], np.float32))[None]
            model = val.meta[val.files[i].stem]
            vi = min(iso, table.iso_range(model)[1])
            K, r = table.params(model, vi)
            torch.manual_seed(i + iso)
            if noise is not None and noise[0].any():
                from .noise_ext import add_noise_ext
                x = add_noise_ext(c, torch.full((1, 1, 1, 1), K), torch.full((1, 1, 1, 1), r), [vi], [model],
                                  noise[0], noise[1]).clamp(max=1).to(DEV)
            else:
                x = add_noise(c, K, r).to(DEV)
            c = c.to(DEV)
            y = net(x, std_map(x, K, r))
            vals.append(psnr(tone(y), tone(c)))
        out[iso] = float(np.mean(vals))
    net.train()
    return out


def _ints(s):
    return tuple(int(v) for v in s.split(",") if v.strip())


def build_net(a):
    if a.arch == "unet":
        return Denoiser(nf=a.nf, residual=a.residual, zero_init=not a.no_zero_init)
    kw = dict(preset=a.nafnet_preset, tlc=a.ps if a.nafnet_tlc is None else a.nafnet_tlc)
    if a.nafnet_width: kw["width"] = a.nafnet_width
    if a.nafnet_enc: kw["enc"] = _ints(a.nafnet_enc)
    if a.nafnet_dec: kw["dec"] = _ints(a.nafnet_dec)
    if a.nafnet_middle is not None: kw["middle"] = a.nafnet_middle
    return Denoiser(residual=True, zero_init=not a.no_zero_init, arch="nafnet", **kw)


def parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
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
    ap.add_argument("--seed", type=int, default=None, help="seed python/numpy/torch RNGs (default: unseeded, as before)")
    g = ap.add_argument_group("validation")
    g.add_argument("--val-isos", default=",".join(map(str, VAL_ISOS)), help="best.pt = max mean tone-PSNR over these")
    g.add_argument("--val-ps", type=int, default=512)
    g.add_argument("--val-every", type=int, default=1000)
    g.add_argument("--val-noise-ext", default="", help="noise_ext spec for validation ('' = B4 protocol)")
    g = ap.add_argument_group("noise model (noise_ext.py)")
    g.add_argument("--noise-ext", default="", help="row,col,gain,fpn,hot,quant,dualgain,heavy | all | '' (off)")
    g.add_argument("--noise-ext-params", default=None, help="calibrate_rows.py JSON (data/noise_ext.json)")
    g.add_argument("--noise-ext-jitter", type=float, default=1.5)
    g = ap.add_argument_group("loss / ISO sampling (losses.py)")
    g.add_argument("--loss", default="base", help="e.g. base,fft:0.05,grad:0.1 | charb | base,nw:0.5 | base,perc:0.01")
    g.add_argument("--iso-sampling", "--iso-mode", dest="iso_sampling", default="loguniform",
                   help="loguniform | high[:f] | bands:w1,w2,.. | adaptive")
    g.add_argument("--iso-adapt-floor", type=float, default=0.3)
    g.add_argument("--iso-adapt-target", default=None, help="JSON list (or file) of per-octave target losses")
    g = ap.add_argument_group("architecture (model.py / nafnet.py)")
    g.add_argument("--arch", choices=("unet", "nafnet"), default="unet")
    g.add_argument("--nafnet-preset", choices=("s", "m", "l"), default="s",
                   help="s fits the <10 s/33 MP budget; time m with speedcheck.py before a long run")
    g.add_argument("--nafnet-width", type=int, default=None)
    g.add_argument("--nafnet-enc", default=None, help='blocks per level, e.g. "1,1,2,4"')
    g.add_argument("--nafnet-dec", default=None, help='blocks per level (0 = full res), e.g. "1,1,1,1"')
    g.add_argument("--nafnet-middle", type=int, default=None)
    g.add_argument("--nafnet-tlc", type=int, default=None, help="eval SCA window (default --ps; 0 = global)")
    g = ap.add_argument_group("EMA / checkpoints (ckpt.py)")
    g.add_argument("--ema", type=float, default=0.0, help="EMA decay, e.g. 0.999 (0 = off)")
    g.add_argument("--ema-no-warmup", action="store_true")
    g.add_argument("--resume", action="store_true", help="continue from <out>/ckpt.pt if it exists")
    g.add_argument("--fresh", action="store_true", help="ignore an existing ckpt.pt (kept as ckpt.prev.pt)")
    g.add_argument("--ckpt-every", type=int, default=250, help="full-state checkpoint interval (0 = only at val)")
    g.add_argument("--stop-after", type=int, default=0, help="checkpoint and exit after N steps of THIS session (train in sessions; rerun with --resume)")
    g = ap.add_argument_group("self-supervised real-photo term (selfsup.py)")
    g.add_argument("--selfsup", "--ss-mode", dest="selfsup", choices=("off", "r2r", "n2n"), default="off")
    g.add_argument("--real", default=None, help="dir of real noisy crops (prepare_real.py)")
    g.add_argument("--real-meta", default=None, help="default <real>/real_meta.json")
    g.add_argument("--real-val", default=None, help="held-out real crops: logs real_excess at each validation")
    g.add_argument("--real-val-n", type=int, default=64)
    g.add_argument("--selfsup-weight", type=float, default=0.3)
    g.add_argument("--selfsup-every", type=int, default=1, help="add the real-batch term every N steps")
    g.add_argument("--selfsup-start", type=int, default=0, help="first step with the term")
    g.add_argument("--selfsup-ramp", type=int, default=0, help="linear weight ramp-in steps after --selfsup-start")
    g.add_argument("--selfsup-bs", type=int, default=4)
    g.add_argument("--selfsup-ps", type=int, default=None, help="default --ps (n2n: multiple of 32)")
    g.add_argument("--selfsup-alpha", type=float, default=0.5)
    g.add_argument("--selfsup-gamma", type=float, default=1.0)
    g.add_argument("--selfsup-gamma-ramp", type=int, default=1000)
    g.add_argument("--selfsup-pairs", choices=("vert", "diag", "any"), default="vert")
    g.add_argument("--selfsup-norm", choices=("std", "var"), default="std")
    g.add_argument("--selfsup-iso-min", type=float, default=6400)
    return ap


# args that must match for a resume to make sense (shapes / schedule)
_RESUME_KEYS = ("iters", "lr", "arch", "nf", "residual", "nafnet_preset", "nafnet_width", "nafnet_enc",
                "nafnet_dec", "nafnet_middle")


def main(argv=None):
    a = parser().parse_args(argv)
    from . import ckpt as C
    torch.set_num_threads(2)  # leave the CPU to the user
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    ck_path = out / "ckpt.pt"
    resume = a.resume and ck_path.exists()
    if ck_path.exists() and not a.resume:
        if not a.fresh:
            raise SystemExit(f"{ck_path} exists: pass --resume to continue that run or --fresh to start over")
        ck_path.replace(out / "ckpt.prev.pt")
    if a.seed is not None:
        random.seed(a.seed); np.random.seed(a.seed); torch.manual_seed(a.seed)
    meta, table = json.load(open(a.meta)), NoiseTable(a.calib)
    tr, val = Data(a.gt, meta, mix=True), Data(a.val, meta)
    tr.iso_min = a.iso_min; tr.star_p = a.stars
    from .noise_ext import NoiseOpts, ExtParams
    nopts, vopts = NoiseOpts.parse(a.noise_ext), NoiseOpts.parse(a.val_noise_ext)
    if nopts.any() or vopts.any():
        P = ExtParams.load(a.noise_ext_params, calib=json.load(open(a.calib)), jitter=a.noise_ext_jitter)
        tr.noise_opts, tr.noise_params = nopts, P
    val_noise = (vopts, P) if vopts.any() else None
    sampler = None
    if a.iso_sampling != "loguniform":
        from . import losses as L
        L.sample_iso(400, 51200, a.iso_sampling, random.Random(0), L.AdaptiveIsoSampler())  # validate spec early
        tr.iso_mode = a.iso_sampling
        if a.iso_sampling == "adaptive":
            t = a.iso_adapt_target
            tgt = None if not t else (json.loads(t) if t.strip().startswith("[") else json.load(open(t)))
            hi = max(float(table.iso_range(m)[1]) for m in table.t)
            sampler = tr.iso_state = L.AdaptiveIsoSampler(a.iso_min, hi, floor=a.iso_adapt_floor, target=tgt)
    if a.loss == "base":
        crit = None  # loss_fn itself: no per-step .item() sync
    else:
        from . import losses as L
        crit = L.make_loss(a.loss)
    real = real_val = None
    if a.selfsup != "off":
        from . import selfsup as S
        assert a.real, "--selfsup needs --real DIR (python -m lumen_denoise.prepare_real ...)"
        ss_ps = a.selfsup_ps or a.ps
        assert a.selfsup != "n2n" or ss_ps % 32 == 0, "n2n: --selfsup-ps must be a multiple of 32"
        real = S.RealData(a.real, a.real_meta or Path(a.real) / "real_meta.json", device=DEV, iso_min=a.selfsup_iso_min)
        if a.real_val:
            real_val = S.RealData(a.real_val, Path(a.real_val) / "real_meta.json", device=DEV, iso_min=a.selfsup_iso_min)
    val_isos = _ints(a.val_isos)

    net = build_net(a).to(DEV)
    if a.init and not resume:
        msg = load_init(net, a.init); print("init:", msg)
        if int(msg.split("/")[0]) == 0:  # identity buffers are never counted (load_init skips them)
            raise SystemExit(f"--init {a.init}: no tensor matches this --arch/--nf (UNet weights can't seed NAFNet)")
    opt = torch.optim.AdamW(net.parameters(), a.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, a.lr, total_steps=a.iters, pct_start=0.05)
    ema = C.EMA(net, a.ema, warmup=not a.ema_no_warmup) if a.ema > 0 else None
    best, start = -1, 1
    if resume:
        cfg0 = {k: b.clone() for k, b in net.named_buffers() if k in _ID_BUFFERS}
        st = C.load_ckpt(ck_path, net=net, opt=opt, sched=sched, ema=ema)  # cpu: Adam 'step' must stay
        # on CPU (load_state_dict leaves it where loaded; on MPS each step would .item()-sync per param)
        old = (st["extra"] or {}).get("args", {})
        bad = {k: (old[k], getattr(a, k)) for k in _RESUME_KEYS if k in old and old[k] != getattr(a, k)}
        bad.update({k: (b.tolist(), cfg0[k].tolist()) for k, b in net.named_buffers()  # e.g. --ps / --nafnet-tlc
                    if k in cfg0 and not torch.equal(b, cfg0[k])})                     # changed the SCA window
        if bad:
            raise SystemExit(f"--resume with different settings {bad}: use the original command (or --fresh)")
        if sampler is not None and (st["extra"] or {}).get("sampler"):
            sampler.load_state_dict(st["extra"]["sampler"])
        start, best = st["step"] + 1, st["best"]
        print(f"resumed {ck_path} at step {st['step']} (best {best:.3f})", flush=True)
    json.dump(vars(a), open(out / "args.json", "w"), indent=1)
    print(f"noise-ext {nopts} | val-noise-ext {vopts} | loss {a.loss} | iso {a.iso_sampling} | arch {a.arch} "
          f"| ema {a.ema} | selfsup {a.selfsup} | {sum(p.numel() for p in net.parameters()) / 1e6:.2f}M params", flush=True)

    def ema_ctx():
        return ema.swapped(net) if ema is not None else contextlib.nullcontext()

    def save(it):
        C.save_ckpt(ck_path, step=it, net=net, opt=opt, sched=sched, ema=ema, best=best,
                    extra={"args": vars(a), "sampler": sampler.state_dict() if sampler else None})

    t0, log = time.time(), open(out / "log.txt", "a")
    stop = C.install_signal_handlers()
    try:
        if not resume:
            with ema_ctx():
                v = validate(net, val, table, val_isos, a.val_ps, val_noise)
            print("val@0", v, flush=True); log.write(f"0 val {v}\n")
        it = start - 1
        for it in range(start, a.iters + 1):
            ti = time.time()
            x, y, K, r = tr.batch(a.bs, a.ps, table)
            s = std_map(x, K, r)
            pred = net(x, s)
            if crit is None:
                loss, parts = loss_fn(pred, y), {}
            else:
                loss, parts = crit(pred, y, s)
            if real is not None and it >= a.selfsup_start and (it - a.selfsup_start) % a.selfsup_every == 0:
                xr, Kr, rr = real.batch(a.selfsup_bs, a.selfsup_ps or a.ps, table)
                gm = S.gamma_ramp(it, a.selfsup_start, a.selfsup_gamma_ramp, a.selfsup_gamma)
                ls, sp = S.selfsup_loss(net, xr, Kr, rr, mode=a.selfsup, gamma=gm, alpha=a.selfsup_alpha,
                                        pairs=a.selfsup_pairs, norm=a.selfsup_norm, std_fn=std_map)
                w = a.selfsup_weight * (min(1.0, (it - a.selfsup_start + 1) / a.selfsup_ramp) if a.selfsup_ramp else 1.0)
                loss = loss + w * ls
                parts = {**parts, "ss": sp["ss"], "ss_excess": sp["ss_excess"]}
            opt.zero_grad(set_to_none=True); loss.backward()
            torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
            opt.step(); sched.step()
            if ema is not None:
                ema.update(net)
            if sampler is not None:
                from .losses import per_sample_tone_l1
                sampler.update(tr.last_iso, per_sample_tone_l1(pred.detach(), y))
            if a.duty < 1:
                if DEV == "mps":
                    torch.mps.synchronize()  # wait for the GPU so the sleep matches real work
                time.sleep((time.time() - ti) * (1 - a.duty) / a.duty)
            if it % 100 == 0:
                extra = "".join(f" {k}={float(v):.5f}" for k, v in parts.items())
                msg = f"{it} loss {loss.item():.5f} {time.time() - t0:.0f}s{extra}"
                if sampler is not None:
                    msg += " isoP=" + ",".join(f"{p:.2f}" for p in sampler.probs())
                print(msg, flush=True); log.write(msg + "\n"); log.flush()
            if it % a.val_every == 0 or it == a.iters:
                with ema_ctx():
                    v = validate(net, val, table, val_isos, a.val_ps, val_noise)
                    rx = None if real_val is None else S.real_excess(
                        net, real_val, table, n=a.real_val_n, ps=a.selfsup_ps or a.ps, mode=a.selfsup,
                        alpha=a.selfsup_alpha, pairs=a.selfsup_pairs, norm=a.selfsup_norm, std_fn=std_map)
                m = float(np.mean(list(v.values())))
                msg = f"{it} val {v} mean {m:.3f}"
                print(msg, flush=True); log.write(msg + "\n")
                if rx is not None:
                    msg = f"{it} realval excess {rx:.4f}"; print(msg, flush=True); log.write(msg + "\n")
                log.flush()
                C.export_weights(out / "last.pt", ema or net)
                if m > best:
                    best = m; C.export_weights(out / "best.pt", ema or net)
                save(it)
            elif a.ckpt_every and it % a.ckpt_every == 0:
                save(it)
            if stop or (a.stop_after and it - start + 1 >= a.stop_after and it < a.iters):  # steps this session
                save(it); C.export_weights(out / "last.pt", ema or net)
                why = f"signal {stop.signum}" if stop else f"--stop-after {a.stop_after}"
                print(f"stopped at step {it} ({why}); rerun with --resume to continue", flush=True)
                break
    finally:
        stop.restore(); log.close()


if __name__ == "__main__":
    main()
