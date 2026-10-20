"""Backbone options: shapes, identity-at-init, state-dict round trips (infer.py contract), fp16."""
import numpy as np
import pytest
import torch

from lumen_denoise.model import Denoiser, UNetSeeInDark
from lumen_denoise.nafnet import NAFNet, local_sca, cfg_to_tensor, tensor_to_cfg

TINY = dict(width=8, enc=(1, 1, 1, 1), middle=1, dec=(1, 1, 1, 1), tlc=32)


def inputs(h=48, w=80, b=1, seed=0):
    g = torch.Generator().manual_seed(seed)
    x = torch.rand(b, 4, h, w, generator=g) * 0.2
    return x, torch.sqrt(1e-4 * x.mean(1, keepdim=True) + 1e-6)


def nparams(m):
    return sum(p.numel() for p in m.parameters())


@pytest.mark.parametrize("kw", [dict(nf=8), dict(nf=8, residual=True), dict(residual=True, arch="nafnet", **TINY)])
@pytest.mark.parametrize("hw", [(48, 80), (16, 112)])
def test_shapes(kw, hw):
    m = Denoiser(**kw).eval()
    x, s = inputs(*hw, b=2)
    with torch.no_grad():
        assert m(x, s).shape == x.shape
    print(kw, "params", nparams(m))


@pytest.mark.parametrize("kw", [dict(nf=8, residual=True), dict(residual=True, arch="nafnet", **TINY)])
def test_identity_at_init(kw):
    m = Denoiser(**kw).eval()
    x, s = inputs()
    with torch.no_grad():
        assert torch.equal(m(x, s), x)


def test_unet_default_unchanged():
    """unet path: same keys as before (no new buffers), same params as UNetSeeInDark."""
    for res in (False, True):
        sd = Denoiser(nf=8, residual=res).state_dict()
        assert not any(k.startswith("arch") for k in sd)
        assert ("residual_flag" in sd) == res
    assert nparams(Denoiser(nf=8).net) == nparams(UNetSeeInDark(5, 4, 8))
    with pytest.raises(AssertionError):
        Denoiser(arch="nafnet")  # needs residual
    with pytest.raises(AssertionError):
        Denoiser(arch="unet", width=8)


@pytest.mark.parametrize("res", [False, True])
def test_unet_old_state_dict_roundtrip(res):
    torch.manual_seed(0)
    m = Denoiser(nf=8, residual=res, zero_init=False).eval()
    sd = {k: v.clone() for k, v in m.state_dict().items()}  # plain dict, as an old checkpoint
    m2 = Denoiser.from_state_dict(sd).eval()
    assert m2.arch == "unet" and m2.residual == res
    x, s = inputs()
    with torch.no_grad():
        assert torch.equal(m(x, s), m2(x, s))


def test_nafnet_state_dict_roundtrip(tmp_path):
    torch.manual_seed(0)
    cfg = dict(width=8, enc=(1, 0, 2), middle=2, dec=(2, 1, 1), tlc=16)
    m = Denoiser(residual=True, arch="nafnet", zero_init=False, **cfg).eval()
    for p in m.parameters():  # beta/gamma start at 0: perturb so every block matters
        p.data.add_(0.05 * torch.randn_like(p))
    torch.save(m.state_dict(), tmp_path / "w.pt")
    m2 = Denoiser.from_state_dict(torch.load(tmp_path / "w.pt", map_location="cpu")).eval()  # infer.py path
    assert m2.arch == "nafnet" and tensor_to_cfg(m2.arch_cfg) == cfg
    x, s = inputs(64, 96)
    with torch.no_grad():
        assert torch.equal(m(x, s), m2(x, s))
    assert tensor_to_cfg(cfg_to_tensor(**cfg)) == cfg


def test_presets_load():
    for p in ("s", "m", "l"):
        m = Denoiser(residual=True, arch="nafnet", preset=p)
        assert Denoiser.from_state_dict(m.state_dict()).arch == "nafnet"
        print("nafnet preset", p, "params %.2fM" % (nparams(m) / 1e6))
    print("unet nf32 %.2fM nf48 %.2fM" % (nparams(Denoiser(nf=32)) / 1e6, nparams(Denoiser(nf=48)) / 1e6))


@pytest.mark.parametrize("kw", [dict(nf=8, residual=True), dict(residual=True, arch="nafnet", **TINY)])
def test_gradient_breaks_identity(kw):
    torch.manual_seed(0)
    m = Denoiser(**kw)
    opt = torch.optim.AdamW(m.parameters(), 1e-3)
    x, s = inputs(32, 32, b=2)
    y = x * 0.9
    loss = (m(x, s) - y).abs().mean(); opt.zero_grad(); loss.backward()
    assert all(torch.isfinite(p.grad).all() for p in m.parameters() if p.grad is not None)
    opt.step()
    for _ in range(3):  # beta/gamma get gradient once the zero-init ending conv moves
        loss = (m(x, s) - y).abs().mean(); opt.zero_grad(); loss.backward(); opt.step()
    with torch.no_grad():
        assert not torch.equal(m(x, s), x)
    if kw.get("arch") == "nafnet":
        assert any(b.beta.abs().sum() > 0 for b in m.net.modules() if hasattr(b, "beta"))


