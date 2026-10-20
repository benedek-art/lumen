"""Blind A/B page + tally: synthetic tiles, hand-made results, CPU only."""
import base64, itertools, json, re
import numpy as np
import pytest
from PIL import Image
from scipy.stats import binomtest
from lumen_denoise.eval import abtest
from lumen_denoise.eval.common import Ctx, NoiseTable, DEFAULT_CALIB

METHODS = ("original", "ours", "lightroom")
CROPS = ("crop0", "crop1", "crop2")


@pytest.fixture
def tiles(tmp_path):
    d = tmp_path / "ab_crops"
    rng = np.random.default_rng(0)
    for c in CROPS:
        for m in METHODS:
            (d / c).mkdir(parents=True, exist_ok=True)
            Image.fromarray(rng.integers(0, 255, (16, 16, 3), dtype=np.uint8)).save(d / c / f"{m}.png")
    json.dump({c: {"model": "ILCE-7M4", "iso": 6400, "kind": "detail"} for c in CROPS}, open(d / "index.json", "w"))
    return d


def _data(html):
    m = re.search(r"const D=(\{.*?\});\n", html)
    return json.loads(m.group(1))


def test_build_page(tiles, tmp_path):
    out = tmp_path / "ab.html"
    tr = abtest.build(tiles, out, seed=1)
    html = out.read_text()
    assert out.exists() and len(tr) == 9
    # all pairs per crop, each exactly once
    got = sorted((t["crop_id"], *sorted((t["left"], t["right"]))) for t in tr)
    assert got == sorted((c, *p) for c in CROPS for p in itertools.combinations(sorted(METHODS), 2))
    # guarantee: no method name appears anywhere in the page source (mapping is XOR+base64)
    for name in METHODS:
        assert name not in html
    no_b64 = re.sub(r"[A-Za-z0-9+/=]{40,}", "", html).lower()
    for name in METHODS:
        assert name not in no_b64
    # the obfuscated map decodes back to the true assignment (what the page reveals at the end)
    D = _data(html)
    key = bytes.fromhex(D["K"])
    mp = json.loads(abtest._xor(base64.b64decode(D["M"]), key))
    assert [(t["c"], mp[t["l"]], mp[t["r"]]) for t in D["T"]] == [(t["crop_id"], t["left"], t["right"]) for t in tr]
    assert all(v.startswith("data:image/png;base64,") for v in D["IMG"].values())
    assert len(D["IMG"]) == 9 and "ILCE-7M4 6400 detail" in D["T"][0]["info"]


def test_build_deterministic(tiles, tmp_path):
    a, b, c = (tmp_path / f"{n}.html" for n in "abc")
    abtest.build(tiles, a, seed=7); abtest.build(tiles, b, seed=7); abtest.build(tiles, c, seed=8)
    assert a.read_text() == b.read_text()
    assert a.read_text() != c.read_text()
    ta, tc = abtest.make_trials(abtest.discover(tiles), 7), abtest.make_trials(abtest.discover(tiles), 8)
    assert [(t["crop_id"], t["left"], t["right"]) for t in ta] != [(t["crop_id"], t["left"], t["right"]) for t in tc]
    assert sorted(t["trial_id"] for t in ta) == sorted(t["trial_id"] for t in tc)  # ids merge across builds


def test_focus_and_noembed(tiles, tmp_path):
    out = tmp_path / "f.html"
    tr = abtest.build(tiles, out, seed=0, focus="ours", embed=False)
    assert len(tr) == 6 and all("ours" in (t["left"], t["right"]) for t in tr)
    imgs = list((tmp_path / "f_img").glob("*.png"))
    assert len(imgs) == 9 and not any(m in p.name for p in imgs for m in METHODS)
    assert "ours" not in out.read_text()


