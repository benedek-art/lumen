import math, random
import pytest
import torch
import torch.nn as nn
import torch.nn.functional as F
from lumen_denoise import losses as L
from lumen_denoise import train


def _pair(b=2, h=32, w=32, seed=0):
    g = torch.Generator().manual_seed(seed)
    gt = torch.rand(b, 4, h, w, generator=g) * 0.5
    pred = (gt + 0.02 * torch.randn(b, 4, h, w, generator=g)).clamp(min=0)
    return pred, gt


def _blur(x):
    k = torch.ones(4, 1, 5, 5) / 25
    return F.conv2d(F.pad(x, (2, 2, 2, 2), mode="reflect"), k, groups=4)


def _stub_net():
    torch.manual_seed(0)
    return nn.Sequential(nn.Conv2d(3, 8, 3, padding=1), nn.ReLU(), nn.Conv2d(8, 8, 3, padding=1), nn.ReLU())


def test_tone_and_base_match_train():
    pred, gt = _pair()
    assert torch.equal(L.tone(pred), train.tone(pred))
    ref = F.l1_loss((pred.clamp(min=0) + 1e-3) ** (1 / 2.2), (gt.clamp(min=0) + 1e-3) ** (1 / 2.2)) + 4 * F.l1_loss(pred, gt)
    l, parts = L.make_loss("base")(pred, gt)
    assert torch.equal(l, train.loss_fn(pred, gt)) and torch.allclose(l, ref)
    assert set(parts) == {"base"}
    # the per-sample path (used once any extra term is on) agrees with base when extras are 0
    l2, _ = L.make_loss("base,grad:0")(pred, gt)
    assert torch.allclose(l, l2, rtol=1e-6)


@pytest.mark.parametrize("spec", ["fft:1", "fftri:1", "grad:1", "charb", "lin:0", "base,nw:1", "perc:1"])
def test_terms_zero_positive_differentiable(spec):
    fn = L.make_loss(spec, perc_net=_stub_net())
    pred, gt = _pair()
    std = torch.rand(2, 1, 32, 32) + 0.1
    term = spec.split(":")[0].split(",")[-1]
    l0, p0 = fn(gt.clone(), gt, std)
    if term in ("fft", "fftri", "grad", "perc"):
        assert p0[term] < 1e-5
    if term != "charb":  # charbonnier has a floor of eps at d=0
        assert l0.item() < 1e-5
    p = pred.clone().requires_grad_(True)
    l, parts = fn(p, gt, std)
    assert l.item() > l0.item()
    if term in parts and term != "lin":  # lin:0 is legitimately 0
        assert parts[term] > 0
    l.backward()
    assert p.grad is not None and torch.isfinite(p.grad).all() and p.grad.abs().sum() > 0


def _pink(b=2, n=64, a=1.0, seed=1):
    """1/f^a texture: natural-image-like spectrum, so blur removes real high-frequency content."""
    g = torch.Generator().manual_seed(seed)
    f = torch.fft.fftfreq(n); r = torch.sqrt(f[:, None] ** 2 + f[None, :] ** 2); r[0, 0] = 1
    z = torch.fft.ifft2(torch.complex(torch.randn(b, 4, n, n, generator=g), torch.randn(b, 4, n, n, generator=g)) / r ** a).real
    z = z - z.amin((2, 3), keepdim=True)
    return z / z.amax((2, 3), keepdim=True) * 0.4 + 0.02


def _match_base(gt, n, target):
    """Scale residual n so base_loss(gt + s*n) == target (bisection)."""
    lo, hi = 0.0, 1.0
    for _ in range(50):
        s = (lo + hi) / 2
        if L.base_loss((gt + s * n).clamp(min=0), gt).item() < target: lo = s
        else: hi = s
    return (gt + s * n).clamp(min=0)


def test_fft_and_grad_penalise_blur_more_than_noise():
    """Anti-oversmoothing: an over-smoothed prediction and a noisy one with EQUAL base loss;
    the ratio term/base is larger for the blur, so adding the term tips training toward detail.
    Measured: fft-mag 1.26x (white residual) / 1.7x (blotchy residual); grad 1.4x and fftri 1.2x
    for blotchy residual (what a denoiser actually leaves), ~0.9x for white (Parseval: fftri ~ L1)."""
    gt = _pink()
    blur = _blur(gt)
    b = L.base_loss(blur, gt).item()
    torch.manual_seed(2)
    white = _match_base(gt, torch.randn_like(gt), b)
    blotch = _match_base(gt, F.avg_pool2d(F.pad(torch.randn_like(gt), (1, 1, 1, 1), mode="reflect"), 3, 1), b)
    for x in (white, blotch):
        assert abs(L.base_loss(x, gt).item() - b) / b < 1e-3
    sel = {}
    for term in ("fft", "fftri", "grad"):
        fn = L.make_loss(f"{term}:1")
        tb = fn(blur, gt)[1][term]
        sel[term] = (tb / fn(white, gt)[1][term], tb / fn(blotch, gt)[1][term])
    assert sel["fft"][0] > 1.15 and sel["fft"][1] > 1.5, sel
    assert sel["grad"][1] > 1.2 and sel["fftri"][1] > 1.1, sel
    # end to end: with fft on, the blurred prediction now costs more than the noisy one
    fn = L.make_loss("base,fft:0.5")
    assert fn(blur, gt)[0] > fn(white, gt)[0]


def test_fft_half_input_runs_float32():
    pred, gt = _pair()
    l, _ = L.make_loss("fft:0.1,grad:0.1")(pred.half().float(), gt)
    assert l.dtype == torch.float32
    assert L._spec(pred.half()).dtype == torch.complex64


