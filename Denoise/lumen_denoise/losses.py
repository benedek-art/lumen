"""Loss options against high-ISO over-smoothing, plus ISO-balanced sampling (all opt-in).

make_loss(spec) -> fn(pred, gt, std=None) -> (loss, parts).  "base" == train.loss_fn exactly.
Spec = comma list of terms, "name" or "name:weight"; base is implicit unless "charb" replaces it:
  base       L1(tone) + 4*L1(linear)                                  (current recipe)
  charb[:e]  Charbonnier sqrt(d^2+e^2) in place of both L1s (tone eps e=1e-3, linear eps e/10).
             Smooth near 0, L1 in the tails; Lai et al. LapSRN / MPRNet use it; ~L1 for PSNR.
  lin:w      weight of the linear L1 term (default 4) - lin:0 = tone-only, more weight on shadows.
  fft:w      L1 of |rFFT| of the tone image per channel (float32). Blur removes high-frequency
             MAGNITUDE while the per-pixel L1 of a blur stays small (errors only at edges), so this
             term penalises over-smoothing more than residual noise (tests/test_losses.py, equal base
             loss on 1/f texture: blur/noise ratio 1.26x vs white residual, 1.7x vs blotchy).
  fftri:w    L1 of rFFT real+imag (= magnitude AND phase), MIMO-UNet "MSFR" style (Cho et al.
             ICCV 2021, lambda=0.1, +0.27 dB GoPro). Phase errors = misplaced edges. By Parseval it
             is ~L1-like for white residual noise; it only singles out blur vs BLOTCHY residuals.
  grad:w     L1 between finite-difference gradients (x and y, per packed channel) in tone space:
             directly rewards keeping edge contrast; zero for a constant offset.
  perc:w     VGG16 relu2_2 feature L1 on a crude half-res sRGB-ish image (perc3: relu3_3).
             Trades PSNR for texture (Johnson 2016; SRGAN vs SRResNet lost ~1-2 dB PSNR at full
             weight) so keep w ~0.005-0.02. torchvision + ImageNet weights load lazily, only here.
  nw:p       per-sample weight (s_i / mean s)^p, s_i = mean noise std of sample i (from `std`),
             normalised to mean 1 per batch. p>0 = more weight on high ISO, p<0 = PSNR-balanced.

Which ISO dominates the current loss (ISO log-uniform 400..51200, 7 octaves):  B4 tone-PSNR falls
~1.9 dB/octave (49.7 @400 -> 38.3 @25600), so the residual error grows ~1.24x per octave (4.6x
from 400 to 51200).  Loss VALUE share of the top two octaves (12800-51200, 28.6% of samples):
45% for L1, 61% for L2 - high ISO already dominates the loss number.  The L1 gradient w.r.t. pred is
sign(d), independent of error size, BUT the residual net works in noise units (pred = noisy +
s*net(x), model.Denoiser), so d loss / d net_out = s*sign(d): per-sample gradients already scale
with the noise std s ~ sqrt(ISO).  Weight 2^(t/2) over t in [0,7] octaves gives the top two octaves
(2^3.5 - 2^2.5)/(2^3.5 - 1) = 55% of the gradient (vs 28.6% of samples) - high ISO is ALREADY
favoured.  The tone term additionally weighs pixels by tone'(x) ~ x^-0.55 (brightness, not ISO).
nw:p multiplies on top of that implicit s^1: nw:0.5 -> effective s^1.5 (top two octaves ~66%),
nw:1 -> s^2 (~76%, low ISO may lose noticeably).  Prefer small exponents (nw:0.25 / nw:0.5) or
sampling (sample_iso "high" / bands / AdaptiveIsoSampler), and run an nw:-0.5 control arm
(effective s^0.5) to check whether the implicit weighting is already too strong.
"""
import math, random
import torch
import torch.nn.functional as F

LIN_W = 4.0


def tone(x):
    # gamma-ish perceptual space; eps keeps gradients finite at black (identical to train.tone)
    return (x.clamp(min=0) + 1e-3) ** (1 / 2.2)


def base_loss(pred, gt):
    return F.l1_loss(tone(pred), tone(gt)) + F.l1_loss(pred, gt) * 4


def _ps(d):
    """Per-sample mean over all but the batch dim."""
    return d.flatten(1).mean(1)


def _charb(d, eps):
    return torch.sqrt(d * d + eps * eps)


def _spec(x):
    """rFFT of (B,C,H,W) in float32 (fft must not run in half; rfft2 works on MPS)."""
    return torch.fft.rfft2(x.float(), norm="ortho")


def fft_mag_term(tp, tg):
    a, b = torch.view_as_real(_spec(tp)), torch.view_as_real(_spec(tg))
    ma = torch.sqrt((a * a).sum(-1) + 1e-12); mb = torch.sqrt((b * b).sum(-1) + 1e-12)  # abs() grad is NaN at 0
    return _ps((ma - mb).abs())


def fft_ri_term(tp, tg):
    return _ps((torch.view_as_real(_spec(tp)) - torch.view_as_real(_spec(tg))).abs())


