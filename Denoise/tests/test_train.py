"""train.py integration: every new flag runs end to end on CPU, defaults == the B4 recipe, resume is bitwise."""
import json, math, os, random, signal
import numpy as np
import pytest
import torch
from lumen_denoise import train
from lumen_denoise.model import Denoiser

BASE = ["--iters", "6", "--bs", "2", "--ps", "32", "--nf", "8", "--val-isos", "1600,25600", "--val-ps", "32",
        "--ckpt-every", "2", "--seed", "0", "--residual"]
NAF = ["--arch", "nafnet", "--nafnet-width", "8", "--nafnet-enc", "1,1", "--nafnet-dec", "1,1", "--nafnet-middle", "1"]


@pytest.fixture
def ds(tmp_path):
    rng = np.random.default_rng(0)
    meta = {}
    for d, n in (("gt", 4), ("val", 2)):
        (tmp_path / d).mkdir()
        for k in range(n):
            stem = f"{d}{k}"
            np.save(tmp_path / d / f"{stem}.npy", (rng.random((4, 64, 64)) * 0.3).astype(np.float16))
            meta[stem] = "ILCE-7M4" if k % 2 == 0 else "DMC-GX85"
    json.dump(meta, open(tmp_path / "meta.json", "w"))
    isos = [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200]
    calib = {"ILCE-7M4": [[i, 1.654e-7 * i, 1e-12 * i * i + 2e-7] for i in isos],
             "DMC-GX85": [[i, 3.789e-7 * i, 4e-12 * i * i + 1e-6] for i in isos[1:-1]]}
    json.dump(calib, open(tmp_path / "calib.json", "w"))
    (tmp_path / "real").mkdir()
    rm = {}
    for k in range(3):
        np.save(tmp_path / "real" / f"r{k}_c0.npy", (rng.random((4, 40, 40)) * 0.2).astype(np.float16))
        rm[f"r{k}_c0"] = {"model": "ILCE-7M4", "iso": [6400, 12800, 51200][k], "frame": f"r{k}"}
    json.dump(rm, open(tmp_path / "real" / "real_meta.json", "w"))
    return tmp_path


def run(ds, out, *extra):
    argv = ["--gt", str(ds / "gt"), "--val", str(ds / "val"), "--meta", str(ds / "meta.json"),
            "--calib", str(ds / "calib.json"), "--out", str(ds / out), *BASE, *extra]
    train.main(argv)
    return ds / out


def load(p):
    return torch.load(p, map_location="cpu", weights_only=False)


def test_defaults_parse_to_b4():
    a = train.parser().parse_args(["--gt", "g", "--val", "v", "--out", "o"])
    assert (a.noise_ext, a.val_noise_ext, a.loss, a.iso_sampling, a.arch, a.ema, a.selfsup) == ("", "", "base", "loguniform", "unet", 0.0, "off")
    assert train._ints(a.val_isos) == train.VAL_ISOS == (400, 1600, 6400, 25600) and a.val_ps == 512 and a.seed is None


def _orig_batch(d, n, ps, table):
    """The pre-upgrade Data.batch body, verbatim, as the reference."""
    ys, ks, rs = [], [], []
    for _ in range(n):
        i = random.randrange(len(d.files)); a = d.arr[i]; _, h, w = a.shape
        y0, x0 = random.randrange(h - ps), random.randrange(w - ps)
        c = torch.from_numpy(np.array(a[:, y0:y0 + ps, x0:x0 + ps], np.float32))
        if random.random() < 0.5:
            c = c.transpose(1, 2)[[0, 2, 1, 3]]
        c = c * math.exp(random.uniform(math.log(0.15), 0))
        model = random.choices(list(train.CAM_WEIGHTS), list(train.CAM_WEIGHTS.values()))[0] if d.mix else d.meta[d.files[i].stem]
        lo, hi = table.iso_range(model)
        iso = math.exp(random.uniform(math.log(max(lo, d.iso_min)), math.log(hi)))
        K, r = table.params(model, iso)
        K *= random.uniform(0.85, 1.15); r *= math.exp(random.uniform(math.log(0.5), math.log(2.0)))
        if random.random() < d.star_p:
            c = train.add_stars(c, K, r)
        ys.append(c); ks.append(K); rs.append(r)
    y = torch.stack(ys); K = torch.tensor(ks).view(-1, 1, 1, 1); r = torch.tensor(rs).view(-1, 1, 1, 1)
    return train.add_noise(y, K, r).clamp(max=1), y, K, r


