import json, math
import pytest
import torch
from lumen_denoise import train
from lumen_denoise.noise_ext import (NoiseOpts, ExtParams, add_noise_ext, ext_variance, chan_gain,
                                     tukey_lambda, dualgain_r, fit_bc)

SONY, GX = "ILCE-7M4", "DMC-GX85"


def _kr(B, K, r):
    return torch.full((B, 1, 1, 1), K), torch.full((B, 1, 1, 1), r)


def _exact(cams, **kw):
    return ExtParams(cams, jitter=kw.pop("jitter", 1.0))


def test_parse():
    assert not NoiseOpts.parse("").any()
    assert all(vars(NoiseOpts.parse("all")).values())
    o = NoiseOpts.parse("row, quant")
    assert o.row and o.quant and not o.col and str(o) == "row,quant"
    with pytest.raises(ValueError):
        NoiseOpts.parse("row,banana")


def test_off_bit_identical_to_train():
    clean = torch.rand(3, 4, 32, 32) * 0.5
    K, r = _kr(3, 2e-3, 1e-5)
    torch.manual_seed(7); a = train.add_noise(clean, K, r)
    torch.manual_seed(7); b = add_noise_ext(clean, K, r, [1600] * 3, SONY, NoiseOpts())
    assert torch.equal(a, b)
    g1, g2 = torch.Generator().manual_seed(3), torch.Generator().manual_seed(3)
    assert torch.equal(add_noise_ext(clean, K, r, 1600, SONY, generator=g1),
                       add_noise_ext(clean, K, r, 1600, SONY, generator=g2))


def test_poisson_gaussian_variance():
    x, K, r = 0.1, 1e-3, 2e-5
    clean = torch.full((4, 4, 128, 128), x)
    Kt, rt = _kr(4, K, r)
    n = add_noise_ext(clean, Kt, rt, 6400, SONY, generator=torch.Generator().manual_seed(0))
    assert abs(n.mean().item() - x) < 1e-3
    assert abs(n.var().item() / (K * x + r) - 1) < 0.03
    v = ext_variance(clean, Kt, rt, 6400, SONY)
    assert torch.allclose(v, torch.full_like(v, K * x + r))


def test_row_noise_shared_and_variance():
    sd = 3e-3
    P = _exact({SONY: {"row_sd": sd}})
    clean = torch.zeros(8, 4, 256, 64)
    K, r = _kr(8, 1e-3, 0.0)  # zero signal + zero read noise -> pure row offsets
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(row=True), P, torch.Generator().manual_seed(1))
    assert torch.equal(n[:, 0], n[:, 1]) and torch.equal(n[:, 2], n[:, 3])
    assert not torch.equal(n[:, 0], n[:, 2])
    assert torch.equal(n[..., :1].expand_as(n), n)  # constant along each row
    assert abs(n[:, 0, :, 0].var().item() / sd ** 2 - 1) < 0.1
    # with read noise: variance of packed-row means = row_sd^2 + r/W
    r0 = 4e-6
    K, r = _kr(8, 1e-3, r0)
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(row=True), P, torch.Generator().manual_seed(2))
    rm = n.mean(3)
    assert abs(rm.var().item() / (sd ** 2 + r0 / 64) - 1) < 0.1
    assert torch.corrcoef(torch.stack([rm[:, 0].flatten(), rm[:, 1].flatten()]))[0, 1] > 0.9
    assert abs(torch.corrcoef(torch.stack([rm[:, 0].flatten(), rm[:, 2].flatten()]))[0, 1]) < 0.1


def test_col_noise_shared():
    sd = 2e-3
    P = _exact({SONY: {"col_sd": sd}})
    clean = torch.zeros(8, 4, 32, 256)
    K, r = _kr(8, 1e-3, 0.0)
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(col=True), P, torch.Generator().manual_seed(1))
    assert torch.equal(n[:, 0], n[:, 2]) and torch.equal(n[:, 1], n[:, 3])
    assert abs(n[:, 0, 0].var().item() / sd ** 2 - 1) < 0.1


def test_row_default_scales_with_read_sd():
    P = ExtParams(jitter=1.0)
    assert P.get(SONY, "row_sd", 6400, 0.01) == pytest.approx(0.08 * 0.01)
    assert P.get(GX, "row_sd", 6400, 0.01) == pytest.approx(0.15 * 0.01)


