"""calibrate_rows: row/col banding, black offset, hot pixels recovered from synthetic raw frames.
Self-contained numpy synthesis (does not depend on noise_ext.py)."""
import json
import numpy as np
import pytest
from lumen_denoise import calibrate_rows as cr

ISO = 12800
K = 1.654e-7 * ISO                    # Sony A7 IV shot gain
RV = 2.5e-14 * ISO ** 2 + 1e-7        # read var, b*ISO^2 + c
RS = RV ** .5


def synth(h, w, row_sd, col_sd, seed, dark=False, K=K, rv=RV):
    """Independent re-implementation of the forward model (the estimator's own _synth is not trusted
    here): textured scene, Poisson-Gaussian, one offset per RAW row / RAW column."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w] / max(h, w)
    s = (0.02 + 0.25 * xx + 0.15 * yy ** 2 + 0.1 * (xx > 0.6) + 0.06 * (np.sin(40 * xx + 25 * yy) > 0.8)
         + 0.02 * np.cos(9 * xx) * np.sin(7 * yy) + 0.05 * ((xx - 0.3) ** 2 + (yy - 0.5) ** 2 < 0.02))
    clean = np.zeros((4, h, w)) if dark else np.stack([s * g for g in (0.45, 1.0, 1.0, 0.65)])
    x = rng.poisson(clean / K) * K + rng.normal(0, rv ** .5, clean.shape)
    raw_rows, raw_cols = rng.normal(0, row_sd, 2 * h), rng.normal(0, col_sd, 2 * w)
    x[0] += raw_rows[0::2, None] + raw_cols[None, 0::2]   # R : raw (2i, 2j)
    x[1] += raw_rows[0::2, None] + raw_cols[None, 1::2]   # G1: raw (2i, 2j+1)
    x[2] += raw_rows[1::2, None] + raw_cols[None, 0::2]   # G2: raw (2i+1, 2j)
    x[3] += raw_rows[1::2, None] + raw_cols[None, 1::2]   # B : raw (2i+1, 2j+1)
    return x.astype(np.float32)


@pytest.mark.parametrize("seed", [0, 1])
def test_row_textured(seed):
    x = synth(768, 1024, 0.3 * RS, 0.0, seed)
    e = cr.estimate_rowcol(x, K, RV)
    assert not e["dark"]
    assert abs(e["row_sd"] / (0.3 * RS) - 1) < 0.2, e["row_sd"] / RS
    assert e["col_sd"] < 0.08 * RS


def test_rowcol_textured():
    x = synth(768, 1024, 0.25 * RS, 0.2 * RS, 3)
    e = cr.estimate_rowcol(x, K, RV)
    assert abs(e["row_sd"] / (0.25 * RS) - 1) < 0.2
    assert abs(e["col_sd"] / (0.2 * RS) - 1) < 0.2


@pytest.mark.parametrize("seed", [0, 1])
def test_dark_frame(seed):
    x = synth(512, 768, 0.15 * RS, 0.1 * RS, seed, dark=True)
    x[[0, 3]] += 2e-4                                       # per-channel black-level error
    e = cr.estimate_rowcol(x, K, RV)
    assert e["dark"]
    assert abs(e["row_sd"] / (0.15 * RS) - 1) < 0.1, e["row_sd"] / RS
    assert abs(e["col_sd"] / (0.1 * RS) - 1) < 0.1, e["col_sd"] / RS
    np.testing.assert_allclose(e["black_offset"], [2e-4, 0, 0, 2e-4], atol=4e-5)


def test_dark_frame_without_calibration():
    x = synth(512, 768, 0.2 * RS, 0.0, 5, dark=True)
    e = cr.estimate_rowcol(x)                               # read var estimated from the frame
    assert abs(e["read_var"] / RV - 1) < 0.05
    assert abs(e["row_sd"] / (0.2 * RS) - 1) < 0.1


@pytest.mark.parametrize("dark", [False, True])
def test_no_banding_reports_zero(dark):
    x = synth(768, 1024, 0.0, 0.0, 7, dark=dark)
    e = cr.estimate_rowcol(x, K, RV)
    # photos: texture leaks a little (documented floor ~0.1 read sd at this size); dark frames: none
    tol = 0.05 if dark else 0.1
    assert e["row_sd"] < tol * RS and e["col_sd"] < tol * RS, (e["row_sd"] / RS, e["col_sd"] / RS)
    assert e["hot_rate"] < 1e-5


@pytest.mark.parametrize("dark", [False, True])
def test_hot_pixels(dark):
    k, rv = 1.654e-7 * 1600, 2.5e-14 * 1600 ** 2 + 1e-7
    x = synth(512, 768, 0.0, 0.0, 11, dark=dark, K=k, rv=rv)
    rng = np.random.default_rng(12)
    rate = 2e-4
    m = rng.random(x.shape) < rate
    x[m] += rng.uniform(0.05, 0.5, m.sum())
    e = cr.estimate_rowcol(x, k, rv)
    assert abs(e["hot_rate"] / m.mean() - 1) < 0.2, (e["hot_rate"], m.mean())
    assert 0.05 < e["hot_amp"] < 0.5
    # hot pixels must not leak into banding estimates
    assert e["row_sd"] < 0.05 * rv ** .5 and e["col_sd"] < 0.05 * rv ** .5


def test_point_light_is_not_hot():
    """A star covering a 2x2 raw tile lights all 4 packed channels at one site: not a hot pixel."""
    k, rv = 1.654e-7 * 1600, 2.5e-14 * 1600 ** 2 + 1e-7
    x = synth(256, 256, 0.0, 0.0, 13, K=k, rv=rv)
    ys, xs = np.random.default_rng(1).integers(2, 254, (2, 200))
    x[:, ys, xs] += 0.3
    assert cr.estimate_rowcol(x, k, rv)["hot_rate"] < 2e-4


def test_calib_params_interp():
    calib = {"ILCE-7M4": [[100, 1e-5, 1e-7], [400, 4e-5, 4e-7]]}
    Kp, rp = cr.calib_params(calib, "ILCE-7M4", 200)
    assert abs(Kp / 2e-5 - 1) < 1e-6 and abs(rp / 2e-7 - 1) < 1e-6
    assert cr.calib_params(calib, "DMC-GX85", 200) == (None, None)


def test_cli_aggregation(tmp_path, monkeypatch):
    """End-to-end CLI with a monkeypatched loader (no rawpy/exiftool): grouping by (model, ISO),
    preference for dark frames, black offset only from dark frames, JSON schema noise_ext.py loads."""
    sony = lambda iso: (1.654e-7 * iso, 2.5e-14 * iso ** 2 + 1e-7)
    gx = lambda iso: (3.789e-7 * iso, 1e-14 * iso ** 2 + 2e-7)
    # name: (model, iso, row_sd / read_sd, dark, seed, size)
    specs = {f"f{i}.ARW": ("ILCE-7M4", 6400.0, 0.3, False, i, (256, 384)) for i in range(3)}
    specs.update({f"d{i}.ARW": ("ILCE-7M4", 6400.0, 0.3, True, 10 + i, (256, 384)) for i in range(2)})
    specs.update({f"p{i}.ARW": ("ILCE-7M4", 1600.0, 1.0, False, 30 + i, (512, 768)) for i in range(2)})
    specs.update({f"g{i}.RW2": ("DMC-GX85", 3200.0, 0.0, True, 20 + i, (256, 384)) for i in range(2)})
    specs["bad.ARW"] = None

    def loader(path):
        s = specs[path.rsplit("/", 1)[-1]]
        if s is None: raise IOError("corrupt")
        m, iso, frac, dark, seed, (h, w) = s
        k, rv = (sony if m == "ILCE-7M4" else gx)(iso)
        return m, iso, synth(h, w, frac * rv ** .5, 0.0, seed, dark=dark, K=k, rv=rv)

    lst = tmp_path / "list.txt"
    lst.write_text("\n".join(str(tmp_path / f) for f in specs))
    calib = {"ILCE-7M4": [[i, *sony(i)] for i in (100, 1600, 6400, 51200)],
             "DMC-GX85": [[i, *gx(i)] for i in (200, 3200, 25600)]}
    (tmp_path / "calib.json").write_text(json.dumps(calib))
    out = tmp_path / "noise_ext.json"
    monkeypatch.setattr(cr, "load_packed", loader)
    monkeypatch.setattr(cr, "ProcessPoolExecutor", _SerialPool)
    cr.main([str(lst), "--calib", str(tmp_path / "calib.json"), "--out", str(out)])
    t = json.load(open(out))
    assert set(t) == {"ILCE-7M4", "DMC-GX85"}
    s = t["ILCE-7M4"]
    for key in ("iso", "row_sd", "col_sd", "black_offset_sd", "hot_rate"):
        assert isinstance(s[key], list) and len(s[key]) == 2
    assert isinstance(s["chan_gain_sd"], float) and s["chan_gain_sd"] < 0.05
    assert s["iso"] == [1600.0, 6400.0] and s["n"] == [2, 5] and s["n_dark"] == [0, 2]
    assert abs(s["row_sd"][0] / sony(1600)[1] ** .5 - 1) < 0.25       # photos only
    assert abs(s["row_sd"][1] / (0.3 * sony(6400)[1] ** .5) - 1) < 0.15  # from the 2 dark frames
    assert s["black_offset_sd"][0] == 0.0 and s["black_offset_sd"][1] < 5e-5
    g = t["DMC-GX85"]
    assert g["row_sd"][0] < 0.05 * gx(3200)[1] ** .5 and g["chan_gain_sd"] == 0.0


class _SerialPool:
    """Stand-in for ProcessPoolExecutor so the monkeypatched loader is visible to workers."""
    def __init__(self, n, initializer=None, initargs=()):
        if initializer: initializer(*initargs)
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def map(self, f, it, chunksize=1): return map(f, it)


@pytest.mark.parametrize("frac", [1.0, 1.5])
def test_dark_frame_strong_banding_not_underestimated(frac):
    """Regression: the texture ratio test (vd holds row var) used to drop high-offset blocks on dark
    frames, underestimating row sd by ~10% once it approached the read sd."""
    v = [cr.estimate_rowcol(synth(512, 768, frac * RS, 0.0, s, dark=True), K, RV)["row_var"] for s in range(4)]
    assert abs((np.mean(v) ** .5) / (frac * RS) - 1) < 0.05
