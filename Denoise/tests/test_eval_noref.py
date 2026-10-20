"""No-reference real-noise checks on synthetic data: metrics move the right way on known cases."""
import numpy as np
from scipy.ndimage import gaussian_filter
from lumen_denoise.eval import common, noref, realdata

K, R = 2e-4, 4e-6
H = W = 192


def _flat(level=0.2, tilt=0.0):
    yy, xx = np.mgrid[0:H, 0:W] / W
    base = level + tilt * xx
    return np.stack([base * t for t in (0.6, 1.0, 1.0, 0.8)]).astype(np.float32)


def _noise(img, seed=0):
    return common.add_noise(img, K, R, seed) - img


def test_white_residual_is_white():
    c = _flat(); n = _noise(c)
    wh = noref.whiteness(n, K, R, c)
    assert wh["flatness"] > 0.9 and wh["lag1"] < 0.03 and wh["xchan"] < 0.05


def test_blurred_noise_residual_not_white():
    c = _flat(); n = _noise(c)
    nb = np.stack([gaussian_filter(p, 1.0) for p in n]) * 3
    wh, ww = noref.whiteness(nb, K, R, c), noref.whiteness(n, K, R, c)
    assert wh["lag1"] > 0.5 and wh["flatness"] < 0.3 < ww["flatness"]


def test_removed_structure_correlates_planes():
    rng = np.random.default_rng(1)
    tex = gaussian_filter(rng.standard_normal((H, W)), 1.0)[None] * 0.05  # luminance texture, same in all planes
    c = _flat() + tex.astype(np.float32); n = _noise(c)
    assert noref.whiteness(n + tex, K, R, c)["xchan"] > 0.3 > noref.whiteness(n, K, R, c)["xchan"]


def test_identity_gives_nan_whiteness_and_zero_variance():
    c = _flat(); x = c + _noise(c)
    assert np.isnan(noref.whiteness(x - x, K, R, x)["flatness"])
    assert noref.variance_ratio(x, x, K, R)["overall"] == 0


def test_variance_ratio_exact_removal():
    c = _flat(0.05, 0.4); x = (c + _noise(c, 3)).astype(np.float32)
    vr = noref.variance_ratio(x, c, K, R)
    assert abs(vr["overall"] - 1) < 0.05 and all(abs(b[2] - 1) < 0.15 for b in vr["bins"])
    assert noref.variance_ratio(x, c + 0.5 * (x - c), K, R)["overall"] < 0.3   # half the noise left
    assert noref.variance_ratio(x, gaussian_filter(c, 0) * 0 + c.mean(), K, R)["overall"] > 2  # structure removed


def test_leftover_noise():
    c = _flat(); n = _noise(c, 4)
    assert 0.9 < noref.leftover_noise(c + n, K, R) < 1.1
    assert noref.leftover_noise(c, K, R) < 0.05
    assert 0.4 < noref.leftover_noise(c + 0.5 * n, K, R) < 0.6


def test_row_banding_detected():
    c = _flat(); n = _noise(c, 5); x = c + n
    sig = np.sqrt(K * c.reshape(4, -1).mean(1) + R)
    base = noref.banding_score(x, sig)["score"]
    rows = np.random.default_rng(6).normal(0, 1, (1, H, 1)) * sig[:, None, None] * 0.25
    band = noref.banding_score(x + rows, sig)
    assert 0.7 < base < 1.4 and band["rows"] > 3 * base and band["cols"] < 1.4
    assert noref.banding_score(x + rows)["score"] > 3   # self-estimated sigma also works
    assert noref.banding_score(np.transpose(x + rows, (0, 2, 1)), sig)["cols"] > 3


def test_chroma_blotches_detected_gradient_not():
    clean = _flat(0.15, 0.3)
    rng = np.random.default_rng(7)
    blot = np.stack([gaussian_filter(rng.standard_normal((H, W)), 6) for _ in range(2)]) * 0.4
    b = clean.copy(); b[0] *= 1 + blot[0]; b[3] *= 1 + blot[1]
    s_clean, s_grad = noref.chroma_blotch_score(_flat(), K=K, r=R), noref.chroma_blotch_score(clean, K=K, r=R)
    s_blot = noref.chroma_blotch_score(b, K=K, r=R)
    s_noisy = noref.chroma_blotch_score(clean + _noise(clean, 8), K=K, r=R)
    assert s_clean < 0.05 and s_grad < 0.1 and s_blot > 1.5 and 0.6 < s_noisy < 1.4
    assert noref.chroma_blotch_score(b) > 10 * noref.chroma_blotch_score(clean)  # unnormalized mode


def test_list_files_missing():
    assert realdata.list_files("/nonexistent/dir") == [] and realdata.list_files("") == []
    assert realdata.list_files("/nonexistent/list.txt") == []


