"""Low-ISO regression: clean shots must stay ~unchanged. python -m pytest tests/test_eval_lowiso.py -q"""
import os, sys
import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lumen_denoise.eval import common, lowiso as L  # noqa: E402


@pytest.fixture(scope="module")
def ctx():
    return common.Ctx(table=common.NoiseTable(), frames=common.clean_frames(synthetic=True, n_synth=2),
                      lowiso_files=[], quick=True)


def _by(rows):
    return {c.name: c for c in rows}


@pytest.fixture(scope="module")
def runs(ctx):
    offset = lambda x, K, r: x + np.float32(0.002)
    shadow = lambda x, K, r: np.where(x < 0.02, x + np.float32(0.0005), x).astype(np.float32)  # lifts shadows only
    ms = {"identity": common.m_identity, "wiener": common.m_wiener, "blur:1.5": common.make_blur(1.5), "offset": offset,
          "blur:2.0": common.make_blur(2.0), "shadow_lift": shadow}
    return {k: _by(L.gate_checks(f, common.m_identity if k == "wiener" else None, ctx)) for k, f in ms.items()}


def test_change_metrics_identity_and_offset():
    c = common.synthetic_scene(256, 256, seed=3)
    m = L.change_metrics(c, c, 1e-5, 1e-7)
    assert m["psnr"] == 99.0 and m["max_shift"] == 0 and m["frac_changed"] == 0 and m["p999"] == 0
    assert m["hf_ratio"] == pytest.approx(1.0) and m["hf_kept"] >= 1.0
    o = L.change_metrics(c, c + 0.002)
    assert o["shift"] == pytest.approx([0.002] * 4, abs=1e-6) and o["frac_changed"] == 1.0
    assert o["max_shift"] > L.SHIFT_MAX


def test_hf_kept_noise_correction_is_unbiased():
    """Perfect denoiser (out = clean) on a base-ISO noisy detail crop keeps ~all texture by hf_kept,
    while the raw out/inp ratio penalises the removed noise."""
    c = common.synthetic_scene(seed=5)  # 768: has dark + flat crops
    K, r = 3e-5, 1.3e-7
    tot = []
    for i, (kind, cr) in enumerate(L._crops(c)):
        x = common.add_noise(cr, K, r, 40 + i)
        tot.append(L.change_metrics(x, cr, K, r))
    kept = sum(m["hf_num"] for m in tot) / sum(m["hf_den"] for m in tot)
    assert 0.97 <= kept <= 1.03
    assert min(m["hf_ratio"] for m in tot) < 0.9   # raw ratio drops on dark/flat crops: noise counted as texture
    dark = [m for (k, _), m in zip(L._crops(c), tot) if k == "dark"]
    assert dark and 0.93 <= dark[0]["hf_kept"] <= 1.07   # unbiased per crop too (mask picked on smoothed input)


def test_hp_gain_matches_white_noise():
    n = np.random.default_rng(0).standard_normal((512, 512))
    emp = float(((n - L.gaussian_filter(n, 1.5)) ** 2).mean())
    assert L._hp_gain(1.5) == pytest.approx(emp, rel=0.01) and L._hp_gain(1.5) == pytest.approx(0.894, abs=0.002)


@pytest.mark.parametrize("img", [np.zeros((4, 64, 64), np.float32), np.full((4, 8, 8), 0.3, np.float32),
                                 np.ones((4, 33, 17), np.float32)])
def test_edge_cases_identity(img):
    """All-black, tiny, clipped-white: untouched input must score as untouched (no texture -> ratio 1)."""
    m = L.change_metrics(img, img.copy(), 1e-5, 1e-7)
    assert m["psnr"] == 99.0 and m["hf_ratio"] == 1.0 and m["hf_kept"] == 1.0 and m["max_shift"] == 0


def test_tiny_frames_gate_runs():
    fr = [common.Frame("tiny", "ILCE-7M4", common.synthetic_scene(64, 80, seed=1), True)]
    c = common.Ctx(table=common.NoiseTable(), frames=fr, lowiso_files=[], quick=True)
    rows = L.gate_checks(common.m_identity, common.m_wiener, c)
    assert all(r.status in ("PASS", "INFO", "SKIP") for r in rows), [(r.name, r.status) for r in rows]


def test_identity_passes_all(runs):
    rows = runs["identity"]
    gated = [c for c in rows.values() if c.status not in ("INFO", "SKIP")]
    assert gated and all(c.status == "PASS" for c in gated), [(c.name, c.value) for c in gated if c.status != "PASS"]