def test_tlc_local_sca():
    """Local SCA equals global when the window covers the map; constant maps stay constant;
    eval on a big tile uses it, train mode always global."""
    conv = torch.nn.Conv2d(3, 3, 1)
    h = torch.randn(1, 3, 32, 48)
    with torch.no_grad():
        g = conv(h.mean((2, 3), keepdim=True))
        loc = local_sca(torch.full((1, 3, 40, 24), 2.0), conv, 16)
        assert torch.allclose(loc, conv(torch.full((1, 3, 1, 1), 2.0)).expand_as(loc), atol=1e-5)
        assert local_sca(h, conv, 13).shape == h.shape  # non-divisible sizes
        assert torch.allclose(local_sca(h, conv, 64), g.expand_as(h), atol=1e-5)  # 4x4 grid = whole map
    net = NAFNet(5, 4, **TINY)
    for p in net.parameters():
        p.data.add_(0.05 * torch.randn_like(p))
    x = torch.randn(1, 5, 64, 64)
    with torch.no_grad():
        net.train(); a = net(x); net.eval(); b = net(x)
        net2 = NAFNet(5, 4, **{**TINY, "tlc": 0}); net2.load_state_dict(net.state_dict()); net2.eval()
        c = net2(x)
    assert torch.allclose(a, c, atol=1e-5) and not torch.allclose(b, c, atol=1e-5)


def test_half_cpu():
    m = Denoiser(residual=True, arch="nafnet", zero_init=False, **TINY).eval()
    x, s = inputs(32, 48)
    try:
        with torch.no_grad():
            y = m.half()(x.half(), s.half())
    except RuntimeError as e:
        pytest.skip(f"fp16 conv unsupported on this CPU build: {e}")
    assert y.dtype == torch.float16 and torch.isfinite(y).all()
    with torch.no_grad():
        ref = m.float()(x, s)
    assert (y.float() - ref).abs().max() < 2e-2


def test_infer_engine_loads_nafnet(tmp_path):
    """The unchanged infer.py path: from_state_dict -> eval -> half -> tiled forward."""
    pytest.importorskip("tifffile")  # infer imports dng
    from lumen_denoise import infer
    m = Denoiser(residual=True, arch="nafnet", **TINY)
    torch.save(m.state_dict(), tmp_path / "w.pt")
    e = infer.Engine(tmp_path / "w.pt", tmp_path / "none.json")
    assert e.net.arch == "nafnet"
    p = (torch.rand(4, 40, 72) * 0.2).numpy()
    try:
        o = e.denoise_packed(p, 1e-4, 1e-6)
    except RuntimeError as err:
        pytest.skip(f"fp16 unsupported on this CPU build: {err}")
    assert o.shape == p.shape and abs(o - p).max() < 1e-3  # identity at init (fp16 rounding)


def test_load_init_unet(tmp_path):
    from lumen_denoise.train import load_init
    src = UNetSeeInDark(4, 4, 8); torch.save(src.state_dict(), tmp_path / "p.pt")
    net = Denoiser(nf=8, residual=True)
    assert load_init(net, tmp_path / "p.pt").startswith(f"{len(src.state_dict())}/")


def test_infer_engine_nafnet_nontrivial(tmp_path):
    """infer.py path with NON-zero weights: reflect pad to 16, tile > tlc window, fp16 local SCA, feathered
    tiling - against a direct fp32 forward (identity-at-init would hide a broken backbone)."""
    pytest.importorskip("tifffile")
    from lumen_denoise import infer
    from lumen_denoise.train import std_map
    torch.manual_seed(0)
    m = Denoiser(residual=True, arch="nafnet", zero_init=False, **TINY)
    with torch.no_grad():
        m.net.ending.weight.mul_(0.3)  # keep the residual O(noise), like a trained net
    torch.save(m.state_dict(), tmp_path / "w.pt")
    e = infer.Engine(tmp_path / "w.pt", tmp_path / "none.json")
    K, rv = 1e-3, 1e-5
    p = (torch.rand(4, 150, 170, generator=torch.Generator().manual_seed(1)) * 0.2).numpy()
    try:
        o1 = e.denoise_packed(p, K, rv)                     # single padded tile
        o2 = e.denoise_packed(p, K, rv, tile=96, ov=16)     # 2x2+ feathered tiles
    except RuntimeError as err:
        pytest.skip(f"fp16 unsupported on this CPU build: {err}")
    t = torch.from_numpy(np.pad(p, ((0, 0), (0, 10), (0, 6)), mode="reflect"))[None]
    with torch.no_grad():
        ref = m.eval()(t, std_map(t, K, rv))[0, :, :150, :170].numpy()
    res = np.abs(ref - p).mean()
    assert res > 1e-3                                       # the backbone really changes the image
    assert np.isfinite(o1).all() and np.abs(o1 - ref).max() < 0.02 * max(1.0, np.abs(ref).max())
    assert np.abs(o1 - ref).mean() < 0.02 * res             # fp16 only
    assert np.abs(o2 - ref).mean() < 0.3 * res              # tiling: seams / local SCA, not garbage


def test_load_init_other_width_skips(tmp_path):
    """Regression: zero-pad branch crashed when out-channels differ too (preset s -> m)."""
    from lumen_denoise.train import load_init
    torch.save(Denoiser(residual=True, arch="nafnet", preset="s").state_dict(), tmp_path / "s.pt")
    net = Denoiser(residual=True, arch="nafnet", preset="m", tlc=128)
    cfg = net.arch_cfg.clone()
    load_init(net, tmp_path / "s.pt")
    assert torch.equal(net.arch_cfg, cfg)


def test_speedcheck_smoke(capsys):
    from lumen_denoise import speedcheck
    speedcheck.main(["--arch", "nafnet", "--preset", "s", "--steps", "1", "--bs", "1", "--ps", "32", "--tile", "64", "--tiles", "1"])
    out = capsys.readouterr().out
    assert "network per" in out and "s/step" in out