def grad_term(tp, tg):
    dx = (tp[..., :, 1:] - tp[..., :, :-1]) - (tg[..., :, 1:] - tg[..., :, :-1])
    dy = (tp[..., 1:, :] - tp[..., :-1, :]) - (tg[..., 1:, :] - tg[..., :-1, :])
    return (_ps(dx.abs()) + _ps(dy.abs())) / 2


WB = (2.0, 1.0, 1.6)  # rough daylight R/G/B gains; only so the feature net sees plausible colours
IMNET = ((0.485, 0.456, 0.406), (0.229, 0.224, 0.225))


def packed_rgb(x):
    """(B,4,h,w) RGGB linear -> (B,3,h,w) half-res tone-mapped RGB in [0,1]."""
    rgb = torch.stack([x[:, 0], (x[:, 1] + x[:, 2]) / 2, x[:, 3]], 1).float()
    rgb = rgb * torch.tensor(WB, device=x.device).view(1, 3, 1, 1)
    return tone(rgb.clamp(0, 1))


_VGG = {}


def vgg_features(layer="relu2_2", device="cpu"):
    """Frozen torchvision VGG16 trunk up to `layer` (downloads ImageNet weights once)."""
    key = (layer, str(device))
    if key not in _VGG:
        try:
            from torchvision.models import vgg16, VGG16_Weights
            m = vgg16(weights=VGG16_Weights.IMAGENET1K_V1).features
        except Exception as e:  # missing package or no network for the one-time download
            raise RuntimeError("perc loss needs torchvision + VGG16 ImageNet weights "
                               "(pip install torchvision; first use downloads ~530 MB): %r" % e) from e
        n = {"relu2_2": 9, "relu3_3": 16}[layer]
        net = m[:n].eval().to(device)
        for p in net.parameters():
            p.requires_grad_(False)
        _VGG[key] = net
    return _VGG[key]


def perc_term(pred, gt, net):
    m = torch.tensor(IMNET[0], device=pred.device).view(1, 3, 1, 1)
    s = torch.tensor(IMNET[1], device=pred.device).view(1, 3, 1, 1)
    fp = net((packed_rgb(pred) - m) / s)
    with torch.no_grad():
        fg = net((packed_rgb(gt) - m) / s)
    return _ps((fp - fg).abs())


def noise_weights(std, p, n):
    """(B,) weights (s_i/mean s)^p normalised to mean 1; std: (B,...) tensor or None."""
    if std is None or p == 0:
        return None
    s = std.detach().float().reshape(n, -1).mean(1).clamp(min=1e-12)
    w = (s / s.mean()) ** p
    return w / w.mean()


def parse_spec(spec):
    out = {}
    for tok in [t.strip() for t in (spec or "base").split(",") if t.strip()]:
        k, _, v = tok.partition(":")
        out[k] = float(v) if v else None
    known = {"base", "charb", "lin", "fft", "fftri", "grad", "perc", "perc3", "nw"}
    bad = set(out) - known
    if bad:
        raise ValueError(f"unknown loss term(s) {sorted(bad)}; known: {sorted(known)}")
    return out


def make_loss(spec="base", perc_net=None):
    """Build a loss fn(pred, gt, std=None) -> (loss tensor, parts dict of floats).
    perc_net overrides the VGG trunk (tests / custom features)."""
    t = parse_spec(spec)
    charb = "charb" in t
    eps = (t["charb"] or 1e-3) if charb else None
    lin_w = LIN_W if t.get("lin") is None else t["lin"]
    nw = t.get("nw") or 0.0
    extra = {k: t[k] for k in ("fft", "fftri", "grad", "perc", "perc3") if k in t}
    for k in extra:
        if extra[k] is None:
            raise ValueError(f"loss term {k} needs a weight, e.g. {k}:0.05")
    exact_base = not charb and lin_w == LIN_W and not extra and nw == 0

    def fn(pred, gt, std=None):
        if exact_base:  # bit-identical to train.loss_fn
            loss = base_loss(pred, gt)
            return loss, {"base": loss.item()}
        tp, tg = tone(pred), tone(gt)
        if charb:
            terms = {"tone": _ps(_charb(tp - tg, eps)), "lin": _ps(_charb(pred - gt, eps / 10)) * lin_w}
        else:
            terms = {"tone": _ps((tp - tg).abs()), "lin": _ps((pred - gt).abs()) * lin_w}
        for k, w in extra.items():
            if k == "fft":
                v = fft_mag_term(tp, tg)
            elif k == "fftri":
                v = fft_ri_term(tp, tg)
            elif k == "grad":
                v = grad_term(tp, tg)
            else:
                v = perc_term(pred, gt, perc_net or vgg_features("relu2_2" if k == "perc" else "relu3_3", pred.device))
            terms[k] = v.to(pred.dtype) * w
        per = sum(terms.values())
        wts = noise_weights(std, nw, pred.shape[0])
        loss = (per * wts.to(per.dtype)).mean() if wts is not None else per.mean()
        return loss, {k: v.detach().mean().item() for k, v in terms.items()}

    fn.spec = spec
    return fn