def _rec(pairs, page=None, created="2026-01-01T00:00:00Z"):
    """pairs: list of (left, right, choice). Each call is its own page unless `page` is given."""
    global _NPAGE
    _NPAGE += 1
    return {"page": page or f"p{_NPAGE}", "created": created, "results": [{"trial_id": f"t{i}", "crop_id": f"c{i % 3}", "left": l, "right": r,
                                      "choice": c, "ms": 500} for i, (l, r, c) in enumerate(pairs)]}


def test_tally_counts(tmp_path):
    rs = ([("ours", "lightroom", "left")] * 7 + [("lightroom", "ours", "right")] * 5 + [("ours", "lightroom", "right")] * 3
          + [("lightroom", "ours", "tie")] * 2 + [("original", "ours", "right")] * 9 + [("original", "lightroom", "right")] * 6
          + [("original", "lightroom", "left")] * 1)
    p1, p2 = tmp_path / "ab_results_a.json", tmp_path / "ab_results_b.json"
    json.dump(_rec(rs[:10]), open(p1, "w")); json.dump(_rec(rs[10:]), open(p2, "w"))
    t = abtest.tally([p1, p2])
    assert t["n_trials"] == len(rs)
    s = t["ours_vs_lightroom"]
    assert (s["wins"], s["losses"], s["ties"], s["n"]) == (12, 3, 2, 15)
    assert s["p"] == pytest.approx(binomtest(12, 15, 0.5).pvalue, rel=1e-9)
    lo, hi = s["ci95"]
    assert lo < 12 / 15 < hi and lo > 0.5 - 0.05
    assert t["per_method"]["ours"] == {"wins": 21, "losses": 3, "ties": 2}
    assert t["per_method"]["original"] == {"wins": 1, "losses": 15, "ties": 0}
    assert t["win_rate"]["ours"]["lightroom"] == pytest.approx(0.8)
    assert t["win_rate"]["lightroom"]["original"] == pytest.approx(6 / 7)
    assert t["ranking"] == ["ours", "lightroom", "original"]
    assert t["ours_vs_original"]["wins"] == 9


_NPAGE = 0


def test_tally_dedupes_redownloads(tmp_path):
    # same page downloaded half-way and at the end: the overlap must count once, newest answer wins
    half = _rec([("ours", "lightroom", "right")] * 5, page="pg", created="2026-01-01T10:00:00Z")
    full = _rec([("ours", "lightroom", "left")] * 10, page="pg", created="2026-01-01T11:00:00Z")
    other = _rec([("ours", "lightroom", "left")] * 3, page="pg2")  # another judge/page: same ids, separate votes
    for n, d in (("b", half), ("a", full), ("c", other)):
        json.dump(d, open(tmp_path / f"ab_results_{n}.json", "w"))
    s = abtest.tally(sorted(tmp_path.glob("ab_results_*.json")))["ours_vs_lightroom"]
    assert (s["wins"], s["losses"], s["n"]) == (13, 0, 13)
    # malformed rows are ignored, not crashed on
    json.dump({"page": "z", "results": [{"choice": "left", "left": "ours", "right": "ours"}, {"choice": "x"}, 5]},
              open(tmp_path / "ab_results_d.json", "w"))
    assert abtest.tally(sorted(tmp_path.glob("ab_results_*.json")))["ours_vs_lightroom"]["n"] == 13


def test_sign_test_large_n():
    # many judges merged: must not overflow (math.comb * p**i did for n > ~1030)
    assert abtest.binom_two_sided(600, 1100) == pytest.approx(binomtest(600, 1100).pvalue, rel=1e-6)
    assert abtest.binom_two_sided(2500, 5000) == pytest.approx(1.0)


def test_page_does_not_leak_order(tiles, tmp_path):
    # image/mapping dict order must follow opaque ids, not alphabetical method order (else the 1st image per crop = lightroom)
    out = tmp_path / "o.html"
    abtest.build(tiles, out, seed=2)
    D = _data(out.read_text())
    assert list(D["IMG"]) == sorted(D["IMG"])
    html = out.read_text()
    assert "busy" in html and "e.repeat" in html  # double-press / key-repeat lock present


