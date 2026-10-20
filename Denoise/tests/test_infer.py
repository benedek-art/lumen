"""CPU, synthetic-data tests for lumen_denoise.infer (tiling, strength, guard, batch run).
Run: python -m pytest tests/test_infer.py"""
import json
import os
import sys

import numpy as np
import pytest
import torch
import torch.nn as nn

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lumen_denoise import infer, raw as rawio  # noqa: E402
from lumen_denoise.model import Denoiser  # noqa: E402
from lumen_denoise.train import std_map  # noqa: E402

K, RV = 2e-4, 1.3e-7
TILE, OV = 64, 16  # discarded margin = OV // 4 = 4 px


class Point(nn.Module):  # pointwise: tiling must be exact for any size
    residual = False

    def forward(self, x, sm):
        return x * 0.7 + 3 * sm - 0.01


class Conv(nn.Module):  # 5x5 conv: receptive radius 2 <= discarded margin
    def __init__(self, residual=False):
        super().__init__()
        torch.manual_seed(0)
        self.residual = residual
        self.net = nn.Conv2d(5, 4, 5, padding=2)

    def forward(self, x, sm):
        return self.net(torch.cat([x, sm], 1))


class Const(nn.Module):
    residual = False

    def forward(self, x, sm):
        return torch.full_like(x, 0.25)