def test_noise_weighting_upweights_high_iso():
    gt = torch.full((2, 4, 16, 16), 0.2)
    pred = gt + 0.01  # identical error for both samples
    std = torch.tensor([0.001, 0.004]).view(2, 1, 1, 1).expand(2, 1, 16, 16)
    w = L.noise_weights(std, 1.0, 2)
    assert torch.allclose(w, torch.tensor([0.4, 1.6])) and abs(w.mean().item() - 1) < 1e-6
    p = pred.clone().requires_grad_(True)
    L.make_loss("nw:1")(p, gt, std)[0].backward()
    g = p.grad.abs().flatten(1).sum(1)
    assert g[1] / g[0] == pytest.approx(4.0, rel=1e-4)
    assert torch.allclose(L.make_loss("nw:1")(pred, gt, None)[0], L.make_loss("lin:4")(pred, gt)[0])


def test_spec_errors():
    with pytest.raises(ValueError):
        L.make_loss("fft")
    with pytest.raises(ValueError):
        L.make_loss("bogus:1")


def test_perc_requires_torchvision_or_stub():
    fn = L.make_loss("perc:0.01", perc_net=_stub_net())
    pred, gt = _pair()
    assert fn(pred, gt)[1]["perc"] > 0
    try:
        import torchvision  # noqa: F401
    except ImportError:
        with pytest.raises(RuntimeError, match="torchvision"):
            L.make_loss("perc:0.01")(pred, gt)


def test_perc_with_torchvision_vgg_shape():
    tv = pytest.importorskip("torchvision")
    net = tv.models.vgg16(weights=None).features[:9].eval()  # random init: no download in tests
    pred, gt = _pair()
    assert L.perc_term(pred, gt, net).shape == (2,)


def test_packed_rgb():
    x = torch.rand(1, 4, 8, 8)
    rgb = L.packed_rgb(x)
    assert rgb.shape == (1, 3, 8, 8) and rgb.min() >= 0 and rgb.max() <= 1.01


# ---------------------------------------------------------------- ISO sampling

def test_loguniform_matches_current_recipe():
    lo, hi = 400, 51200
    r1, r2 = random.Random(5), random.Random(5)
    a = [L.sample_iso(lo, hi, "loguniform", r1) for _ in range(200)]
    b = [math.exp(r2.uniform(math.log(lo), math.log(hi))) for _ in range(200)]
    assert a == b


def _top2(xs, hi):
    return sum(x >= hi / 4 for x in xs) / len(xs)


def test_high_mode_mass():
    rng = random.Random(0)
    xs = [L.sample_iso(400, 51200, "high", rng) for _ in range(20000)]
    assert all(400 <= x <= 51200 for x in xs)
    assert _top2(xs, 51200) >= 0.5  # 0.5 + 0.5 * 2/7 = 0.64 expected
    assert _top2(xs, 51200) == pytest.approx(0.5 + 0.5 * 2 / 7, abs=0.02)


def test_bands_mode():
    rng = random.Random(0)
    xs = [L.sample_iso(400, 51200, "bands:0,0,0,0,0,1,3", rng) for _ in range(5000)]
    assert min(xs) >= 12800 * 0.999
    assert sum(x >= 25600 for x in xs) / len(xs) == pytest.approx(0.75, abs=0.03)
    xs = [L.sample_iso(400, 51200, "bands:1", rng) for _ in range(5000)]  # padded weights = uniform
    assert _top2(xs, 51200) == pytest.approx(2 / 7, abs=0.03)


def test_adaptive_shifts_mass_and_roundtrips():
    s = L.AdaptiveIsoSampler(400, 51200, decay=0.5, floor=0.2)
    assert len(s.bands) == 7 and s.probs() == pytest.approx([1 / 7] * 7)
    isos = [s.bands[k][0] * 1.4 for k in range(7)]
    for _ in range(10):
        s.update(isos, [0.01] * 6 + [0.05])
    p = s.probs()
    assert p[6] > 3 * p[0] and min(p) >= 0.2 / 7 - 1e-9 and sum(p) == pytest.approx(1)
    rng = random.Random(0)
    xs = [L.sample_iso(400, 51200, "adaptive", rng, state=s) for _ in range(5000)]
    frac = sum(x >= s.bands[6][0] for x in xs) / len(xs)
    assert frac == pytest.approx(p[6], abs=0.03)
    # narrower camera range: samples stay inside it
    assert all(400 <= s.sample(400, 25600, rng) <= 25600 for _ in range(500))
    t = L.AdaptiveIsoSampler(400, 51200)
    t.load_state_dict(s.state_dict())
    assert t.probs() == s.probs() and t.count == s.count
    r1, r2 = random.Random(3), random.Random(3)
    assert [s.sample(rng=r1) for _ in range(50)] == [t.sample(rng=r2) for _ in range(50)]
    with pytest.raises(ValueError):
        L.sample_iso(400, 51200, "adaptive")


def test_adaptive_target_gap():
    s = L.AdaptiveIsoSampler(400, 51200, n_bands=2, floor=0.0, target=[0.01, 0.04])
    s.update([500, 40000], [0.02, 0.04])  # band0 at 2x its target, band1 at target
    assert s.probs() == pytest.approx([2 / 3, 1 / 3])


def test_per_sample_tone_l1():
    pred, gt = _pair()
    v = L.per_sample_tone_l1(pred, gt)
    assert v.shape == (2,) and torch.allclose(v.mean(), F.l1_loss(L.tone(pred), L.tone(gt)))
