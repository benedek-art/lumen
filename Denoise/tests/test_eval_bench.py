"""CPU tests for eval.regions / eval.synth_bench / bench (synthetic data only)."""
import numpy as np
import pytest
from lumen_denoise.eval import common, regions, synth_bench as sb


@pytest.fixture(scope="module")
def table():
    return common.NoiseTable()


@pytest.fixture(scope="module")
def frames():
    return common.clean_frames(synthetic=True, n_synth=2)


def test_regions_kinds_deterministic():
    img = common.synthetic_scene(seed=5)
    a, b = regions.pick_regions(img), regions.pick_regions(img.copy())
    assert a == b
    kinds = [r["kind"] for r in a]
    assert set(kinds) == set(regions.KINDS)
    by = {r["kind"]: regions.cut(img, r) for r in a}
    assert regions.DARK[0] <= by["dark"].mean() <= regions.DARK[1]
    assert by["dark"].max() < 0.1
    for k, c in by.items():
        assert c.max() <= regions.CLIP or k == "centre"
    g = {k: regions.region_stats(c, crop=c.shape[1])["grad"].item() for k, c in by.items() if k != "centre"}
    assert g["flat"] == min(g[k] for k in ("flat", "detail", "mid"))
    hf = {k: regions.region_stats(c, crop=c.shape[1])["hf"].item() for k, c in by.items() if k != "centre"}
    assert hf["detail"] == max(hf.values())
    c = next(r for r in a if r["kind"] == "centre")
    assert c["size"] == common.CENTRE and c["y"] == (img.shape[1] - 512) // 2
    # non-centre kinds do not overlap on a scene that has room
    nc = [r for r in a if r["kind"] != "centre"]
    for i, r in enumerate(nc):
        assert not regions._overlaps(r["y"], r["x"], r["size"], nc[:i] + nc[i + 1:])


def test_regions_small_image():
    img = common.synthetic_scene(100, 140, seed=1)
    rs = regions.pick_regions(img)
    assert rs and all(r["y"] + r["size"] <= 100 and r["x"] + r["size"] <= 140 for r in rs)
    assert next(r for r in rs if r["kind"] == "centre")["size"] == 100
    flat = np.full((4, 64, 64), 0.2, np.float32)  # no shadows, no detail: must not crash
    assert any(r["kind"] == "centre" for r in regions.pick_regions(flat))


def test_run_deterministic_and_shared_noise(frames, table):
    seen = []
    def spy(x, K, r):
        seen.append(x.copy()); return x
    m = {"a": spy, "b": spy, "w": common.m_wiener}
    r1 = sb.run(m, frames[:1], table, isos=(6400,), kinds=("flat", "dark"), extra=False)
    assert len(r1) == 2 * 3
    assert np.array_equal(seen[0], seen[1]) and np.array_equal(seen[2], seen[3])  # same noise per method
    assert not np.array_equal(seen[0][:, :8, :8], seen[2][:, :8, :8])            # different per region
    r2 = sb.run(m, frames[:1], table, isos=(6400,), kinds=("flat", "dark"), extra=False)
    strip = lambda rs: [{k: v for k, v in r.items() if k != "sec"} for r in rs]
    assert strip(r1) == strip(r2)


def test_iso_clamped(frames, table):
    gx = [f for f in frames if f.camera == "DMC-GX85"][:1]
    rows = sb.run({"n": common.m_identity}, gx, table, isos=(51200,), kinds=("flat",), extra=False)
    assert rows[0]["iso"] == 51200 and rows[0]["iso_eff"] == table.iso_range("DMC-GX85")[1]


def test_wiener_beats_identity_blur_loses_detail(frames, table):
    m = {"noisy": common.m_identity, "wiener": common.m_wiener, "blur": common.make_blur(2.0)}
    s = sb.summarize(sb.run(m, frames, table, isos=(6400,), extra=False))
    o, br = s["overall"], s["by_region"]
    assert o["wiener"][6400]["psnr"] > o["noisy"][6400]["psnr"] + 3
    assert br["blur"][6400]["detail"]["psnr"] < br["wiener"][6400]["detail"]["psnr"] - 3
    assert set(s["by_iso"]["wiener"]) == {f.camera for f in frames}
    assert set(br["wiener"][6400]) == set(regions.KINDS)


def test_summary_and_markdown(frames, table):
    m = {"noisy": common.m_identity, "wiener": common.m_wiener}
    rows = sb.run(m, frames, table, isos=(1600, 6400), kinds=("flat", "detail"), extra=False)
    assert len(rows) == 2 * len(frames) * 2 * 2
    s = sb.summarize(rows)
    assert s["n_rows"] == len(rows)
    assert s["overall"]["noisy"][1600]["n"] == len(frames) * 2
    md = sb.to_markdown(s)
    assert "| wiener | **all** |" in md and "ISO 6400" in md and "| detail | flat |" in md
    lines = [l for l in md.splitlines() if l.startswith("| noisy |")]
    assert len(lines) == len(s["by_iso"]["noisy"]) + 1 + 2  # cameras + all, plus 2 region rows