def test_list_files_dir_and_txt(tmp_path):
    for n in ("a.ARW", "b.rw2", "c.jpg"):
        (tmp_path / n).write_bytes(b"x")
    assert [p.rsplit("/", 1)[1] for p in realdata.list_files(tmp_path)] == ["a.ARW", "b.rw2"]
    lst = tmp_path / "l.txt"; lst.write_text(f"# c\n{tmp_path/'a.ARW'}\n/missing.ARW\n")
    assert realdata.list_files(lst) == [str(tmp_path / "a.ARW")]


def test_pick_test_crops():
    img = common.synthetic_scene(384, 384, 0)
    cr = realdata.pick_test_crops(common.add_noise(img, K, R, 1), n=4, size=128)
    assert len(cr) == 4 and all(x.shape == (4, 128, 128) for _, x in cr)


def _ctx(**kw):
    return common.Ctx(common.NoiseTable(), common.clean_frames(n=2, synthetic=True), quick=True, **kw)


def test_gate_no_real_files_all_skip():
    for rf in (None, []):
        rows = noref.gate_checks(common.m_wiener, common.m_identity, _ctx(real_files=rf))
        assert rows and all(c.status == "SKIP" and c.note for c in rows)
    rows = noref.gate_checks(common.m_wiener, common.m_identity, _ctx(real_files=["/nope.ARW"]))
    assert all(c.status == "SKIP" for c in rows)


def test_selftest_directions():
    ctx = _ctx()
    ident = {c.name: c for c in noref.noref_selftest_checks(common.m_identity, ctx)}
    assert ident["residual_var_ratio"].status == "FAIL" and ident["leftover_noise_flat"].status == "FAIL"
    assert ident["residual_spectral_flatness"].status == "FAIL"
    blur = {c.name: c for c in noref.noref_selftest_checks(common.make_blur(2.0), ctx)}
    wien = {c.name: c for c in noref.noref_selftest_checks(common.m_wiener, ctx)}
    assert blur["residual_xchan_corr"].value > wien["residual_xchan_corr"].value
    assert blur["residual_spectral_flatness"].value < wien["residual_spectral_flatness"].value
    assert blur["residual_xchan_corr"].status == "FAIL" and blur["residual_lag1_autocorr"].status == "FAIL"
    assert blur["residual_var_ratio_worst_kind"].status == "FAIL"   # median over crops alone hid blur:2's detail removal
    assert "hard bar" in blur["residual_xchan_corr"].note             # baseline-relative slack cannot rescue blur:2
    assert wien["leftover_noise_flat"].status == "PASS"
    assert "ok" in wien["metric_sanity_true_noise"].note
    assert all(c.section == noref.SEC_PROXY for c in wien.values())


def test_gate_real_path_with_fake_loader(monkeypatch):
    """Exercise the real-file branch without rawpy/exiftool: loader returns a noisy synthetic frame."""
    img = common.synthetic_scene(768, 768, 2)
    monkeypatch.setattr(realdata, "available", lambda files=None: (True, "ok"))
    monkeypatch.setattr(realdata, "load_packed", lambda p, t=None: (common.add_noise(img, K, R, 9), K, R, dict(model="X", iso=6400)))
    rows = noref.gate_checks(common.m_wiener, common.m_identity, _ctx(real_files=["a.ARW", "b.ARW", "c.ARW"]))
    by = {c.name: c for c in rows}
    assert all(c.section == noref.SEC_REAL for c in rows) and "2 files, 8 crops" in by["residual_lag1_autocorr"].note
    assert by["leftover_noise_flat"].status == "PASS" and by["residual_var_ratio"].value is not None
    monkeypatch.setattr(realdata, "load_packed", lambda p, t=None: (_ for _ in ()).throw(OSError("bad")))
    assert all(c.status == "SKIP" for c in noref.gate_checks(common.m_wiener, common.m_identity, _ctx(real_files=["a.ARW"])))


def _rows(**kw):
    m = dict(lag1=0.02, ac_max=0.03, flatness=0.95, xchan=0.03, var_ratio=1.0, leftover=0.1,
             blotch=0.3, blotch_in=1.0, band=0.5, band_in=1.0, band_amp=0.5, band_new=0.0)
    return [(k, {**m, **kw.get(k, {})}) for k in ("flat", "dark", "detail", "mid")]