def test_quant_on_grid():
    clean = torch.rand(2, 4, 64, 64) * 0.3
    K, r = _kr(2, 5e-4, 1e-6)
    for m, q in ((SONY, 1 / (16383 - 512)), (GX, 1 / (4095 - 143))):
        n = add_noise_ext(clean, K, r, 3200, m, NoiseOpts(quant=True), ExtParams(jitter=1.0),
                          torch.Generator().manual_seed(0))
        k = n / q
        assert (k - k.round()).abs().max().item() < 1e-3
    # configurable step
    P = _exact({SONY: {"quant_step": 1 / 1000}})
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(quant=True), P, torch.Generator().manual_seed(0))
    assert ((n * 1000) - (n * 1000).round()).abs().max().item() < 1e-3


def test_hot_rate():
    rate = 2e-3
    P = _exact({SONY: {"hot_rate": rate}})
    clean = torch.zeros(4, 4, 128, 128)
    K, r = _kr(4, 1e-3, 1e-6)
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(hot=True), P, torch.Generator().manual_seed(0))
    frac = (n > 6e-3).float().mean().item()  # hot amps >= 8 read sd; read noise max ~5.5 sd
    assert abs(frac / rate - 1) < 0.15
    assert n.max().item() <= 0.1 + 0.01


def test_hot_rate_curve_loglog():
    P = _exact({SONY: {"iso": [100, 10000], "hot_rate": [1e-6, 1e-4]}})
    assert P.get(SONY, "hot_rate", 1000) == pytest.approx(1e-5, rel=1e-6)


def test_zero_curve_entries_are_below_detection():
    """Regression: a 0.0 row_sd (below detection) must not collapse log-log interp to ~0 between points."""
    P = _exact({SONY: {"iso": [800, 1600, 3200, 6400], "row_sd": [0, 0, 2e-4, 4e-4], "col_sd": [0, 0, 0, 0]}})
    assert P.get(SONY, "row_sd", 2800, 1e-3) == pytest.approx(2e-4, rel=1e-6)  # clamped to nearest measured
    assert P.get(SONY, "row_sd", 4525, 1e-3) == pytest.approx(2.83e-4, rel=1e-2)
    assert P.get(SONY, "col_sd", 3200, 1e-3) == pytest.approx(0.03 * 1e-3)  # all zero -> col_frac default


def test_gain_mean_one_and_unbiased():
    gk = chan_gain(20000, 0.05, torch.zeros(1), torch.Generator().manual_seed(0))
    assert gk.shape == (20000, 4, 1, 1)
    assert abs(gk.mean().item() - 1) < 2e-3 and abs(gk.std().item() / 0.05 - 1) < 0.05
    x, K = 0.2, 1e-3
    P = _exact({SONY: {"chan_gain_sd": 0.2}})
    clean = torch.full((64, 4, 32, 32), x)
    Kt, rt = _kr(64, K, 1e-6)
    n = add_noise_ext(clean, Kt, rt, 3200, SONY, NoiseOpts(gain=True), P, torch.Generator().manual_seed(0))
    assert abs(n.mean().item() - x) < 1e-3  # signal untouched
    pv = n.var((2, 3))  # per-sample per-channel variance spreads, but averages to K x + r
    assert pv.std() / pv.mean() > 0.1
    assert abs(pv.mean().item() / (K * x + 1e-6) - 1) < 0.05


def test_heavy_tails_keep_variance():
    z = tukey_lambda((400000,), 0.0, torch.zeros(1), torch.Generator().manual_seed(0))
    assert abs(z.var().item() - 1) < 0.02
    kurt = ((z - z.mean()) ** 4).mean() / z.var() ** 2
    assert 3.8 < kurt.item() < 4.6  # logistic: 4.2 (Gaussian 3)
    zg = tukey_lambda((400000,), 0.14, torch.zeros(1), torch.Generator().manual_seed(0))
    assert abs((((zg - zg.mean()) ** 4).mean() / zg.var() ** 2).item() - 3) < 0.15
    clean = torch.zeros(4, 4, 64, 64)
    K, r = _kr(4, 1e-3, 1e-5)
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(heavy=True), ExtParams(jitter=1.0),
                      torch.Generator().manual_seed(0))
    assert abs(n.var().item() / 1e-5 - 1) < 0.05