def test_default_batch_and_loss_match_original(ds):
    from lumen_denoise import losses
    from lumen_denoise.noise_ext import NoiseOpts
    meta, table = json.load(open(ds / "meta.json")), train.NoiseTable(ds / "calib.json")
    d = train.Data(ds / "gt", meta, mix=True); d.star_p = 0.5
    dev, train.DEV = train.DEV, "cpu"  # bit-equality needs one RNG: on a Mac DEV would be mps
    outs = []
    for f in (lambda: d.batch(3, 32, table), lambda: _orig_batch(d, 3, 32, table)):
        random.seed(1); torch.manual_seed(1); outs.append(f())
    for p, q in zip(*outs):
        assert torch.equal(p, q)
    d.noise_opts = NoiseOpts.parse("")  # explicit "off" is the same path
    random.seed(1); torch.manual_seed(1)
    assert all(torch.equal(p, q) for p, q in zip(d.batch(3, 32, table), outs[1]))
    assert len(d.last_iso) == len(d.last_model) == 3
    x, y = outs[0][0], outs[0][1]
    assert torch.equal(losses.make_loss("base")(x, y)[0], train.loss_fn(x, y))
    train.DEV = dev


def test_default_run_and_infer_load(ds):
    out = run(ds, "r0")
    log = open(out / "log.txt").read().splitlines()
    assert log[0].startswith("0 val {") and log[-1].startswith("6 val {1600:") and " mean " in log[-1]
    for f in ("best.pt", "last.pt", "ckpt.pt", "args.json"):
        assert (out / f).exists()
    m = Denoiser.from_state_dict(load(out / "best.pt")).eval()  # exactly what infer.Engine does
    x = torch.rand(1, 4, 32, 32) * 0.1
    assert m(x, train.std_map(x, 1e-4, 1e-6)).shape == x.shape


def test_refuses_to_clobber_ckpt(ds):
    run(ds, "r1")
    with pytest.raises(SystemExit, match="--resume"):
        run(ds, "r1")
    run(ds, "r1", "--fresh")
    assert (ds / "r1" / "ckpt.prev.pt").exists()


@pytest.mark.parametrize("extra", [
    ["--noise-ext", "all", "--val-noise-ext", "row,quant", "--iso-min", "100"],
    ["--loss", "base,fft:0.05,grad:0.1,nw:0.5", "--iso-sampling", "high"],
    ["--iso-sampling", "adaptive", "--loss", "charb"],
    ["--ema", "0.99", "--duty", "0.9"],
], ids=["noise_ext", "loss", "adaptive", "ema"])
def test_flags_run(ds, extra):
    out = run(ds, "rf", *extra)
    assert (out / "best.pt").exists()
    Denoiser.from_state_dict(load(out / "best.pt"))


def test_nafnet_run_and_infer_load(ds):
    out = run(ds, "rn", *NAF, "--ema", "0.9")
    sd = load(out / "best.pt")
    assert int(sd["arch_code"][0]) == 1 and all(v.device.type == "cpu" for v in sd.values())
    m = Denoiser.from_state_dict(sd).eval().half()  # infer.py casts to half
    assert m.arch == "nafnet" and m.arch_cfg.dtype == torch.long
    torch.save(Denoiser(nf=8, residual=True).state_dict(), ds / "unet.pt")
    with pytest.raises(SystemExit, match="NAFNet"):  # UNet weights cannot seed NAFNet: fail loudly
        run(ds, "rn2", *NAF, "--init", str(ds / "unet.pt"))
    run(ds, "rn3", *NAF, "--init", str(out / "best.pt"))  # NAFNet -> NAFNet fine-tune loads


@pytest.mark.parametrize("mode", ["r2r", "n2n"])
def test_selfsup_run(ds, mode, capsys):
    out = run(ds, "rs", "--selfsup", mode, "--real", str(ds / "real"), "--real-val", str(ds / "real"),
              "--real-val-n", "4", "--selfsup-bs", "2", "--selfsup-every", "2", "--selfsup-ramp", "3")
    log = open(out / "log.txt").read()
    assert "6 realval excess" in log


def test_init_finetune(ds):
    src = run(ds, "ri0")
    out = run(ds, "ri1", "--init", str(src / "best.pt"), "--selfsup", "r2r", "--real", str(ds / "real"), "--selfsup-start", "3")
    assert (out / "best.pt").exists()


@pytest.mark.parametrize("extra", [[], ["--ema", "0.9", "--iso-sampling", "adaptive", "--noise-ext", "row,gain,quant"]],
                         ids=["plain", "ema_adaptive_noise"])
