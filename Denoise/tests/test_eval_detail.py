"""Detail/texture metrics move the right way on known cases. python -m pytest tests/test_eval_detail.py -q"""
import os, sys
import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lumen_denoise.eval import common, detail as D, perceptual  # noqa: E402

K, R = 4e-4, 2e-6   # ~ISO 6400-ish shot/read noise


@pytest.fixture(scope="module")
def crops():
    scene = common.synthetic_scene(512, 512, seed=7)
    c = D._regions(scene, "detail", 1)[0]
    f = D._regions(scene, "flat", 1)[0]
    x = common.add_noise(c, K, R, 11)
    xf = common.add_noise(f, K, R, 12)
    out = {m: common.get_method(m)(x, K, R) for m in ("identity", "wiener", "blur:2.0")}
    return c, x, f, xf, out


def test_identity_on_clean(crops):
    c = crops[0]
    assert D.hf_energy_ratio(c, c) == pytest.approx(1.0, abs=1e-9)
    assert abs(D.residual_structure_corr(c, c, c, K, R)) < 1e-9
    assert D.structure_removed(c, c, c) == 0.0
    assert D.gmsd(c, c) == pytest.approx(0.0, abs=1e-12)


def test_blur_loses_detail_vs_wiener(crops):
    c, x, _, _, o = crops
    hw, hb = D.hf_energy_ratio(c, o["wiener"]), D.hf_energy_ratio(c, o["blur:2.0"])
    assert hb < 0.7 < 0.85 < hw
    assert D.residual_structure_corr(x, o["blur:2.0"], c, K, R) > D.residual_structure_corr(x, o["wiener"], c, K, R) + 0.2
    assert D.structure_removed(x, o["blur:2.0"], c) > 0.4 > 0.1 > D.structure_removed(x, o["wiener"], c)
    assert D.gmsd(c, o["blur:2.0"]) > D.gmsd(c, o["wiener"])
    assert D.hf_energy_ratio(c, o["identity"]) > 1.0          # noise left raises HF energy


def test_white_noise_residual_is_uncorrelated(crops):
    c, x = crops[0], crops[1]
    # oracle denoiser: out == clean, so the residual is exactly the (white) noise
    assert abs(D.residual_structure_corr(x, c, c, K, R)) < 0.03
    assert abs(D.structure_removed(x, c, c)) < 0.02
    rng = np.random.default_rng(0)
    n = rng.normal(0, 0.01, c.shape).astype(np.float32)
    assert abs(D.residual_structure_corr(c + n, c, c, K, R)) < 0.03


def test_gmsd_monotone_in_blur(crops):
    c = crops[0]
    g = [D.gmsd(c, common.make_blur(s)(c, K, R)) for s in (0.5, 1.0, 2.0)]
    assert 0 < g[0] < g[1] < g[2]


def test_method_noise_ratio(crops):
    f, xf, = crops[2], crops[3]
    assert D.method_noise_ratio(xf, f, K, R) == pytest.approx(1.0, abs=0.15)   # removed exactly the noise
    assert D.method_noise_ratio(xf, xf, K, R) == 0.0                            # identity removes nothing
    w = D.method_noise_ratio(xf, common.m_wiener(xf, K, R), K, R)
    assert 0.3 < w < 1.2


def test_crop_metrics_keys(crops):
    c, x, _, _, o = crops
    d = D.crop_metrics(c, x, o["wiener"], K, R)
    assert {"hf_ratio", "resid_corr", "method_noise", "gmsd"} <= set(d)
    assert all(isinstance(v, float) for v in d.values())


def _ctx():
    t = common.NoiseTable()
    return common.Ctx(t, common.clean_frames(synthetic=True, n_synth=2), (1600, 6400), quick=True)


def test_gate_blur_fails_vs_wiener():
    ctx = _ctx()
    rows = D.gate_checks(common.get_method("blur:2.0"), common.m_wiener, ctx)
    st = {c.name: c.status for c in rows}
    assert all(c.section == "detail" for c in rows)
    assert st["hf_ratio@1600"] == "FAIL" and st["struct_removed@6400"] == "FAIL" and st["gmsd@6400"] == "FAIL"


def test_gate_wiener_passes_and_identity_fails_noise_removal():
    ctx = _ctx()
    w = D.gate_checks(common.m_wiener, common.m_wiener, ctx)
    assert all(c.status == "PASS" for c in w), [c for c in w if c.status != "PASS"]
    i = D.gate_checks(common.m_identity, common.m_wiener, ctx)
    assert {c.name: c.status for c in i}["method_noise@6400"] == "FAIL"


def test_gate_skips_without_frames():
    ctx = common.Ctx(common.NoiseTable(), [], (1600,), quick=True)
    assert [c.status for c in D.gate_checks(common.m_wiener, common.m_wiener, ctx)] == ["SKIP"]


def test_lpips_optional(crops):
    assert isinstance(perceptual.available(), bool)
    c = crops[0]
    assert perceptual.to_rgb(c).shape == (3,) + c.shape[1:]
    if not perceptual.available():
        assert perceptual.lpips_distance(c, c) is None
        pytest.skip("lpips/torchvision or cached AlexNet weights not present")
    assert perceptual.lpips_distance(c, c) == pytest.approx(0.0, abs=1e-4)


def test_wiener_vs_identity_baseline_not_penalised():
    # identity removes nothing, so "more structured residual than baseline" is meaningless: no FAIL rows
    rows = D.gate_checks(common.m_wiener, common.m_identity, _ctx())
    assert not [c for c in rows if c.status == "FAIL"], [c for c in rows if c.status == "FAIL"]
    st = {c.name: c.status for c in rows}
    assert st["resid_corr@6400"] == "INFO" and st["struct_removed@6400"] == "PASS"
    # ...but blur:2.0 vs identity still fails on the absolute texture checks
    b = {c.name: c.status for c in D.gate_checks(common.get_method("blur:2.0"), common.m_identity, _ctx())}
    assert b["hf_ratio@1600"] == "FAIL" and b["struct_removed@1600"] == "FAIL"


def test_degenerate_inputs():
    z = np.zeros((4, 24, 24), np.float32)
    d = D.crop_metrics(z, z, z, K, R)                     # all-black: no crash, no texture -> nan hf_ratio
    assert np.isnan(d["hf_ratio"]) and d["gmsd"] == 0.0
    o = np.ones((4, 24, 24), np.float32)                  # fully clipped: no flat unclipped pixels
    assert np.isnan(D.crop_metrics(o, o, o, K, R)["method_noise"])
    ctx = common.Ctx(common.NoiseTable(), [common.Frame("x", "NOPE", z, True)], (1600,), quick=True)
    assert {c.status for c in D.gate_checks(common.m_wiener, common.m_wiener, ctx)} == {"SKIP"}
