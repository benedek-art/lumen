"""Star retention metrics + gate on synthetic data (CPU, no photos)."""
import importlib
from pathlib import Path
import numpy as np
from scipy.ndimage import median_filter
from lumen_denoise.eval import common, stars

T = common.NoiseTable()
FR = common.clean_frames(synthetic=True, n_synth=2)


def med5(x, K, r):  # a classic star-eater
    return np.stack([median_filter(c, 5) for c in x]).astype(np.float32)


def _bench(f, iso=6400):
    return stars.synthetic_star_bench(f, FR, T, iso)


def test_add_stars_deterministic_and_bucketed():
    c = stars.night_sky(FR[0].clean[:, :256, :256])
    assert abs(c.mean() - stars.SKY_LEVEL) < 1e-4
    K, r = T.params("ILCE-7M4", 6400)
    a, pa = stars.add_stars(c, K, r, np.random.default_rng(3), n=30, min_sep=12)
    b, pb = stars.add_stars(c, K, r, np.random.default_rng(3), n=30, min_sep=12)
    assert np.array_equal(a, b) and pa == pb and len(pa) == 30
    assert (a >= c - 1e-7).all() and a.max() <= 1.0
    for i, (y0, x0, _) in enumerate(pa):  # min_sep honoured
        for y1, x1, _ in pa[i + 1:]:
            assert abs(y0 - y1) >= 12 or abs(x0 - x1) >= 12
    # perfect output keeps everything, star-free output keeps nothing
    assert np.allclose(stars.flux_kept(c, a, a, pa), 1)
    assert np.allclose(stars.flux_kept(c, a, c, pa), 0)


def test_identity_keeps_flux():
    s = _bench(common.m_identity)
    for lab in ("5-10x", "10-25x", "25-60x"):
        assert 0.85 < s[lab] < 1.15, (lab, s[lab])
    assert s["lost"] <= stars.LOST_MAX


def test_wiener_sane_blur_dims_median_erases():
    w, b, m = _bench(common.m_wiener), _bench(common.make_blur(2.0)), _bench(med5)
    assert w["5-10x"] >= stars.FAINT_MIN and w["10-25x"] >= stars.BRIGHT_MIN and w["lost"] <= stars.LOST_MAX
    # blur:2 spreads flux out of the 7x7 aperture: bright stars ~0.78, below the bright bar
    assert b["25-60x"] < stars.BRIGHT_MIN and b["25-60x"] < w["25-60x"] - 0.1
    # median 5x5 erases compact stars outright
    assert m["5-10x"] < stars.FAINT_MIN and m["lost"] > 0.3 and m["25-60x"] < 0.5


def _ctx(**kw):
    return common.Ctx(table=T, frames=FR, real_files=[], quick=True, **kw)


def _by(checks):
    return {c.name: c for c in checks}


def test_gate_pass_fail():
    g = _by(stars.gate_checks(common.m_wiener, common.m_identity, _ctx()))
    gated = [c for c in g.values() if c.status in ("PASS", "FAIL")]
    assert gated and all(c.status == "PASS" for c in gated), [c for c in gated if c.status != "PASS"]
    assert g["real_stars"].status == "SKIP"
    g = _by(stars.gate_checks(med5, common.m_wiener, _ctx()))
    for iso in stars.GATE_ISOS:
        assert g[f"star_faint_kept@{iso}"].status == "FAIL"
        assert g[f"stars_lost@{iso}"].status == "FAIL"
        assert g[f"star_faint_vs_baseline@{iso}"].status == "FAIL"


def test_real_path_skips(monkeypatch, tmp_path):
    monkeypatch.delenv("LUMEN_ASTRO_LIST", raising=False)
    c = _ctx(); c.real_files = ["/nope/day_portrait.ARW"]
    assert _by(stars.gate_checks(common.m_identity, None, c))["real_stars"].status == "SKIP"
    lst = tmp_path / "astro.txt"; lst.write_text("/nope/milkyway.ARW\n")
    monkeypatch.setenv("LUMEN_ASTRO_LIST", str(lst))  # listed but missing -> list_files drops it -> SKIP
    assert _by(stars.gate_checks(common.m_identity, None, _ctx()))["real_stars"].status == "SKIP"
    c = _ctx(); c.real_files = ["/nope/night_sky_6400.ARW"]  # named astro, file absent -> SKIP, not crash
    monkeypatch.delenv("LUMEN_ASTRO_LIST")
    r = _by(stars.gate_checks(common.m_identity, None, c))["real_stars"]
    assert r.status == "SKIP" and r.note


def test_real_detect_measure_synthetic():
    K, r = T.params("ILCE-7M4", 6400)
    sky = np.full((4, 200, 200), 0.01, np.float32)
    starry, pos = stars.add_stars(sky, K, r, np.random.default_rng(0), n=20, sigmas=(30, 60), min_sep=16)
    x = common.add_noise(starry, K, r, 1)
    ys, xs = stars.detect_real_stars(x, K, r)
    hit = sum(any(abs(y - py) <= 2 and abs(xx - px) <= 2 for y, xx in zip(ys, xs)) for py, px, _ in pos)
    assert hit >= 0.8 * len(pos) and len(ys) < 3 * len(pos)
    m = stars.measure_real(x, x, ys, xs)
    assert m["n"] == len(ys) and abs(m["flux_kept"] - 1) < 1e-6 and m["lost"] == 0
    m = stars.measure_real(x, med5(x, K, r), ys, xs)
    assert m["peak_kept"] < 0.7
    e = stars.measure_real(x, x, np.array([], int), np.array([], int))
    assert e["n"] == 0