def test_extra_metrics_merge(monkeypatch, frames, table):
    import types, sys
    mod = types.ModuleType("lumen_denoise.eval.detail")
    mod.crop_metrics = lambda c, x, y, K, r: {"hf_ratio": float(np.std(y) / np.std(c))}
    monkeypatch.setitem(sys.modules, "lumen_denoise.eval.detail", mod)
    rows = sb.run({"w": common.m_wiener}, frames[:1], table, isos=(1600,), kinds=("flat",))
    assert "hf_ratio" in rows[0]
    assert "hf_ratio" in sb.to_markdown(sb.summarize(rows))


def _ctx(table, frames):
    return common.Ctx(table=table, frames=frames, isos=(1600, 6400, 25600), quick=True)


def test_gate_pass_and_fail(frames, table):
    import time
    t = time.time()
    ok = sb.gate_checks(common.m_wiener, common.m_identity, _ctx(table, frames))
    assert time.time() - t < 15
    assert ok and all(c.status in ("PASS", "INFO") for c in ok), [c for c in ok if c.status == "FAIL"]
    bad = sb.gate_checks(common.m_identity, common.m_wiener, _ctx(table, frames))
    fails = {c.name.split("@")[0] for c in bad if c.status == "FAIL"}
    assert {"psnr_gain_vs_baseline", "psnr_gain_vs_noisy", "worst_region_vs_baseline", "ssim_vs_baseline"} <= fails
    # blur over-smooths detail: must fail the per-region check against wiener even where mean is close
    blur = sb.gate_checks(common.make_blur(2.0), common.m_wiener, _ctx(table, frames))
    assert any(c.name.startswith("worst_region") and c.status == "FAIL" and "detail" in c.note for c in blur)
    assert all(isinstance(c, common.Check) for c in ok + bad)


def test_gate_no_frames(table):
    out = sb.gate_checks(common.m_wiener, common.m_identity, _ctx(table, []))
    assert [c.status for c in out] == ["SKIP"]


def test_bench_cli_default_ps_matches_validate():
    import inspect, lumen_denoise.bench as b
    src = inspect.getsource(b.main)
    assert 'default=512' in src and common.CENTRE == 512


def test_noise_independent_of_kinds_filter(frames, table):
    seen = {}
    def spy(tag):
        def f(x, K, r):
            seen.setdefault(tag, []).append(x.copy()); return x
        return f
    sb.run({"all": spy("all")}, frames[:1], table, isos=(6400,), extra=False)
    sb.run({"flat": spy("flat")}, frames[:1], table, isos=(6400,), kinds=("flat",), extra=False)
    ki = [r["kind"] for r in regions.pick_regions(frames[0].clean)].index("flat")
    assert np.array_equal(seen["all"][ki], seen["flat"][0])


def test_tiny_crop_and_nan_model(table):
    f = common.Frame("t", "ILCE-7M4", np.random.default_rng(0).random((4, 5, 40)).astype(np.float32) * 0.3, True)
    rows = sb.run({"w": common.m_wiener}, [f], table, isos=(1600,), extra=False)
    assert rows and all(np.isfinite(r["psnr"]) for r in rows)
    nan = lambda x, K, r: np.full_like(x, np.nan)
    fr = common.clean_frames(synthetic=True, n_synth=2)
    out = sb.gate_checks(nan, common.m_wiener, common.Ctx(table=table, frames=fr, isos=(6400,), quick=True))
    assert all(c.status == "FAIL" for c in out)  # a NaN-emitting model must never pass


def test_gate_per_camera_regression(frames, table):
    # model = wiener on the A7 IV, but untouched on the GX85: the A7 IV gain must not hide the GX85 loss
    Kgx = table.params("DMC-GX85", 6400)[0]
    def model(x, K, r):
        return x if abs(K - Kgx) < 1e-12 else common.m_wiener(x, K, r)
    out = sb.gate_checks(model, common.m_identity, common.Ctx(table=table, frames=frames, isos=(6400,), quick=True))
    g = next(c for c in out if c.name == "psnr_gain_vs_noisy@6400")
    assert g.status == "FAIL" and "DMC-GX85" in g.note


def test_region_loss_is_per_camera():
    # A7 IV detail +1 dB, GX85 detail -1 dB: pooled over cameras that is 0, per camera the GX85 loss must show
    rows = [dict(method=m, camera=c, iso=6400, region="detail", psnr=p) for m, c, p in
            [("baseline", "ILCE-7M4", 40.0), ("model", "ILCE-7M4", 41.0),
             ("baseline", "DMC-GX85", 40.0), ("model", "DMC-GX85", 39.0)]]
    loss = sb.region_losses(rows, 6400)
    assert loss[("DMC-GX85", "detail")] == -1.0 and loss[("ILCE-7M4", "detail")] == 1.0