def packed(h, w, seed=0):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w]
    clean = 0.05 + 0.3 * (xx / max(w, 1)) * (yy / max(h, 1)) + 0.2 * ((xx // 7 + yy // 5) % 2)
    return (clean[None] + rng.normal(0, 0.01, (4, h, w))).astype(np.float32)


def reference(net, p):
    """Untiled, unpadded, fp32 result of the same math."""
    with torch.no_grad():
        t = torch.from_numpy(p)[None]
        sm = std_map(t, K, RV)
        if getattr(net, "residual", False):
            s = max(float(sm.double().mean()), 1e-5)
            return (t + s * net.net(torch.cat([t / s, sm / s], 1)))[0].numpy()
        return net(t, sm)[0].numpy()


SIZES = [(5, 7), (40, 40), (64, 64), (65, 65), (100, 130), (37, 201), (150, 97), (48, 130)]


@pytest.mark.parametrize("h,w", SIZES + [(2000, 1), (1, 300)])
def test_weights_cover_every_pixel(h, w):
    for tile, ov in [(TILE, OV), (1024, 64)]:
        ws = np.zeros((h, w))
        for y0 in infer._starts(h, tile, tile - 2 * ov):
            for x0 in infer._starts(w, tile, tile - 2 * ov):
                th, tw = min(tile, h - y0), min(tile, w - x0)
                assert y0 >= 0 and x0 >= 0
                ws[y0:y0 + th, x0:x0 + tw] += infer._weights(th, y0, h, ov)[:, None] * infer._weights(tw, x0, w, ov)
        assert ws.min() > 0.05, (h, w, tile, ws.min())


def test_weights_margin():
    w = infer._weights(64, 10, 200, 16)  # interior on both sides
    assert (w[:4] == 0).all() and (w[-4:] == 0).all() and w[4] > 0 and (w[16:-16] == 1).all()
    assert (infer._weights(64, 0, 64, 16) == 1).all()  # whole image: full weight at image borders


@pytest.mark.parametrize("h,w", SIZES)
def test_tiled_equals_untiled_pointwise(h, w):
    p = packed(h, w)
    eng = infer.Engine(net=Point(), dev="cpu", tile=TILE, ov=OV)
    np.testing.assert_allclose(eng.denoise_packed(p, K, RV), reference(Point(), p), atol=1e-6, rtol=0)


@pytest.mark.parametrize("residual", [False, True])
@pytest.mark.parametrize("h,w", [(64, 64), (65, 65), (100, 130), (48, 201), (150, 97), (130, 80)])
def test_tiled_equals_untiled_conv(h, w, residual):
    # dims >= tile or multiple of 16, so no /16 reflect padding differs from the reference
    p = packed(h, w, seed=h + w)
    net = Conv(residual)
    eng = infer.Engine(net=net, dev="cpu", tile=TILE, ov=OV)
    np.testing.assert_allclose(eng.denoise_packed(p, K, RV), reference(net, p), atol=1e-6, rtol=0)


def test_residual_parity_with_denoiser_forward():
    torch.manual_seed(0)
    net = Denoiser(nf=8, residual=True, zero_init=False).eval()
    p = packed(64, 96)
    with torch.no_grad():
        t = torch.from_numpy(p)[None]
        want = net(t, std_map(t, K, RV))[0].numpy()
    got = infer.Engine(net=net, dev="cpu", tile=1024, ov=64).denoise_packed(p, K, RV)
    assert np.abs(want - p).max() > 1e-3  # the net actually does something
    np.testing.assert_allclose(got, want, atol=1e-6, rtol=1e-5)


def fake_raw(h, w, seed=0):
    rng = np.random.default_rng(seed)
    white, bls = 16383.0, np.array([512, 510, 514, 509], np.float32)
    colors = np.array([[0, 1], [3, 2]])
    blk = np.tile(bls[colors], (h // 2 + 1, w // 2 + 1))[:h, :w]
    raw = np.clip(blk + rng.normal(2000, 300, (h, w)), 0, white).astype(np.uint16)
    bl = bls[colors.flatten()]
    cfa = (raw.astype(np.float32) - blk) / np.float32(white - bl.mean())
    return rawio.Raw(cfa, "RGGB", bl, white, np.ones(4, np.float32), 400.0, "TOY", raw, bls, colors, "Toy")


def test_strength_blend(monkeypatch):
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None, mp_sigma=0)
    r = fake_raw(66, 90)
    dn0, info, _ = eng._denoise("a.ARW", "a.dng", r, 0.0, 0.0)
    np.testing.assert_array_equal(dn0, r.raw)  # strength 0 = bit-exact source
    assert info["iso"] == 400 and isinstance(info["iso"], int)
    monkeypatch.setattr(infer.rawio, "denormalize", lambda r, c: c)  # look at normalized output
    d1 = eng._denoise("a", "b", r, 0.0, 1.0)[0]
    dh = eng._denoise("a", "b", r, 0.0, 0.5)[0]
    np.testing.assert_allclose(d1, 0.25, atol=1e-7)
    np.testing.assert_allclose(dh, (r.cfa + 0.25) / 2, atol=1e-6)
    with pytest.raises(ValueError):
        eng.denoise_file("a", "b", 1.5)


def test_odd_dims_fully_processed(monkeypatch):
    monkeypatch.setattr(infer.rawio, "denormalize", lambda r, c: c)
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None, mp_sigma=0)
    r = fake_raw(33, 47)
    d = eng._denoise("a", "b", r, 0.0, 1.0)[0]
    assert d.shape == (33, 47)
    np.testing.assert_allclose(d, 0.25, atol=1e-7)  # including the last odd row and column


def test_fp32_retry_on_nonfinite():
    class Flaky(nn.Module):
        residual, n = False, 0

        def forward(self, x, sm):
            self.n += 1
            return x * (float("inf") if self.n == 1 else 1)

    p = packed(20, 20)
    out = infer.Engine(net=Flaky(), dev="cpu", tile=TILE, ov=OV).denoise_packed(p, K, RV)
    assert np.isfinite(out).all()


def test_noise_params_sources(tmp_path):
    cal = tmp_path / "calib.json"
    cal.write_text(json.dumps({"TOY": [[100, 1e-5, 1e-7], [6400, 1e-3, 1e-6]]}))
    eng = infer.Engine(net=Const(), dev="cpu", calib=cal)
    r = fake_raw(8, 8)
    r.iso = 1e6  # out of range -> clipped to the table
    K_, rv, src = eng.noise_params(r, np.zeros((4, 4, 4), np.float32))
    assert src == "calib" and np.isclose(K_, 1e-3) and np.isclose(rv, 1e-6)
    r.model = "UNKNOWN"  # flat/tiny image: estimate can't fit -> conservative default
    for p in [np.zeros((4, 4, 4), np.float32), np.full((4, 64, 64), 0.1, np.float32)]:
        K_, rv, src = eng.noise_params(r, p)
        assert src == "default" and K_ > 0 and rv > 0
    p = np.clip(packed(256, 256), 0, None)
    p += np.random.default_rng(1).normal(0, 0.02, p.shape).astype(np.float32)
    assert eng.noise_params(r, p)[2] == "estimated"


@pytest.fixture
def offload(tmp_path, monkeypatch):
    root = tmp_path / "Volumes" / "Offload Drive"
    root.mkdir(parents=True)
    monkeypatch.setattr(infer, "OFFLOAD", str(root))
    return root


def test_guard_real_path():
    with pytest.raises(PermissionError):
        infer.guard_output("/Volumes/Offload Drive/x.dng")
    with pytest.raises(PermissionError):
        infer.guard_output("/volumes/offload drive/x")
    with pytest.raises(PermissionError):
        infer.guard_output("/Volumes/Offload Drive")
    with pytest.raises(PermissionError):
        infer.guard_output("/Volumes/Other/../Offload Drive/a/b.dng")
    infer.guard_output("/Volumes/Offload Drive 2/x.dng")
    infer.guard_output("/Users/me/Pictures/Lumen Denoise/x.dng")


def test_guard_symlink_and_case(offload, tmp_path):
    link = tmp_path / "innocent"
    link.symlink_to(offload)
    with pytest.raises(PermissionError):
        infer.guard_output(link / "x.dng")
    with pytest.raises(PermissionError):
        infer.guard_output(str(offload).upper() + "/x.dng")
    with pytest.raises(PermissionError):
        infer.guard_output(tmp_path / "Volumes" / "elsewhere" / ".." / "Offload Drive" / "x")
    infer.guard_output(tmp_path / "Volumes" / "Offload Drive 2" / "x.dng")


@pytest.fixture
def batch(monkeypatch, tmp_path):
    written, cancelled = [], []

    def load(src):
        if "bad" in str(src):
            raise ValueError("corrupt raw")
        return fake_raw(34, 50, seed=len(str(src)))

    def write(src, cfa, out, orig=None, black=None, pending=None):
        assert orig is not None and black is not None and pending == ("h", src)
        if "wfail" in str(src):
            raise OSError("disk full")
        written.append((str(src), str(out), cfa.dtype, cfa.shape))

    monkeypatch.setattr(infer.rawio, "load", load)
    monkeypatch.setattr(infer.dng, "start", lambda src: ("h", src), raising=False)
    monkeypatch.setattr(infer.dng, "write_cfa_dng", write)
    monkeypatch.setattr(infer.dng, "cancel", cancelled.append, raising=False)
    return written, cancelled


def test_run_continues_after_failures(batch, tmp_path):
    written, _ = batch
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None)
    lines = []
    files = ["a.ARW", "bad.ARW", "c.RW2", "wfail.ARW", "e.ARW"]
    failed = eng.run(files, tmp_path / "out", 0.8, emit=lines.append)
    assert failed == 2
    assert [l["file"] for l in lines] == files  # input order preserved
    assert ["error" in l for l in lines] == [False, True, False, True, False]
    ok = lines[0]
    assert set(ok) >= {"file", "out", "iso", "model", "noise", "denoise_s", "total_s"}
    assert ok["out"].endswith("a-Denoised.dng") and isinstance(ok["iso"], int)
    json.dumps(lines)
    assert [w[0] for w in written] == ["a.ARW", "c.RW2", "e.ARW"]
    assert all(w[2] == np.uint16 and w[3] == (34, 50) for w in written)


def test_run_refuses_offload(batch, offload):
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None)
    with pytest.raises(PermissionError):
        eng.run(["a.ARW"], offload / "out", emit=lambda d: None)
    assert not (offload / "out").exists()