@pytest.mark.parametrize("k,n", [(0, 0), (0, 5), (3, 10), (5, 10), (9, 10), (14, 20), (20, 20), (31, 47)])
def test_sign_test_matches_scipy(k, n):
    ref = 1.0 if n == 0 else binomtest(k, n, 0.5).pvalue
    assert abtest.binom_two_sided(k, n) == pytest.approx(ref, rel=1e-9)
    assert abtest.binom_two_sided(k, n, 0.3) == pytest.approx(1.0 if n == 0 else binomtest(k, n, 0.3).pvalue, rel=1e-7)


def test_wilson():
    lo, hi = abtest.wilson(81, 263)  # textbook example: 0.255..0.366 (Newcombe 1998 style check)
    assert lo == pytest.approx(0.2553, abs=1e-3) and hi == pytest.approx(0.3662, abs=1e-3)
    assert abtest.wilson(0, 0) == (0.0, 1.0)


def test_bradley_terry_order():
    ms = ["a", "b", "c"]
    w = {"a": {"a": 0, "b": 9, "c": 10}, "b": {"a": 1, "b": 0, "c": 8}, "c": {"a": 0, "b": 2, "c": 0}}
    p = abtest.bradley_terry(w, ms)
    assert p["a"] > p["b"] > p["c"]
    assert np.prod(list(p.values())) == pytest.approx(1.0)


def _ctx(tmp_path):
    return Ctx(table=NoiseTable(DEFAULT_CALIB), frames=[], quick=True, out_dir=tmp_path / "gate")


def test_gate(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(abtest, "ROOT", tmp_path / "nowhere")
    c = abtest.gate_checks(None, None, _ctx(tmp_path))
    assert [x.status for x in c] == ["SKIP"] and "abtest build" in c[0].note
    json.dump(_rec([("ours", "lightroom", "left")] * 20 + [("lightroom", "ours", "left")] * 5
                   + [("original", "ours", "right")] * 4), open(tmp_path / "ab_results_1.json", "w"))
    c = {x.name: x for x in abtest.gate_checks(None, None, _ctx(tmp_path))}
    assert c["ab_ours_vs_lightroom"].status == "PASS" and c["ab_ours_vs_lightroom"].value == 0.8
    assert c["ab_ours_vs_original"].status == "INFO"
    json.dump(_rec([("ours", "lightroom", "left")] * 6), open(tmp_path / "ab_results_1.json", "w"))  # p<.05 but n<MIN_N
    assert abtest.gate_checks(None, None, _ctx(tmp_path))[0].status == "FAIL"
    json.dump(_rec([("ours", "lightroom", "left")] * 12 + [("ours", "lightroom", "right")] * 10),
              open(tmp_path / "ab_results_1.json", "w"))  # rate > .5 but not significant
    assert abtest.gate_checks(None, None, _ctx(tmp_path))[0].status == "FAIL"


def test_cli(tiles, tmp_path, capsys, monkeypatch):
    import sys
    out = tmp_path / "cli.html"
    monkeypatch.setattr(sys, "argv", ["abtest", "build", "--crops", str(tiles), "--out", str(out), "--seed", "3"])
    abtest.main()
    assert out.exists() and "9 trials" in capsys.readouterr().out
    r = tmp_path / "ab_results_x.json"
    json.dump(_rec([("ours", "lightroom", "left")] * 3), open(r, "w"))
    monkeypatch.setattr(sys, "argv", ["abtest", "tally", str(tmp_path / "ab_results*.json")])
    abtest.main()
    assert "ours vs lightroom: 3-0" in capsys.readouterr().out


def test_crops_ab_name():
    pytest.importorskip("rawpy")
    pytest.importorskip("torch")
    from lumen_denoise.crops import ab_name
    assert ab_name("original") == "original" and ab_name("Lightroom") == "lightroom"
    assert ab_name("blur:2.0") == "blur_2_0" and ab_name("A", ours="A") == "ours"
