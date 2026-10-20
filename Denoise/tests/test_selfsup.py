import json, random
import numpy as np
import pytest
import torch
import torch.nn as nn
from lumen_denoise import selfsup as ss, prepare_real as pr, raw as rawmod, train
from lumen_denoise.model import Denoiser


class Const(nn.Module):
    """Predicts a learnable per-channel constant: its optimum under a loss is that loss's 'mean'."""
    def __init__(self):
        super().__init__(); self.c = nn.Parameter(torch.zeros(1, 4, 1, 1))

    def forward(self, x, s):
        return self.c.expand_as(x)


class Table:
    t = {"ILCE-7M4": None}
    def params(self, model, iso): return 1.654e-7 * iso, 1e-12 * iso ** 2 + 1e-6
    def iso_range(self, model): return 100.0, 25600.0


def _kr(B, iso=6400):
    K, r = Table().params("", iso)
    return torch.full((B, 1, 1, 1), K), torch.full((B, 1, 1, 1), r)


def test_std_map_matches_train():
    x = torch.rand(2, 4, 16, 16) * 0.3; K, r = _kr(2)
    assert torch.allclose(ss.std_map(x, K, r), train.std_map(x, K, r))


@pytest.mark.parametrize("mode", ["r2r", "n2n"])
@pytest.mark.parametrize("norm", ["std", "var"])
def test_loss_shapes_and_grad(mode, norm):
    torch.manual_seed(0)
    net = Denoiser(nf=8, residual=True)
    K, r = _kr(2)
    y = train.add_noise(torch.rand(2, 4, 32, 32) * 0.2, K, r)
    loss, parts = ss.selfsup_loss(net, y, K, r, mode=mode, norm=norm, gen=torch.Generator().manual_seed(1))
    assert loss.dim() == 0 and torch.isfinite(loss)
    assert set(parts) == {"ss", "ss_mse", "ss_reg", "ss_excess"}
    loss.backward()
    g = net.net.conv10_1.weight.grad  # zero-init residual head: the only layer with grad at step 0
    assert g is not None and g.abs().sum() > 0
    assert all(torch.isfinite(p.grad).all() for p in net.parameters() if p.grad is not None)


def test_identity_excess_r2r():
    # identity net: error vs clean = input noise (1+a^2) var -> excess ~ 1+a^2 = 1.25
    K, r = _kr(4)
    y = train.add_noise(torch.full((4, 4, 64, 64), 0.1), K, r)
    _, p = ss.selfsup_loss(lambda x, s: x, y, K, r, mode="r2r", alpha=0.5, gen=torch.Generator().manual_seed(0))
    assert abs(p["ss_excess"].item() - 1.25) < 0.08


@pytest.mark.parametrize("pairs", ["vert", "diag", "any"])
def test_n2n_sampler(pairs):
    B, h, w = 3, 8, 8
    i1, i2 = ss.n2n_pairs(B, h, w, pairs, torch.Generator().manual_seed(0))
    assert (i1 != i2).all()
    r1, r2, c1, c2 = i1 // 2, i2 // 2, i1 % 2, i2 % 2
    if pairs == "vert":
        assert (r1 != r2).all() and (c1 == c2).all()
    if pairs == "diag":
        assert (r1 != r2).all() and (c1 != c2).all()
    if pairs != "any":
        # raw rows: packed row P holds raw rows 2P, 2P+1 -> the two picks never share a raw row
        P = torch.arange(h).view(1, h, 1) * 2
        raw1 = {(b, 2 * int(P[0, i, 0] + r1[b, i, j]) + k, i, j) for b in range(B) for i in range(h) for j in range(w) for k in (0, 1)}
        raw2 = {(b, 2 * int(P[0, i, 0] + r2[b, i, j]) + k, i, j) for b in range(B) for i in range(h) for j in range(w) for k in (0, 1)}
        assert not raw1 & raw2
    # both orders and both choices occur (randomness, as the paper stresses)
    assert len(torch.unique(i1)) >= 2
    # subsample picks exactly the indexed cell position from every channel
    x = torch.arange(B * 4 * 2 * h * 2 * w, dtype=torch.float32).view(B, 4, 2 * h, 2 * w)
    s = ss.subsample(x, i1)
    yy = 2 * torch.arange(h).view(1, h, 1) + r1; xx = 2 * torch.arange(w).view(1, 1, w) + c1
    for b in range(B):
        for ch in range(4):
            assert torch.equal(s[b, ch], x[b, ch][yy[b], xx[b]])


def test_r2r_pair_uncorrelated():
    g = torch.Generator().manual_seed(0)
    x0 = 0.05; K, r = _kr(1, 25600)
    v = K * x0 + r
    y = x0 + torch.randn(1, 4, 256, 256, generator=g) * v.sqrt()  # Gaussian noise of the modelled var
    yh, yt, vh = ss.recorrupt(y, K, r, 0.5, g)
    a, b = (yh - x0).flatten(), (yt - x0).flatten()
    corr = (a * b).mean() / (a.std() * b.std())
    assert abs(corr) < 0.02
    assert abs(a.var() / (1.25 * v) - 1) < 0.05 and abs(b.var() / (5 * v) - 1) < 0.05