def test_main_cli(batch, monkeypatch, tmp_path, capsys):
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None)
    monkeypatch.setattr(infer, "Engine", lambda *a, **k: eng)
    with pytest.raises(SystemExit) as e:
        infer.main(["a.ARW", "--out", str(tmp_path), "--strength", "2"])
    assert e.value.code == 2  # argparse error
    with pytest.raises(SystemExit) as e:
        infer.main(["a.ARW", "bad.ARW", "--out", str(tmp_path)])
    assert e.value.code == 1
    cap = capsys.readouterr()
    out = [json.loads(l) for l in cap.out.splitlines()]
    assert [l["file"] for l in out] == ["a.ARW"] and "error" not in out[0]  # app decodes stdout as results
    err = [json.loads(l) for l in cap.err.splitlines() if l.startswith("{")]
    assert [l["file"] for l in err] == ["bad.ARW"] and "corrupt raw" in err[0]["error"]
    with pytest.raises(SystemExit) as e:
        infer.main(["a.ARW", "--out", str(tmp_path)])
    assert e.value.code == 0


def test_run_unique_outputs(batch, tmp_path):
    written, _ = batch
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None)
    lines = []
    files = ["d1/DSC00001.ARW", "d2/DSC00001.ARW", "d3/dsc00001.RW2", "d1/DSC00002.ARW"]
    assert eng.run(files, tmp_path, emit=lines.append) == 0
    names = [os.path.basename(l["out"]) for l in lines]
    assert names == ["DSC00001-Denoised.dng", "DSC00001-Denoised-2.dng", "dsc00001-Denoised-3.dng",
                     "DSC00002-Denoised.dng"]
    assert [os.path.basename(w[1]) for w in written] == names


def test_run_timing_excludes_queue(batch, monkeypatch, tmp_path):
    """Prefetch must not charge a file for the time it waited behind the previous one on the GPU."""
    import time
    eng = infer.Engine(net=Const(), dev="cpu", tile=TILE, ov=OV, calib=None)
    dp = eng.denoise_packed
    monkeypatch.setattr(eng, "denoise_packed", lambda *a: (time.sleep(0.3), dp(*a))[1])
    lines = []
    eng.run(["a.ARW", "b.ARW", "c.ARW"], tmp_path, emit=lines.append)
    assert all(0.3 <= l["denoise_s"] < 0.5 and l["total_s"] < 0.6 for l in lines), lines


def test_mean_preserve_removes_bias_keeps_detail():
    from lumen_denoise.infer import mean_preserve
    import cv2
    rng = np.random.default_rng(0)
    clean = np.full((4, 256, 256), 0.02, np.float32); clean[:, 100:140, 100:140] = 0.2  # detail
    d = clean - 0.001  # a "denoiser" that is perfect except for a constant bias
    out = mean_preserve(clean, d, 24.0)
    assert abs(float((out - clean)[:, 20:60, 20:60].mean())) < 2e-5  # bias gone in flat area
    blur = lambda a: np.stack([cv2.GaussianBlur(c, (0, 0), 24.0, borderType=cv2.BORDER_REFLECT) for c in a])
    np.testing.assert_allclose(blur(out), blur(clean), atol=1e-6)  # large-scale level matches input
    assert np.array_equal(mean_preserve(clean, d, 0), d)  # sigma 0 disables
