"""Release gate end-to-end on small synthetic scenes (CPU, no photos). python -m pytest tests/test_eval_gate.py -q"""
import json, subprocess, sys
from pathlib import Path
import pytest
from lumen_denoise.eval import common, gate
from lumen_denoise.eval.common import Check

ROOT = Path(__file__).resolve().parents[1]
FAST = ["--synthetic", "--quick", "--synth-size", "384", "--isos", "6400",
        "--real-list", "", "--lowiso-list", "", "--astro-list", ""]  # never touch the Mac's real RAW lists in tests


def _ctx(tmp_path, isos=(6400,)):
    fr = [common.Frame(f"s{i}", common.CAMERAS[i % 2], common.synthetic_scene(384, 384, common.SEED + i), True)
          for i in range(2)]
    return common.Ctx(common.NoiseTable(), fr, isos=isos, real_files=[], lowiso_files=[], quick=True,
                      out_dir=tmp_path / "gate", model_name="m", baseline_name="b")


def _fails(checks, sec=None):
    return [c for c in checks if c.status == "FAIL" and (sec is None or c.section == sec)]


def test_wiener_vs_identity_end_to_end(tmp_path, capsys):
    code = gate.main(["--model", "wiener", "--baseline", "identity", *FAST, "--out", str(tmp_path)])
    out = capsys.readouterr().out
    assert "RELEASE: NOT A RELEASE - synthetic smoke run" in out and "LIGHTROOM CLAIM: NOT PROVEN" in out
    assert "section" in out and "threshold" in out  # the table header
    d = json.load(open(tmp_path / "wiener_vs_identity.json"))
    assert (tmp_path / "wiener_vs_identity.md").read_text().startswith("# Release gate")
    secs = {c["section"] for c in d["checks"]}
    assert {"synthetic", "detail", "real-noise", "real-noise (synthetic proxy)", "low-iso", "stars", "a/b"} <= secs
    assert not [c for c in d["checks"] if c["name"] == "module crashed"]
    # wiener really denoises: every synthetic PSNR row passes vs identity; real-photo rows SKIP on a CPU box
    assert all(c["status"] == "PASS" for c in d["checks"] if c["section"] == "synthetic")
    assert all(c["status"] == "SKIP" for c in d["checks"] if c["section"] == "real-noise")
    # honest result: the crude filter fails whiteness / shadow texture, so the smoke run is a FAIL (exit 1)
    assert d["verdict"]["fails"] and code == 1 and d["verdict"]["exit"] == 1


def test_identity_vs_wiener_fails(tmp_path):
    ctx = _ctx(tmp_path)
    checks, _ = gate.run_gate(common.m_identity, common.m_wiener, ctx, ["synthetic", "detail", "real-noise"], log=None)
    v = gate.verdict(checks, True, ["synthetic", "detail", "real-noise"])
    assert v["release"] == "FAIL" and v["exit"] == 1
    names = {c.name for c in _fails(checks)}
    assert "psnr_gain_vs_noisy@6400" in names and "method_noise@6400" in names


def test_blur_vs_wiener_fails_detail(tmp_path):
    ctx = _ctx(tmp_path)
    checks, _ = gate.run_gate(common.make_blur(2.0), common.m_wiener, ctx, ["synthetic", "detail"], log=None)
    assert gate.verdict(checks, True, ["synthetic", "detail"])["exit"] == 1
    det = {c.name for c in _fails(checks, "detail")}
    assert {"hf_ratio@6400", "struct_removed@6400", "gmsd@6400"} <= det


def test_zero_init_residual_net_runs(tmp_path, capsys):
    torch = pytest.importorskip("torch")
    from lumen_denoise.model import Denoiser
    pt = tmp_path / "zero.pt"
    torch.save(Denoiser(residual=True).state_dict(), pt)
    out = tmp_path / "rep"
    code = gate.main(["--model", f"net:{pt}", "--baseline", "wiener", *FAST, "--only", "synthetic,detail", "--out", str(out)])
    assert code == 1
    d = json.load(open(next(out.glob("*_vs_wiener.json"))))
    assert not [c for c in d["checks"] if c["name"] == "module crashed"]
    st = {c["name"]: c["status"] for c in d["checks"]}
    gain = next(c for c in d["checks"] if c["name"] == "psnr_gain_vs_noisy@6400")
    assert st["psnr_gain_vs_noisy@6400"] == "FAIL" and abs(gain["value"]) < 0.05   # zero-init residual = identity
    assert st["method_noise@6400"] == "FAIL"


def test_crashing_module_is_a_fail_row(tmp_path, monkeypatch):
    def boom(m, b, ctx):
        raise RuntimeError("kaput")
    monkeypatch.setitem(gate.RUNNERS, "stars", boom)
    checks, _ = gate.run_gate(common.m_identity, common.m_identity, _ctx(tmp_path), ["stars", "a/b"], log=None)
    c = [c for c in checks if c.section == "stars"]
    assert len(c) == 1 and c[0].status == "FAIL" and c[0].name == "module crashed" and "kaput" in c[0].note


def _rows(status="PASS", real=True):
    r = [Check(s, "x", 1.0, ">= 0", status) for s in gate.MANDATORY]
    if real:
        r.append(Check("low-iso", "psnr_vs_input_real", 50.0, ">= 45", "PASS"))
    return r