def test_r2r_linear_denoiser_matches_supervised():
    """Toy linear denoiser f = beta*y: the R2R-optimal beta equals the supervised-optimal beta at the
    re-corrupted noise level (E[loss_r2r] = E[supervised L2] + const)."""
    g = torch.Generator().manual_seed(0)
    sig2 = 1e-4
    x = torch.randn(8, 4, 128, 128, generator=g) * 0.02          # zero-mean texture, var 4e-4
    y = x + torch.randn(x.shape, generator=g) * sig2 ** 0.5
    K, r = torch.zeros(8, 1, 1, 1), torch.full((8, 1, 1, 1), sig2)  # pure Gaussian: v = r exactly
    yh, yt, _ = ss.recorrupt(y, K, r, 0.5, g)
    beta_r2r = (yh * yt).sum() / (yh * yh).sum()
    beta_sup = 4e-4 / (4e-4 + 1.25 * sig2)
    assert abs(beta_r2r - beta_sup) < 0.01
    # naive noisy-target L2 (target = y itself) would learn the identity-ish beta: clearly biased
    assert (yh * y).sum() / (yh * yh).sum() - beta_sup > 0.05


@pytest.mark.parametrize("mode", ["r2r", "n2n"])
def test_optimal_constant_recovers_clean_mean(mode):
    """Poisson-Gaussian flat field at ISO 25600: minimising the self-supervised L2 with a constant
    predictor lands on the clean value (unbiased), unlike tone-space L1."""
    torch.manual_seed(0)
    x0 = torch.tensor([0.02, 0.05, 0.05, 0.03]).view(1, 4, 1, 1)
    K, r = _kr(8, 25600)
    y = train.add_noise(x0.expand(8, 4, 64, 64).contiguous(), K, r)
    net = Const(); opt = torch.optim.Adam(net.parameters(), 2e-3)
    for _ in range(300):
        loss, _ = ss.selfsup_loss(net, y, K, r, mode=mode, gamma=0.0)
        opt.zero_grad(); loss.backward(); opt.step()
    sd = (K[0] * x0 + r[0]).sqrt().flatten()
    err = (net.c.detach().flatten() - x0.flatten()).abs()
    assert (err < 0.05 * sd).all(), (err, sd)


def test_clipped_pixels_masked():
    K, r = _kr(1)
    y = torch.full((1, 4, 32, 32), 0.1); y[..., :16] = 1.0
    net = Const()
    l1, _ = ss.selfsup_loss(net, y, K, r, gen=torch.Generator().manual_seed(0))
    y2 = y.clone(); y2[..., :16] = 0.99
    l2, _ = ss.selfsup_loss(net, y2, K, r, gen=torch.Generator().manual_seed(0))
    assert torch.allclose(l1, l2)


def test_std_map_scaled_for_recorruption():
    seen = []
    def spy(x, K, r):
        seen.append((K.flatten()[0].item(), r.flatten()[0].item())); return ss.std_map(x, K, r)
    K, r = _kr(1)
    y = torch.rand(1, 4, 16, 16) * 0.1
    ss.selfsup_loss(lambda x, s: x, y, K, r, mode="r2r", alpha=0.5, std_fn=spy)
    assert seen[0][0] == pytest.approx(K.item() * 1.25) and seen[0][1] == pytest.approx(r.item() * 1.25)
    seen.clear(); ss.selfsup_loss(lambda x, s: x, y, K, r, mode="n2n", std_fn=spy)
    assert all(k == pytest.approx(K.item()) for k, _ in seen)


def test_gamma_ramp():
    assert ss.gamma_ramp(0, 0, 100, 2.0) == 0 and ss.gamma_ramp(50, 0, 100, 2.0) == 1.0 and ss.gamma_ramp(500, 0, 100, 2.0) == 2.0


# ------------------------------------------------------------------ augmentation / RealData

def _coded(ps):
    """Packed RGGB image whose values encode the CFA colour (R=1, G1=2, G2=2.5, B=3)."""
    return np.stack([np.full((ps, ps), v, np.float32) for v in (1, 2, 2.5, 3)])


@pytest.mark.parametrize("fh,fv,tr", [(a, b, c) for a in (0, 1) for b in (0, 1) for c in (0, 1)])
def test_augment_keeps_rggb(fh, fv, tr):
    o = ss.augment(_coded(9), 8, fh, fv, tr)
    assert o.shape == (4, 8, 8)
    assert (o[0] == 1).all() and (o[3] == 3).all() and np.isin(o[1:3], [2, 2.5]).all()
    # content mirrored: a raw column ramp reverses under fh
    rawramp = np.tile(np.arange(18, dtype=np.float32), (18, 1))
    o = ss.unpack_t(ss.augment(ss.pack_t(rawramp), 8, fh, fv, 0))
    d = np.diff(o[0])
    assert (d == (-1 if fh else 1)).all()