def test_fpn_channel_bias():
    sd = 1e-3
    P = _exact({SONY: {"black_offset_sd": sd, "shade_sd": 0.0, "fpn_col_sd": 0.0}})
    clean = torch.zeros(2000, 4, 8, 8)
    K, r = _kr(2000, 1e-3, 0.0)
    n = add_noise_ext(clean, K, r, 3200, SONY, NoiseOpts(fpn=True), P, torch.Generator().manual_seed(0))
    assert torch.equal(n, n[:, :, :1, :1].expand_as(n))  # one offset per channel
    assert abs(n[:, :, 0, 0].var().item() / sd ** 2 - 1) < 0.06


@pytest.mark.parametrize("jit", [1.0, 1.5])
def test_all_matches_ext_variance(jit):
    torch.manual_seed(0)
    B = 64
    P = ExtParams({SONY: {"hot_rate": 1e-4}}, jitter=jit)
    clean = torch.rand(1, 4, 32, 32).expand(B, -1, -1, -1) * 0.2
    K, r = _kr(B, 1e-3, 2e-5)
    o = NoiseOpts.parse("all")
    n = add_noise_ext(clean, K, r, 6400, SONY, o, P, torch.Generator().manual_seed(1))
    emp = n.var(0).mean().item()
    th = ext_variance(clean, K, r, 6400, SONY, o, P)[0].mean().item()
    assert abs(emp / th - 1) < 0.1


def test_dualgain():
    rows = [[i, 1.654e-7 * i, 1.9e-14 * i * i + 1.26e-7] for i in (400, 800, 1600, 6400, 51200)]
    b, c = fit_bc(rows)
    assert b == pytest.approx(1.9e-14, rel=1e-4) and c == pytest.approx(1.26e-7, rel=1e-4)
    r400 = b * 400 ** 2 + c
    assert dualgain_r(r400, 400, b, c) == r400  # HCG side untouched
    r250 = b * 250 ** 2 + c
    assert dualgain_r(r250, 250, b, c, lcg_ratio=2.5) == pytest.approx(b * (2.5 * 250) ** 2 + c)
    assert dualgain_r(2 * r250, 250, b, c) == pytest.approx(2 * dualgain_r(r250, 250, b, c))  # keeps jitter
    P = ExtParams(table={SONY: rows}, jitter=1.0)
    clean = torch.zeros(2, 4, 8, 8)
    K, r = _kr(2, 1.654e-7 * 250, r250)
    v = ext_variance(clean, K, r, [250, 250], [SONY, SONY], NoiseOpts(dualgain=True), P)
    assert v[0, 0, 0, 0].item() == pytest.approx(b * (2.5 * 250) ** 2 + c, rel=1e-5)
    v = ext_variance(clean, K, r, [250, 250], [GX, GX], NoiseOpts(dualgain=True), P)  # no switch on GX85
    assert v[0, 0, 0, 0].item() == pytest.approx(r250, rel=1e-5)


def test_load_json_missing_keys(tmp_path):
    p = tmp_path / "rows.json"
    p.write_text(json.dumps({SONY: {"iso": [400, 6400], "row_sd": [1e-4, 1e-3]}}))
    P = ExtParams.load(str(p), jitter=1.0)
    assert P.get(SONY, "row_sd", 1600, 0.05) == pytest.approx(math.sqrt(1e-4 * 1e-3), rel=1e-6)
    assert P.get(SONY, "col_sd", 1600, 0.05) == pytest.approx(0.03 * 0.05)  # default
    assert P.cam(SONY)["chan_gain_sd"] == 0.01
    q = ExtParams(jitter=1.0).get("NEW-CAM", "row_sd", 800, 0.01)  # unknown camera -> base defaults
    assert q == pytest.approx(0.08 * 0.01)


def test_mixed_batch_models_and_lambdas():
    P = ExtParams({GX: {"tl_lambda": -0.1}}, jitter=1.3)
    clean = torch.rand(2, 4, 16, 16) * 0.1
    K = torch.tensor([1e-3, 2e-3]).view(2, 1, 1, 1); r = torch.tensor([1e-5, 3e-5]).view(2, 1, 1, 1)
    n = add_noise_ext(clean, K, r, torch.tensor([3200.0, 1600.0]), [SONY, GX], NoiseOpts.parse("all"), P,
                      torch.Generator().manual_seed(0))
    assert n.shape == clean.shape and torch.isfinite(n).all()