def test_cli_modules_import_cleanly():
    for mod in ("lumen_denoise.starbench", "lumen_denoise.realstars"):
        m = importlib.import_module(mod)
        assert callable(m.main)
    import lumen_denoise.realstars as rs
    assert rs.detect_real_stars is stars.detect_real_stars


def test_differential_transfer_is_exact_and_stable():
    s = _bench(common.m_identity, 12800)
    assert np.allclose(s["kept"], 1, atol=1e-4) and s["lost"] == 0  # identity passes stars through untouched
    # paired wiener-vs-identity faint delta must sit well inside BASE_MARGIN for any seed (it ranged
    # -0.09..+0.14 with the non-differential starbench rule at quick size -> flaky gate)
    for sd in range(3):
        a = stars.synthetic_star_bench(common.m_wiener, FR, T, 12800, seed=sd)
        assert abs(a["5-10x"] - 1) < stars.BASE_MARGIN, (sd, a["5-10x"])


def test_gate_blur_fails_bright():
    g = _by(stars.gate_checks(common.make_blur(2.0), common.m_wiener, _ctx()))
    for iso in stars.GATE_ISOS:
        assert g[f"star_25-60x_kept@{iso}"].status == "FAIL"
        assert g[f"star_faint_vs_baseline@{iso}"].status == "FAIL"


def _fake_realdata(monkeypatch):
    from lumen_denoise.eval import realdata
    K, r = T.params("ILCE-7M4", 6400)

    def load(path, table=None):
        i = int(Path(path).stem[-1])
        sky = np.full((4, 400, 400), 0.01, np.float32)
        st, _ = stars.add_stars(sky, K, r, np.random.default_rng(i), n=60, sigmas=(5, 60), min_sep=14)
        return common.add_noise(st, K, r, 10 + i), K, r, dict(model="ILCE-7M4", iso=6400.0, source="calib")
    monkeypatch.setattr(realdata, "available", lambda files=None: (True, "ok"))
    monkeypatch.setattr(realdata, "load_packed", load)


def test_gate_real_path_end_to_end(monkeypatch):
    _fake_realdata(monkeypatch)
    c = _ctx(); c.real_files = ["/x/astro_0.ARW", "/x/milkyway_1.ARW", "/x/portrait_2.ARW"]
    g = _by(stars.gate_checks(common.m_wiener, common.m_identity, c))
    assert g["real_star_flux_kept"].status == "PASS" and g["real_stars_lost"].status == "PASS"
    assert g["real_star_flux_vs_baseline"].status in ("PASS", "FAIL") and "2 files" in g["real_star_flux_kept"].note
    g = _by(stars.gate_checks(med5, common.m_wiener, c))
    assert g["real_star_flux_kept"].status == "FAIL" and g["real_stars_lost"].status == "FAIL"
    assert g["real_star_flux_vs_baseline"].status == "FAIL"


def test_real_load_errors_skip_with_reason(monkeypatch):
    from lumen_denoise.eval import realdata
    monkeypatch.setattr(realdata, "available", lambda files=None: (True, "ok"))
    monkeypatch.setattr(realdata, "load_packed", lambda p, t=None: (_ for _ in ()).throw(OSError("bad raw")))
    c = _ctx(); c.real_files = ["/x/night_0.ARW"]
    r = _by(stars.gate_checks(common.m_identity, None, c))["real_stars"]
    assert r.status == "SKIP" and "failed to load" in r.note and "bad raw" in r.note


def test_measure_real_ignores_nonpositive_reference_flux():
    p0 = np.zeros((4, 64, 64), np.float32); p0[:, 20, 20] = 1.0; p0[:, 40, 40] = -1.0
    m = stars.measure_real(p0, p0 * 0.5, np.array([20, 40]), np.array([20, 40]))
    assert m["n"] == 1 and abs(m["flux_kept"] - 0.5) < 1e-6 and m["lost"] == 0


def test_real_detection_threshold_matches_rationale():
    """REAL_LOST_MAX/REAL_FLUX_MIN rationale: the realstars rule (2.67 x unsmoothed 4-ch-mean std on a gaussian(1)
    copy) is ~9 sigma of the smoothed noise, so a star-free sky yields no detections, >= 5x stars are found, and an
    exact denoiser keeps ~all flux and loses none."""
    from lumen_denoise.eval import stars as st
    K, r = common.NoiseTable().params("ILCE-7M4", 6400)
    sky = (np.full((4, 384, 384), 0.01, np.float32) * np.array([0.5, 1, 1, 0.7], np.float32)[:, None, None])
    assert len(st.detect_real_stars(common.add_noise(sky, K, r, 3), K, r)[0]) == 0
    starry, pos = st.add_stars(sky, K, r, np.random.default_rng(1), n=120, min_sep=12)
    x = common.add_noise(starry, K, r, 5)
    ys, xs = st.detect_real_stars(x, K, r)
    hit = np.array([np.any((np.abs(ys - p[0]) <= 1) & (np.abs(xs - p[1]) <= 1)) for p in pos])
    snr = np.array([p[2] for p in pos])
    assert hit[snr >= 5].mean() >= 0.85
    m = st.measure_real(x, starry, ys, xs)
    assert m["flux_kept"] > 0.95 and m["lost"] == 0.0