@torch.no_grad()
def per_sample_tone_l1(pred, gt):
    """(B,) detached tone-space L1, the signal to feed AdaptiveIsoSampler.update."""
    return _ps((tone(pred) - tone(gt)).abs()).float().cpu()


# ---------------------------------------------------------------- ISO sampling

def _bands(lo, hi):
    """Octave edges lo*2^k, last band truncated at hi."""
    n = max(1, math.ceil(math.log2(hi / lo) - 1e-9))
    return [(lo * 2 ** k, min(hi, lo * 2 ** (k + 1))) for k in range(n)]


def _logu(rng, lo, hi):
    return math.exp(rng.uniform(math.log(lo), math.log(hi)))


def _from_weights(rng, bands, w):
    w = (list(w) + [w[-1]] * len(bands))[:len(bands)]
    b = rng.choices(range(len(bands)), w)[0]
    return _logu(rng, *bands[b])


def sample_iso(lo, hi, mode="loguniform", rng=random, state=None):
    """Draw one ISO in [lo, hi].
    loguniform      exp(U(log lo, log hi)) - the current recipe, same single rng.uniform draw.
    high[:f]        with prob f (0.5) log-uniform over the top two octaves [hi/4, hi], else full range.
    bands:w1,w2,..  fixed weight per octave starting at lo (missing weights repeat the last one).
    adaptive        delegate to `state` (an AdaptiveIsoSampler)."""
    if mode == "loguniform":
        return _logu(rng, lo, hi)
    name, _, arg = mode.partition(":")
    if name == "high":
        f = float(arg) if arg else 0.5
        return _logu(rng, max(lo, hi / 4), hi) if rng.random() < f else _logu(rng, lo, hi)
    if name == "bands":
        return _from_weights(rng, _bands(lo, hi), [float(v) for v in arg.split(",")])
    if name == "adaptive":
        if state is None:
            raise ValueError("mode 'adaptive' needs state=AdaptiveIsoSampler(...)")
        return state.sample(lo, hi, rng)
    raise ValueError(f"unknown ISO sampling mode {mode!r}")


class AdaptiveIsoSampler:
    """Sample octave bands in proportion to an EMA of their per-sample loss (optionally divided by
    a per-band target, e.g. the loss of the model to beat, so the priority is the GAP), mixed with
    a uniform floor so no band is ever starved.  Bands are absolute octaves of [lo, hi]; a camera
    with a narrower range samples only the bands it overlaps (clipped)."""

    def __init__(self, lo=400, hi=51200, n_bands=None, decay=0.98, floor=0.3, target=None, power=1.0):
        self.lo, self.hi = float(lo), float(hi)
        n = n_bands or len(_bands(lo, hi))
        r = math.log(hi / lo) / n
        self.bands = [(lo * math.exp(r * k), lo * math.exp(r * (k + 1))) for k in range(n)]
        self.decay, self.floor, self.power = decay, floor, power
        self.target = list(target) if target is not None else [1.0] * n
        self.ema = [None] * n
        self.count = [0] * n

    def band(self, iso):
        k = int(math.log(max(iso, self.lo) / self.lo) / math.log(self.hi / self.lo) * len(self.bands))
        return min(max(k, 0), len(self.bands) - 1)

    def update(self, isos, losses):
        """isos, losses: sequences (or tensors) of per-sample ISO and loss/gap values."""
        for iso, l in zip(list(map(float, isos)), list(map(float, losses))):
            k = self.band(iso)
            self.ema[k] = l if self.ema[k] is None else self.decay * self.ema[k] + (1 - self.decay) * l
            self.count[k] += 1

    def probs(self):
        n = len(self.bands)
        seen = [e for e in self.ema if e is not None]
        if not seen:
            return [1.0 / n] * n
        fill = max(seen)  # unseen bands are treated as the hardest so they get explored
        pr = [max((e if e is not None else fill) / t, 0.0) ** self.power for e, t in zip(self.ema, self.target)]
        s = sum(pr) or 1.0
        return [self.floor / n + (1 - self.floor) * p / s for p in pr]

    def sample(self, lo=None, hi=None, rng=random):
        lo = self.lo if lo is None else lo; hi = self.hi if hi is None else hi
        idx = [k for k, (a, b) in enumerate(self.bands) if b > lo and a < hi] or [self.band(hi)]
        p = self.probs()
        k = rng.choices(idx, [p[i] for i in idx])[0]
        a, b = self.bands[k]
        return _logu(rng, max(a, lo), min(b, hi)) if max(a, lo) < min(b, hi) else min(max(a, lo), hi)

    def state_dict(self):
        return {"lo": self.lo, "hi": self.hi, "bands": [list(b) for b in self.bands], "decay": self.decay,
                "floor": self.floor, "power": self.power, "target": list(self.target),
                "ema": list(self.ema), "count": list(self.count)}

    def load_state_dict(self, d):
        self.lo, self.hi = d["lo"], d["hi"]
        self.bands = [tuple(b) for b in d["bands"]]
        self.decay, self.floor, self.power = d["decay"], d["floor"], d["power"]
        self.target, self.ema, self.count = list(d["target"]), list(d["ema"]), list(d["count"])
