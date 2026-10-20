"""Core ML vs PyTorch parity gate (macOS only: Core ML prediction needs the Mac runtime).

python scripts/coreml_parity.py [RAW ...] [--mlmodel weights/lumen_denoise.mlpackage]
       [--weights weights/lumen_denoise.pt] [--calib weights/calib.json]
       [--compute-units ALL,CPU_ONLY] [--min-psnr 50] [--fixtures weights/coreml_fixtures]

Every backend goes through infer.Engine.denoise_packed itself (not a copy of it), so tiling, reflect
padding, the fp16 std map and the feathering are byte-for-byte what the CLI ships; only the network call
differs. Backends:
  torch32  Denoiser fp32 on MPS/CPU (the reference)
  torch16  Denoiser .half() on MPS, i.e. what `python -m lumen_denoise.infer` runs today
  coreml:<units>  the exported mlpackage
Note denoise_packed hands every backend fp16 inputs (`.half()` in infer.py); the Core ML model takes
fp16 inputs too, so torch32 differs only in network precision.

Cases: (a) random synthetic tiles at several shapes/ISOs, model-level and tiled; (b) every RAW given on
the command line, full image with the production tile=1024/ov=64. Reports max abs error and PSNR in
train.tone() space; exits 1 if any Core ML result is below --min-psnr dB vs torch32 or non-finite.

Also writes small golden fixtures (float32 .npy + raw little-endian .bin + manifest.json) for Lumen's
Swift Core ML runner test, which loads the model from LUMEN_DENOISE_MLMODEL and the fixtures from
LUMEN_DENOISE_FIXTURES (default: coreml_fixtures/ next to the model). See docs/COREML_EXPORT.md.
"""
import argparse, hashlib, json, math, sys, time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from lumen_denoise import raw as rawio  # noqa: E402
from lumen_denoise.infer import Engine, DEV  # noqa: E402
from lumen_denoise.model import Denoiser  # noqa: E402
from lumen_denoise.prepare import to_rggb  # noqa: E402
from lumen_denoise.train import NoiseTable, std_map, add_noise  # noqa: E402

TRIAL_ISOS = (100, 1600, 6400, 25600)


# ---------------------------------------------------------------- metrics

def tone_np(x):
    # numpy twin of train.tone (gamma-ish perceptual space the training loss and bench use)
    return (np.clip(x, 0, None) + 1e-3) ** (1 / 2.2)


def compare(a, b):
    a = a.astype(np.float64); b = b.astype(np.float64)
    mse = float(np.mean((tone_np(a) - tone_np(b)) ** 2))
    return {"max_abs": float(np.abs(a - b).max()),
            "psnr_tone": float("inf") if mse == 0 else 10 * math.log10(1.0 / mse)}


# ---------------------------------------------------------------- backends
# Each backend is net-shaped: f(noisy, std) -> tensor (1,4,H,W). denoise_packed calls it as self.net.

def torch_backend(net, dtype):
    @torch.no_grad()
    def f(noisy, std):
        return net(noisy.to(DEV, dtype), std.to(DEV, dtype))
    return f


def coreml_backend(ml):
    def f(noisy, std):
        out = ml.predict({"noisy": noisy.detach().cpu().numpy().astype(np.float16),
                          "std": std.detach().cpu().numpy().astype(np.float16)})["denoised"]
        return torch.from_numpy(np.asarray(out, dtype=np.float32))
    return f


def tiled(backend, p, K, rv, tile=1024, ov=64):
    """Run infer.Engine.denoise_packed with `backend` as the network: the shipping tiler, unmodified."""
    eng = Engine.__new__(Engine)
    eng.net, eng.table = backend, None
    return Engine.denoise_packed(eng, p, K, rv, tile=tile, ov=ov)


# ---------------------------------------------------------------- inputs