def test_judge_rules():
    good = {c.name: c.status for c in noref.judge("s", _rows(), _rows())}
    assert all(v in ("PASS", "INFO") for v in good.values())
    # whiteness: detail-only failure is caught (worst kind), rescued only by a no-better baseline under the hard bar
    bad = _rows(detail=dict(lag1=0.2, xchan=0.3))
    st = {c.name: c.status for c in noref.judge("s", bad, _rows())}
    assert st["residual_lag1_autocorr"] == "FAIL" and st["residual_xchan_corr"] == "FAIL"
    st = {c.name: c.status for c in noref.judge("s", bad, _rows(detail=dict(lag1=0.19, xchan=0.29)))}
    assert st["residual_lag1_autocorr"] == "PASS" and st["residual_xchan_corr"] == "PASS"
    st = {c.name: c.status for c in noref.judge("s", _rows(detail=dict(lag1=0.5, xchan=0.8)), _rows(detail=dict(lag1=0.6, xchan=0.9)))}
    assert st["residual_lag1_autocorr"] == "FAIL" and st["residual_xchan_corr"] == "FAIL"
    st = {c.name: c.status for c in noref.judge("s", _rows(detail=dict(var_ratio=4.0)), _rows())}
    assert st["residual_var_ratio"] == "PASS" and st["residual_var_ratio_worst_kind"] == "FAIL"
    st = {c.name: c.status for c in noref.judge("s", _rows(flat=dict(band_amp=2.0, band_new=2.0), dark=dict(band_amp=2.0, band_new=2.0)), _rows())}
    assert st["banding_not_amplified"] == "FAIL" and st["banding_ceiling"] == "PASS"
    st = {c.name: c.status for c in noref.judge("s", _rows(flat=dict(band_new=4.0), dark=dict(band_new=4.0)), _rows())}
    assert st["banding_ceiling"] == "FAIL"
    assert {c.name: c.status for c in noref.judge("s", _rows(**{k: dict(blotch=0.6) for k in ("flat", "dark", "detail", "mid")}), _rows())}[
        "chroma_blotch_vs_baseline"] == "FAIL"


def test_model_made_banding_and_blotches_caught():
    """End to end through crop_metrics: wiener + injected row stripes / chroma blotches."""
    from lumen_denoise.eval.regions import pick_regions, cut
    fr = common.clean_frames(n=1, synthetic=True)[0]
    Kc, Rc = common.NoiseTable().params(fr.camera, 6400)
    rng = np.random.default_rng(0)
    stripes = lambda o, s: o + rng.normal(0, 0.15 * s, (1, o.shape[1], 1)).astype(np.float32)
    def blotch(o, s):
        o = o.copy(); o[0] *= 1 + 1.5 * gaussian_filter(rng.standard_normal(o.shape[1:]), 6); return o
    rows = {"base": [], "stripes": [], "blotch": []}
    for i, g in enumerate(g for g in pick_regions(fr.clean, crop=192) if g["kind"] in ("flat", "dark")):
        c = cut(fr.clean, g); x = common.add_noise(c, Kc, Rc, i); o = common.m_wiener(x, Kc, Rc)
        s = float(common.noise_std(x, Kc, Rc).mean())
        for k, y in (("base", o), ("stripes", stripes(o, s)), ("blotch", blotch(o, s))):
            rows[k].append((g["kind"], noref.crop_metrics(x, y, Kc, Rc)))
    st = lambda k: {c.name: c.status for c in noref.judge("s", rows[k], rows["base"])}
    assert st("base")["banding_not_amplified"] == "PASS" and st("base")["chroma_blotch_vs_baseline"] == "PASS"
    assert st("stripes")["banding_not_amplified"] == "FAIL"
    assert st("blotch")["chroma_blotch_vs_baseline"] == "FAIL"


# --- regressions (metrics-correctness review) ---
_RAW_WB = (0.3, 1.0, 1.0, 0.4)   # typical daylight raw: R/B planes 2-3x below G


def _tinted(level=0.2, tint=_RAW_WB):
    return (np.ones((4, H, W), np.float32) * level * np.array(tint, np.float32)[:, None, None])


def test_blotch_input_scale_is_one_on_wb_raw():
    """Untouched noisy input must score ~1 ("all input chroma noise left"). The expected-noise term used the
    4-plane mean signal for every plane, so R/B noise was overestimated and a raw-like tint scored ~0.75."""
    Kh, Rh = 1e-3, 1e-6   # shot-noise dominated, where per-plane variance K*x_c matters most
    c = _tinted()
    v = [noref.chroma_blotch_score(common.add_noise(c, Kh, Rh, s), K=Kh, r=Rh, mask=np.ones((H, W), bool))
         for s in range(3)]
    assert 0.9 < float(np.mean(v)) < 1.1


def test_leftover_noise_per_plane_scale():
    """Leftover is a per-plane ratio: a model that removes all G noise but leaves R/B untouched must read 0.5
    (median of [1, 0, 0, 1]); with the 4-plane-mean std R/B read ~0.7/0.8 and it slipped to ~0.37."""
    Kh, Rh = 1e-3, 1e-6
    c = _tinted(); x = common.add_noise(c, Kh, Rh, 0)
    y = x.copy(); y[1:3] = c[1:3]
    assert abs(noref.leftover_noise(x, Kh, Rh, ref=x) - 1.0) < 0.05
    assert abs(noref.leftover_noise(y, Kh, Rh, ref=x) - 0.5) < 0.05
    sd = noref.plane_noise_std(x, Kh, Rh)
    for p in (0, 3):  # each plane's own noise / its predicted std ~ 1
        assert abs(noref.mad_sigma(x[p] - c[p]) / float(sd[p].mean()) - 1) < 0.05