def test_resume_bitwise(ds, extra):
    a = run(ds, "straight", *extra)
    with pytest.raises(SystemExit):  # changing --iters on resume is refused (OneCycle schedule)
        run(ds, "straight", *extra, "--resume", "--iters", "8")
    b = run(ds, "split", *extra, "--stop-after", "3")
    assert load(b / "ckpt.pt")["step"] == 3
    run(ds, "split", *extra, "--resume")
    sa, sb = load(a / "last.pt"), load(b / "last.pt")
    assert sa.keys() == sb.keys() and all(torch.equal(sa[k], sb[k]) for k in sa)
    ca, cb = load(a / "ckpt.pt"), load(b / "ckpt.pt")
    assert ca["step"] == cb["step"] == 6 and ca["best"] == cb["best"]
    if ca["extra"]["sampler"]:
        assert ca["extra"]["sampler"] == cb["extra"]["sampler"]


def test_signal_checkpoints_and_resumes(ds, monkeypatch):
    a = run(ds, "sig_a")
    orig, calls = train.Data.batch, {"n": 0}

    def batch(self, *k):
        calls["n"] += 1
        if calls["n"] == 3 and self.mix:
            os.kill(os.getpid(), signal.SIGUSR1)  # the Mac app's "pause"
        return orig(self, *k)

    monkeypatch.setattr(train.Data, "batch", batch)
    b = run(ds, "sig_b")
    assert load(b / "ckpt.pt")["step"] == 3
    monkeypatch.setattr(train.Data, "batch", orig)
    run(ds, "sig_b", "--resume")
    sa, sb = load(a / "last.pt"), load(b / "last.pt")
    assert all(torch.equal(sa[k], sb[k]) for k in sa)
    assert signal.getsignal(signal.SIGUSR1) == signal.SIG_DFL  # handlers restored after main()


def test_noise_ext_params_zero_black_offset_means_unmeasured():
    """calibrate_rows.py writes black_offset_sd 0.0 at ISOs without dark frames: fall back, don't zero it."""
    from lumen_denoise.noise_ext import ExtParams
    P = ExtParams({"ILCE-7M4": {"iso": [800, 1600, 3200], "black_offset_sd": [0.0, 1e-4, 0.0]},
                   "DMC-GX85": {"iso": [800], "black_offset_sd": [0.0]}})
    assert P.get("ILCE-7M4", "black_offset_sd", 3200, 1.0) == pytest.approx(1e-4)
    assert P.get("DMC-GX85", "black_offset_sd", 800, 0.01) == pytest.approx(0.05 * 0.01)  # default black_frac


def test_stop_after_is_per_session(ds):
    """Regression: --stop-after counted absolute steps, so a rerun with --resume did one step and stopped."""
    out = run(ds, "chunk", "--stop-after", "2")
    assert load(out / "ckpt.pt")["step"] == 2
    run(ds, "chunk", "--stop-after", "2", "--resume")
    assert load(out / "ckpt.pt")["step"] == 4
    run(ds, "chunk", "--stop-after", "2", "--resume")
    assert load(out / "ckpt.pt")["step"] == 6


def test_init_keeps_own_arch_cfg(ds):
    """Regression: --init copied the source NAFNet's arch_cfg (middle / tlc) into the new net's best.pt."""
    src = run(ds, "naf0", *NAF)
    out = run(ds, "naf1", *NAF[:-1], "2", "--nafnet-tlc", "0", "--init", str(src / "best.pt"))
    sd = load(out / "best.pt")
    m = Denoiser.from_state_dict(sd)  # infer.py path: must rebuild the TRAINED config
    assert len(m.net.middle) == 2 and int(sd["arch_cfg"][-1]) == 0


def test_init_other_width_no_crash(ds, capsys):
    """Regression: the zero-pad branch assumed only in-channels differ -> RuntimeError for a wider net."""
    src = run(ds, "naf_w8", *NAF)
    out = run(ds, "naf_w16", *[("16" if v == "8" else v) for v in NAF], "--init", str(src / "best.pt"))
    assert (out / "best.pt").exists() and "init: " in capsys.readouterr().out


def test_resume_refuses_changed_tlc(ds):
    run(ds, "naf_tlc", *NAF, "--stop-after", "2")
    with pytest.raises(SystemExit, match="arch_cfg"):
        run(ds, "naf_tlc", *NAF, "--resume", "--nafnet-tlc", "0")


def test_resume_loads_ckpt_on_cpu(ds, monkeypatch):
    """Regression: map_location=DEV put Adam's 'step' tensors on MPS (one .item() sync per param per step)."""
    from lumen_denoise import ckpt as C
    seen, orig = [], C.load_ckpt
    def spy(*k, **kw):
        seen.append(kw.get("map_location", "cpu")); return orig(*k, **kw)
    monkeypatch.setattr(C, "load_ckpt", spy)
    run(ds, "cpu_ck", "--stop-after", "2")
    run(ds, "cpu_ck", "--resume")
    assert seen == ["cpu"]