def test_verdict_rules():
    v = gate.verdict(_rows(), False)
    assert v["release"] == "PASS" and v["exit"] == 0
    assert v["lightroom"] == "NOT PROVEN" and any("A/B" in m for m in v["lightroom_missing"])
    ab = [Check("a/b", "ab_ours_vs_lightroom", 0.8, "", "PASS"), Check("a/b", "ab_photos", 9, "", "PASS")]
    assert gate.verdict(_rows() + ab, False)["lightroom"] == "PROVEN"
    assert gate.verdict(_rows() + ab, True)["lightroom"] == "NOT PROVEN"          # synthetic never proves it
    few = [ab[0], Check("a/b", "ab_photos", 3, "", "FAIL")]
    v = gate.verdict(_rows() + few, False)                                        # too few photos: claim fails,
    assert v["exit"] == 0 and v["lightroom"] == "NOT PROVEN" and "ab_photos" in v["lightroom_missing"][0]  # release not
    assert gate.verdict(_rows("FAIL"), False)["exit"] == 1
    v = gate.verdict(_rows(real=False), False)
    assert v["release"] == "NOT ENOUGH DATA" and v["exit"] == 2
    skip = [c if c.section != "real-noise" else Check("real-noise", "x", None, "", "SKIP", "no files") for c in _rows()]
    assert gate.verdict(skip, False)["exit"] == 2                                  # mandatory section all SKIP
    assert gate.verdict(_rows(), False, ["synthetic", "detail"])["exit"] == 2      # --only partial run
    assert gate.verdict(_rows(), True)["exit"] == 2                                # procedural frames are not data


def test_ab_photo_count(tmp_path, monkeypatch):
    from lumen_denoise.eval import abtest
    monkeypatch.setattr(abtest, "ROOT", tmp_path)   # never pick up the user's real reports/ab_results*.json on the Mac
    monkeypatch.chdir(tmp_path)
    out = tmp_path / "reports" / "gate"
    out.mkdir(parents=True)
    res = [dict(trial_id=f"t{i}", crop_id=f"DSC{i % 3}_detail", left="ours", right="lightroom", choice="left")
           for i in range(25)]
    json.dump({"page": "p", "created": "2026", "results": res}, open(out.parent / "ab_results_x.json", "w"))
    ctx = _ctx(tmp_path); ctx.out_dir = out
    c = gate.ab_photo_checks(ctx)
    assert c[0].value == 3 and c[0].status == "FAIL"
    rows = gate.run_gate(None, None, ctx, ["a/b"], log=None)[0]
    assert {r.name: r.status for r in rows} == {"ab_ours_vs_lightroom": "PASS", "ab_photos": "FAIL"}


def test_only_and_cli_exit_code(tmp_path):
    with pytest.raises(SystemExit):
        gate.normalize_only("nope")
    assert gate.normalize_only("bench,noref,ab") == ["synthetic", "real-noise", "a/b"]
    p = subprocess.run([sys.executable, "-m", "lumen_denoise.eval.gate", "--model", "wiener", "--baseline", "identity",
                        "--only", "a/b", "--val", str(tmp_path / "none"), "--out", str(tmp_path)],
                       cwd=ROOT, capture_output=True, text=True, timeout=120)
    assert p.returncode == 2, p.stderr      # no held-out data, nothing failed: not enough data
    assert "LIGHTROOM CLAIM: NOT PROVEN" in p.stdout


def test_release_needs_full_run_both_cameras_and_real_lowiso():
    assert gate.verdict(_rows(), False, quick=True)["exit"] == 2                     # --quick is never a release
    v = gate.verdict(_rows(), False, cams_missing=["DMC-GX85"])
    assert v["exit"] == 2 and any("DMC-GX85" in m for m in v["missing"])
    skip_real = _rows(real=False) + [Check("low-iso", "psnr_vs_input_real", None, ">= 45", "SKIP")]
    assert gate.verdict(skip_real, False)["exit"] == 2                               # SKIPped *_real rows are not data
    ab = [Check("a/b", "ab_ours_vs_lightroom", 0.8, "", "PASS")]                     # photo count unknown: not proven
    assert gate.verdict(_rows() + ab, False)["lightroom"] == "NOT PROVEN"


def test_bad_calib_and_unrunnable_method_exit_2(tmp_path, monkeypatch, capsys):
    assert gate.main(["--model", "wiener", "--baseline", "identity", *FAST, "--calib", str(tmp_path / "no.json"),
                      "--out", str(tmp_path)]) == 2
    assert "cannot read noise calibration" in capsys.readouterr().err
    def broken(x, K, r):
        raise ModuleNotFoundError("No module named 'bm3d'")
    real_get = common.get_method
    monkeypatch.setattr(common, "get_method", lambda s: broken if s == "bm3d" else real_get(s))
    assert gate.main(["--model", "bm3d", "--baseline", "identity", *FAST, "--out", str(tmp_path)]) == 2
    assert "cannot load method" in capsys.readouterr().err and not list(tmp_path.glob("*.json"))


@pytest.fixture(autouse=True)
def _no_astro_env(monkeypatch):
    monkeypatch.delenv("LUMEN_ASTRO_LIST", raising=False)   # stars falls back to it for real night shots