def _write_crops(d, n=3, ps=40, isos=(6400, 12800, 51200)):
    meta = {}
    for k in range(n):
        np.save(d / f"f{k}_c0.npy", (np.random.rand(4, ps, ps) * 0.2).astype(np.float16))
        meta[f"f{k}_c0"] = {"model": "ILCE-7M4", "iso": isos[k], "frame": f"f{k}"}
    json.dump(meta, open(d / "real_meta.json", "w"))


def test_realdata_batch(tmp_path):
    _write_crops(tmp_path)
    np.save(tmp_path / "orphan.npy", np.zeros((4, 40, 40), np.float16))  # no meta -> ignored
    rd = ss.RealData(tmp_path, tmp_path / "real_meta.json", device="cpu", rng=random.Random(0))
    assert len(rd) == 3
    x, K, r = rd.batch(6, 32, Table())
    assert x.shape == (6, 4, 32, 32) and x.dtype == torch.float32 and K.shape == r.shape == (6, 1, 1, 1)
    Ks = [Table().params("", i)[0] for i in (6400, 12800, 51200)]  # 51200 extrapolated (table max 25600)
    assert all(any(abs(k / k0 - 1) < 1e-5 for k0 in Ks) for k in K.flatten().tolist())
    assert len(ss.RealData(tmp_path, tmp_path / "real_meta.json", iso_min=10000)) == 2
    x, _, _ = ss.RealData(tmp_path, tmp_path / "real_meta.json", flips=False).batch(2, 40, Table())
    assert x.shape == (2, 4, 40, 40)  # ps == stored size: transpose-only path


# ------------------------------------------------------------------ prepare_real

def test_crop_ok():
    c = np.full((4, 64, 64), 0.1, np.float32)
    assert pr.crop_ok(c)[0]
    c2 = c.copy(); c2[:, :, :20] = 1.0
    assert pr.crop_ok(c2) == (False, "clipped")
    assert pr.crop_ok(np.full((4, 64, 64), 1e-4, np.float32)) == (False, "dark")


def test_prepare_real_with_fake_loader(tmp_path, monkeypatch):
    cfa = np.full((256, 256), 0.1, np.float32) + np.random.RandomState(0).randn(256, 256).astype(np.float32) * 0.01
    cfa[:, :128] = 1.0  # left half blown out: no crop may come from there
    fake = rawmod.Raw(cfa, "RGGB", np.zeros(4), 16383.0, np.ones(4), 12800.0, "ILCE-7M4")
    monkeypatch.setattr(pr.raw, "load", lambda p: fake)
    lst = tmp_path / "list.txt"; lst.write_text("/x/A.ARW\n/x/B.ARW\n")
    out = tmp_path / "out"
    meta = pr.main([str(lst), str(out), "--crops", "3", "--ps", "32", "--workers", "1"])
    files = sorted(out.glob("*.npy"))
    assert 2 <= len(files) <= 6 and set(meta) == {f.stem for f in files}
    for f in files:
        a = np.load(f)
        assert a.shape == (4, 32, 32) and a.dtype == np.float16
        assert (a.max(0) >= 0.98).mean() <= 0.05
    assert meta[files[0].stem] == {"model": "ILCE-7M4", "iso": 12800.0, "frame": files[0].stem.rsplit("_c", 1)[0]}
    assert json.load(open(out / "real_meta.json")) == meta
    # re-run skips finished frames and keeps meta; RealData reads the result
    monkeypatch.setattr(pr.raw, "load", lambda p: (_ for _ in ()).throw(AssertionError("reloaded")))
    assert pr.main([str(lst), str(out), "--crops", "3", "--ps", "32", "--workers", "1"]) == meta
    x, _, _ = ss.RealData(out, out / "real_meta.json").batch(2, 16, Table())
    assert x.shape == (2, 4, 16, 16)


def test_real_excess_deterministic(tmp_path):
    _write_crops(tmp_path)
    rd = ss.RealData(tmp_path, tmp_path / "real_meta.json")
    a = ss.real_excess(lambda x, s: x, rd, Table(), n=8, ps=32)
    b = ss.real_excess(lambda x, s: x, rd, Table(), n=8, ps=32)
    assert a == b and np.isfinite(a)


def test_table_params_extrapolates_physically():
    """Regression: ISO beyond the calib table must not clamp (R2R needs Sigma_z = Sigma_n)."""
    for iso in (102400.0, 51200.0, 3200.0, 50.0):
        K, r = ss.table_params(Table(), "ILCE-7M4", iso)
        K0, r0 = Table().params("", iso)
        assert abs(K / K0 - 1) < 1e-6 and abs(r / r0 - 1) < 1e-6


def test_pixel_var_unbiased_in_blacks():
    """Regression: clamping the local mean at 0 overstated the shadow noise variance (~+9%)."""
    K, r = 8.5e-3, 1.6e-4  # ISO 51200
    g = torch.Generator().manual_seed(0)
    for x in (0.0, 0.003, 0.03):
        clean = torch.full((4, 4, 128, 128), x)
        y = torch.poisson(clean / K, generator=g) * K + torch.randn(clean.shape, generator=g) * r ** .5
        v = ss.pixel_var(y, torch.tensor(K), torch.tensor(r)).mean().item()
        assert abs(v / (K * x + r) - 1) < 0.02, (x, v / (K * x + r))