def test_blur_fails_hf_and_psnr(runs):
    rows = runs["blur:1.5"]
    for iso in L.BASE_ISOS:
        for n in (f"hf_kept@{iso}", f"psnr_vs_input@{iso}", f"not_worse_vs_clean@{iso}", f"hf_kept_clean_in@{iso}",
                  f"psnr_vs_input_clean_in@{iso}"):
            assert rows[n].status == "FAIL", n
        assert rows[f"mean_shift@{iso}"].status == "PASS"   # blur is mean-preserving


def test_blur2_fails_detail(runs):
    rows = runs["blur:2.0"]
    for iso in L.BASE_ISOS:
        for n in (f"hf_kept@{iso}", f"hf_kept_shadow@{iso}", f"psnr_vs_input@{iso}", f"p999_change@{iso}"):
            assert rows[n].status == "FAIL", n


def test_shadow_only_shift_not_averaged_away(runs):
    """+0.0005 (~8 DN) only below 0.02: a black-level lift confined to dark crops must FAIL the shift check."""
    rows = runs["shadow_lift"]
    for iso in L.BASE_ISOS:
        assert rows[f"mean_shift@{iso}"].status == "FAIL"


def test_offset_fails_shift(runs):
    rows = runs["offset"]
    for iso in L.BASE_ISOS:
        assert rows[f"mean_shift@{iso}"].status == "FAIL"
        assert rows[f"mean_shift_clean_in@{iso}"].status == "FAIL"
        assert rows[f"mean_shift@{iso}"].value == pytest.approx(0.002 / L.DN, rel=0.01)


def test_wiener_sane(runs):
    """Documented verdict on synthetic frames: wiener PASSes every low-ISO row (~54-57 dB vs input,
    <0.2 DN shift, hf_kept ~0.99, +5 dB closer to clean than its noisy input) EXCEPT hf_kept_shadow:
    it smooths away ~35-45 % of the faint shadow texture (0.53-0.62 < 0.85), a real low-ISO regression."""
    rows = runs["wiener"]
    for iso in L.BASE_ISOS:
        assert 48 < rows[f"psnr_vs_input@{iso}"].value < 70
        assert rows[f"psnr_vs_input_clean_in@{iso}"].value > rows[f"psnr_vs_input@{iso}"].value
        assert rows[f"mean_shift@{iso}"].value < 0.5
        assert 0.97 < rows[f"hf_kept@{iso}"].value <= 1.01
        assert rows[f"not_worse_vs_clean@{iso}"].value > 1.0
        assert 0.3 < rows[f"frac_changed_1dn@{iso}"].value < 1.0
        assert rows[f"hf_kept_shadow@{iso}"].status == "FAIL" and 0.4 < rows[f"hf_kept_shadow@{iso}"].value < 0.85
    bad = [c.name for c in rows.values() if c.status == "FAIL"]
    assert sorted(bad) == sorted(f"hf_kept_shadow@{i}" for i in L.BASE_ISOS), bad


def test_real_skips_without_files(ctx, runs, tmp_path):
    assert runs["identity"]["real"].status == "SKIP"
    ms, why = L.real_lowiso(common.m_identity, [], ctx.table)
    assert ms == [] and why
    ms, why = L.real_lowiso(common.m_identity, [str(tmp_path / "missing.ARW")], ctx.table)
    assert ms == [] and why   # no rawpy/exiftool or unreadable file -> reason, never an exception
    c2 = common.Ctx(table=ctx.table, frames=ctx.frames[:1], lowiso_files=[str(tmp_path / "missing.ARW")], quick=True)
    assert _by(L.gate_checks(common.m_identity, None, c2))["real"].status == "SKIP"


def test_exact_denoiser_passes_with_margin():
    """Rationale check: an exact denoiser (out = clean) at base ISO stays well inside every low-ISO bar,
    in particular its noise-mean shift is <= 0.4 DN (SHIFT_MAX = 1 DN)."""
    from lumen_denoise.eval import common as cm, lowiso as lo
    from lumen_denoise.eval.regions import pick_regions, cut
    T = cm.NoiseTable(); fr = cm.clean_frames(synthetic=True, n_synth=2)
    for fi, f in enumerate(fr):
        K, r = T.params(f.camera, max(200, T.iso_range(f.camera)[0]))
        for ri, g in enumerate(pick_regions(f.clean)):
            c = cut(f.clean, g); x = cm.add_noise(c, K, r, cm.crop_seed(fi, ri + 200, 200))
            m = lo.change_metrics(x, c, K, r)
            assert m["max_shift"] <= 0.4 * lo.SHIFT_MAX and m["p999"] <= lo.P999_MAX and m["psnr"] >= lo.PSNR_MIN
            assert m["hf_kept"] >= (lo.HF_MIN_SHADOW if g["kind"] == "dark" else lo.HF_MIN)