def synthetic(h, w, K, rv, seed):
    """Smooth-ish clean packed RGGB (gradients + blobs + a few hard edges and near-black/near-white
    areas, where fp16 and the tone curve are least forgiving) plus calibrated Poisson-Gaussian noise."""
    g = torch.Generator().manual_seed(seed)
    base = F.interpolate(torch.rand(1, 1, max(h // 32, 2), max(w // 32, 2), generator=g), (h, w),
                         mode="bilinear", align_corners=False)
    tint = torch.tensor([1.0, 0.8, 0.8, 0.6]).view(1, 4, 1, 1) * (0.7 + 0.3 * torch.rand(1, 4, 1, 1, generator=g))
    clean = base * tint * 0.6
    clean[..., : h // 8, :] *= 0.01                     # deep shadow band
    clean[..., h // 2: h // 2 + h // 10, : w // 3] = 0.98  # near-clip highlight block
    clean[..., :, w // 2: w // 2 + 2] += 0.3             # thin bright line
    torch.manual_seed(seed)
    noisy = add_noise(clean.clamp(0, 1), K, rv)
    return noisy[0].numpy().astype(np.float32)


def table_params(table, model, iso):
    lo, hi = table.iso_range(model)
    return table.params(model, float(np.clip(iso, lo, hi)))


# ---------------------------------------------------------------- fixtures

def save_array(d, name, a):
    a = np.ascontiguousarray(a, dtype="<f4")
    np.save(d / f"{name}.npy", a)
    a.tofile(d / f"{name}.bin")  # headerless float32 LE, C order: trivial to read from Swift
    return {"npy": f"{name}.npy", "bin": f"{name}.bin", "shape": list(a.shape), "dtype": "float32-le"}


def write_fixtures(d, backends, ref_name, cml_name, K, rv, meta):
    d.mkdir(parents=True, exist_ok=True)
    cases = []

    # model-level: one forward on an exact multiple-of-16 shape, std map supplied (fp32 train.std_map)
    p = synthetic(32, 48, K, rv, seed=101)
    t = torch.from_numpy(p)[None]
    s = std_map(t, K, rv)
    c = {"name": "model_32x48", "kind": "model", "K": K, "read_var": rv,
         "files": {"noisy": save_array(d, "model_32x48_noisy", p),
                   "std": save_array(d, "model_32x48_std", s[0].numpy())}}
    outs = {k: f(t, s).float()[0].cpu().numpy() for k, f in backends.items() if k in (ref_name, cml_name)}
    c["files"]["expected_torch32"] = save_array(d, "model_32x48_expected_torch32", outs[ref_name])
    c["files"]["expected_coreml"] = save_array(d, "model_32x48_expected_coreml", outs[cml_name])
    c["metrics_coreml_vs_torch32"] = compare(outs[cml_name], outs[ref_name])
    cases.append(c)

    # tiled: multi-tile with clamped last tiles (200x232, tile 128, ov 16) and a single sub-tile image
    # that needs reflect padding to 16 (40x56 -> 48x64), through the shipping tiler
    for name, (h, w, tile, ov, seed) in {"tiled_200x232_t128_o16": (200, 232, 128, 16, 102),
                                         "tiled_40x56_t1024_o64": (40, 56, 1024, 64, 103)}.items():
        p = synthetic(h, w, K, rv, seed=seed)
        c = {"name": name, "kind": "tiled", "K": K, "read_var": rv, "tile": tile, "overlap": ov,
             "files": {"packed": save_array(d, f"{name}_packed", p)}}
        r = tiled(backends[ref_name], p, K, rv, tile, ov)
        m = tiled(backends[cml_name], p, K, rv, tile, ov)
        c["files"]["expected_torch32"] = save_array(d, f"{name}_expected_torch32", r)
        c["files"]["expected_coreml"] = save_array(d, f"{name}_expected_coreml", m)
        c["metrics_coreml_vs_torch32"] = compare(m, r)
        cases.append(c)

    manifest = {
        **meta,
        "layout": "planar channel-major (4,H,W) RGGB, normalized (raw-black)/(white-black); std is (1,H,W)",
        "note": "tiled cases use infer.Engine.denoise_packed (std map computed in fp16 on the padded tile)",
        "suggested_tolerance": {
            # Swift -> Core ML vs Python -> Core ML: same model, inputs differ only by std-map rounding
            # (Swift fp32 vs infer.py fp16) and compute-unit nondeterminism
            "max_abs_vs_expected_coreml": 2e-3,
            "min_psnr_tone_vs_expected_torch32": meta["min_psnr"],
        },
        "cases": cases,
    }
    (d / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    return manifest


# ---------------------------------------------------------------- main

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raws", nargs="*", help="real RAW files (.ARW/.RW2) to run full-image")
    ap.add_argument("--mlmodel", default=str(ROOT / "weights" / "lumen_denoise.mlpackage"))
    ap.add_argument("--weights", default=str(ROOT / "weights" / "lumen_denoise.pt"))
    ap.add_argument("--calib", default=str(ROOT / "weights" / "calib.json"))
    ap.add_argument("--compute-units", default="ALL",
                    help="comma list of coremltools ComputeUnit names: ALL, CPU_AND_GPU, CPU_AND_NE, CPU_ONLY")
    ap.add_argument("--min-psnr", type=float, default=50.0, help="gate: Core ML vs torch32, dB in tone space")
    ap.add_argument("--fixtures", default=None, help="fixture dir (default: coreml_fixtures/ next to --mlmodel)")
    ap.add_argument("--no-fixtures", action="store_true")
    ap.add_argument("--skip-random", action="store_true")
    ap.add_argument("--json", default=None, help="also write the full report here")
    a = ap.parse_args()

    if sys.platform != "darwin":
        raise SystemExit("coreml_parity.py needs macOS (Core ML runtime); export works anywhere, prediction does not")
    import coremltools as ct

    sd = torch.load(a.weights, map_location="cpu")
    net32 = Denoiser.from_state_dict(sd).eval().float().to(DEV)
    backends = {"torch32": torch_backend(net32, torch.float32)}
    try:
        net16 = Denoiser.from_state_dict(sd).eval().to(DEV).half()
        f16 = torch_backend(net16, torch.float16)
        f16(torch.zeros(1, 4, 16, 16, dtype=torch.float16), torch.full((1, 1, 16, 16), 0.01, dtype=torch.float16))
        backends["torch16"] = f16
    except Exception as e:  # fp16 conv is MPS-only on some torch builds
        print(f"note: torch16 backend unavailable on {DEV}: {e}", file=sys.stderr)
    units = [u.strip() for u in a.compute_units.split(",") if u.strip()]
    for u in units:
        ml = ct.models.MLModel(a.mlmodel, compute_units=getattr(ct.ComputeUnit, u))
        backends[f"coreml:{u}"] = coreml_backend(ml)
    cml_names = [k for k in backends if k.startswith("coreml:")]

    table = NoiseTable(a.calib)
    cam = next(iter(table.t))
    report = {"mlmodel": a.mlmodel, "weights_sha256": sha256(a.weights), "device": DEV, "cases": []}
    failures = []

    def run_case(name, fn):
        outs, secs = {}, {}
        for k, f in backends.items():
            t0 = time.time(); outs[k] = fn(f); secs[k] = round(time.time() - t0, 3)
        row = {"case": name, "seconds": secs}
        for k in outs:
            if k == "torch32":
                continue
            m = compare(outs[k], outs["torch32"])
            m["finite"] = bool(np.isfinite(outs[k]).all())
            row[f"{k}_vs_torch32"] = m
            if k.startswith("coreml:") and (not m["finite"] or m["psnr_tone"] < a.min_psnr):
                failures.append((name, k, m))
        report["cases"].append(row)
        print(json.dumps(row), flush=True)

    if not a.skip_random:
        for i, iso in enumerate(TRIAL_ISOS):
            K, rv = table_params(table, cam, iso)
            for h, w in [(256, 256), (64, 48), (512, 768), (1024, 1024)]:
                p = synthetic(h, w, K, rv, seed=1000 * i + h + w)
                t = torch.from_numpy(p)[None]
                s = std_map(t, K, rv)
                run_case(f"model {cam} ISO{iso} {h}x{w}", lambda f: f(t, s).float()[0].cpu().numpy())
            p = synthetic(1300, 1900, K, rv, seed=77 + i)  # 2x2 tiles + clamped edge tiles
            run_case(f"tiled {cam} ISO{iso} 1300x1900", lambda f: tiled(f, p, K, rv))

    for src in a.raws:
        r = rawio.load(src)
        p = to_rggb(rawio.pack(r.cfa), r.pattern)
        eng = Engine.__new__(Engine)
        eng.table = table
        K, rv = eng.noise_params(r, p)
        run_case(f"raw {Path(src).name} {r.model} ISO{r.iso:g} {p.shape[1]}x{p.shape[2]}",
                 lambda f: tiled(f, p, K, rv))

    if not a.no_fixtures:
        d = Path(a.fixtures) if a.fixtures else Path(a.mlmodel).resolve().parent / "coreml_fixtures"
        K, rv = table_params(table, cam, 6400)
        meta_path = Path(a.mlmodel).with_name(Path(a.mlmodel).stem + ".coreml.json")
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        mf = write_fixtures(d, backends, "torch32", cml_names[0], K, rv, {
            "model_id": meta.get("model_id", report["weights_sha256"][:16]),
            "camera": cam, "iso": 6400, "compute_units": cml_names[0].split(":", 1)[1],
            "min_psnr": a.min_psnr})
        for c in mf["cases"]:
            m = c["metrics_coreml_vs_torch32"]
            if m["psnr_tone"] < a.min_psnr:
                failures.append((f"fixture {c['name']}", cml_names[0], m))
        print(json.dumps({"fixtures": str(d), "cases": [c["name"] for c in mf["cases"]]}))

    report["failures"] = [{"case": n, "backend": k, **m} for n, k, m in failures]
    if a.json:
        Path(a.json).write_text(json.dumps(report, indent=1) + "\n")
    worst = min((r[k]["psnr_tone"] for r in report["cases"] for k in r if k.startswith("coreml:")), default=None)
    print(json.dumps({"result": "FAIL" if failures else "PASS", "min_psnr_gate": a.min_psnr,
                      "worst_coreml_psnr_tone": worst, "failures": len(failures)}))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
