"""Core ML vs PyTorch parity gate (macOS only: Core ML prediction needs the Mac runtime).

python scripts/coreml_parity.py [RAW ...] [--mlmodel weights/lumen_denoise.mlpackage]
       [--weights weights/lumen_denoise.pt] [--calib weights/calib.json]
       [--compute-units ALL,CPU_AND_GPU] [--min-psnr 50] [--fixtures DIR | --no-fixtures]
       [--skip-random] [--json REPORT]

Gate cases go through infer.Engine.denoise_packed itself (not a copy of it), so tiling, reflect
padding, the fp16 std map and the feathering are what the CLI ships; only the network call differs.
Backends:
  torch32  Denoiser fp32 on MPS/CPU (the reference)
  torch16  Denoiser .half() on MPS, i.e. what `python -m lumen_denoise.infer` runs today
  coreml:<units>  the exported mlpackage, once per --compute-units entry
denoise_packed hands every backend fp16 inputs (`.half()` in infer.py); the Core ML model takes fp16
inputs too, so torch32 differs only in network precision.

Cases: (a) random synthetic tiles at ISO 100/1600/6400/25600, model-level and tiled; (b) every RAW
given on the command line, full image with the production tile=1024/ov=64. Reports max abs error and
PSNR in train.tone() space. The gate (P6 in docs/LUMEN_INTEGRATION.md): exit 1 if any Core ML result
is non-finite or below --min-psnr dB (default 50) vs torch32, fixture cases included.

Fixtures for the Swift runner test (skip with --no-fixtures). Default dir: coreml_fixtures/ next to
--mlmodel. Lumen's macOS test loads the model from env LUMEN_DENOISE_MLMODEL, reads manifest.json from
the dir in env LUMEN_DENOISE_FIXTURES, runs RawDenoiseCoreMLRunner on every case and requires
max abs <= suggested_tolerance.max_abs_vs_expected_coreml (2e-3) against expected_coreml, and at least
suggested_tolerance.min_psnr_tone_vs_expected_torch32 dB against expected_torch32. It skips when either
variable is unset.

Unlike the gate cases, the fixtures use the fp32 train.std_map (what Lumen's RawDenoiseStdMap computes,
and what training used), not infer.py's fp16 one: at ISO <= 100 `K*sig + r` is subnormal in fp16 and
the fp16 std map is 5-8% off. Each case is computed at two settings: the first camera in calib.json at
ISO 6400, and ILCE-7M4 at ISO 100 (the low-ISO case, names suffixed _iso100).

manifest.json (written by write_fixtures below):
  {
    "format": 1,
    "model_id": "<16 hex>",          # com.lumen.denoise.model_id of --mlmodel
    "calib_digest": "<64 hex>",      # com.lumen.denoise.calib_digest of --mlmodel
    "weights_sha256": "<64 hex>",    # of --weights (the torch32 reference)
    "compute_units": "ALL",          # coremltools name used for expected_coreml
    "min_psnr": 50.0,
    "layout": "...", "std_map": "...", "note": "...",
    "suggested_tolerance": {"max_abs_vs_expected_coreml": 0.002,
                            "min_psnr_tone_vs_expected_torch32": 50.0},
    "cases": [
      {"name": "model_32x48", "kind": "model", "camera": "ILCE-7M4", "iso": 6400,
       "K": <float>, "read_var": <float>,
       "files": {"noisy": F, "std": F, "expected_torch32": F, "expected_coreml": F},
       "metrics_coreml_vs_torch32": {"max_abs": <float>, "psnr_tone": <float or null if identical>}},
      {"name": "tiled_200x232_t128_o16", "kind": "tiled", "camera": ..., "iso": ..., "K": ...,
       "read_var": ..., "tile": 128, "overlap": 16,
       "files": {"packed": F, "expected_torch32": F, "expected_coreml": F}, "metrics_...": {...}},
      ...
    ]
  }
  F = {"npy": "<name>.npy", "bin": "<name>.bin", "shape": [4, H, W] or [1, H, W], "dtype": "float32-le"}
  .bin is headerless little-endian float32 in C order (planar channel-major), file paths are relative
  to the fixture dir. Cases: model_32x48, tiled_200x232_t128_o16, tiled_40x56_t1024_o64, and the same
  three with the _iso100 suffix (omitted with a warning if calib.json has no ILCE-7M4 entry).
  A "model" case is one predictTile call on (noisy, std) with H, W already multiples of 16; a "tiled"
  case is RawDenoiseCoreMLRunner.denoise(packed:..., params: (K, read_var), tile:, overlap:).
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
LOW_ISO_CAMERA, LOW_ISO = "ILCE-7M4", 100  # fixture case where infer.py's fp16 std map is subnormal


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


def fp32_std(backend, K, rv):
    """Backend wrapper that replaces infer.py's fp16 std map with the fp32 train.std_map, computed on
    the (fp16-rounded) padded tile denoise_packed hands the network. This is what Lumen does:
    RawDenoiseStdMap in Float32 on the padded tile, cast to Float16 only at the model input."""
    def f(noisy, std):
        return backend(noisy, std_map(noisy.float(), K, rv))
    return f


def json_metrics(m):
    # psnr_tone is +inf for identical arrays; strict JSON (Swift's JSONSerialization) rejects Infinity
    return {k: (None if isinstance(v, float) and not math.isfinite(v) else v) for k, v in m.items()}


FIXTURE_CASES = {  # name: (kind, h, w, tile, overlap, seed)
    "model_32x48": ("model", 32, 48, None, None, 101),
    "tiled_200x232_t128_o16": ("tiled", 200, 232, 128, 16, 102),   # several tiles, clamped last row/col
    "tiled_40x56_t1024_o64": ("tiled", 40, 56, 1024, 64, 103),     # sub-tile: reflect pad 40x56 -> 48x64
}


def write_fixtures(d, backends, ref_name, cml_name, settings, meta):
    """settings: [(suffix, camera, iso, K, read_var)]. Every FIXTURE_CASES entry is written once per
    setting, named <case><suffix>. Returns the manifest (see the module docstring for its format)."""
    d.mkdir(parents=True, exist_ok=True)
    cases = []
    for si, (suffix, camera, iso, K, rv) in enumerate(settings):
        for base, (kind, h, w, tile, ov, seed) in FIXTURE_CASES.items():
            name = base + suffix
            p = synthetic(h, w, K, rv, seed=seed + 1000 * si)
            c = {"name": name, "kind": kind, "camera": camera, "iso": iso, "K": K, "read_var": rv}
            if kind == "model":
                # one forward on an exact multiple-of-16 shape, fp32 train.std_map supplied
                t = torch.from_numpy(p)[None]
                s = std_map(t, K, rv)
                c["files"] = {"noisy": save_array(d, f"{name}_noisy", p),
                              "std": save_array(d, f"{name}_std", s[0].numpy())}
                r = backends[ref_name](t, s).float()[0].cpu().numpy()
                m = backends[cml_name](t, s).float()[0].cpu().numpy()
            else:
                # the shipping tiler, with the fp32 std map Lumen computes
                c["tile"], c["overlap"] = tile, ov
                c["files"] = {"packed": save_array(d, f"{name}_packed", p)}
                r = tiled(fp32_std(backends[ref_name], K, rv), p, K, rv, tile, ov)
                m = tiled(fp32_std(backends[cml_name], K, rv), p, K, rv, tile, ov)
            c["files"]["expected_torch32"] = save_array(d, f"{name}_expected_torch32", r)
            c["files"]["expected_coreml"] = save_array(d, f"{name}_expected_coreml", m)
            metrics = compare(m, r)
            metrics["finite"] = bool(np.isfinite(m).all())
            c["metrics_coreml_vs_torch32"] = json_metrics(metrics)
            cases.append(c)

    manifest = {
        "format": 1,
        **meta,
        "layout": "planar channel-major (4,H,W) RGGB, normalized (raw-black)/(white-black); std is (1,H,W)",
        "std_map": "float32 train.std_map (Lumen's RawDenoiseStdMap), cast to float16 at the model input",
        "note": "tiled cases use infer.Engine.denoise_packed with the fp32 std map on each padded tile",
        "suggested_tolerance": {
            # Swift -> Core ML vs Python -> Core ML: same model and same fp32 std map; inputs differ only
            # in that Python's std map sees the fp16-rounded tile, plus compute-unit nondeterminism
            "max_abs_vs_expected_coreml": 2e-3,
            "min_psnr_tone_vs_expected_torch32": meta["min_psnr"],
        },
        "cases": cases,
    }
    (d / "manifest.json").write_text(json.dumps(manifest, indent=1, allow_nan=False) + "\n")
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
    ap.add_argument("--no-fixtures", action="store_true", help="do not write the Swift runner fixtures")
    ap.add_argument("--skip-random", action="store_true", help="skip the synthetic gate cases (RAWs and fixtures only)")
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
        # identity as the Swift runner sees it: the package's own metadata, else the sidecar json
        ml_meta = dict(ct.models.MLModel(a.mlmodel, skip_model_load=True).user_defined_metadata)
        meta_path = Path(a.mlmodel).with_name(Path(a.mlmodel).stem + ".coreml.json")
        side = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        settings = [("", cam, 6400) + tuple(table_params(table, cam, 6400))]
        if LOW_ISO_CAMERA in table.t:
            settings.append(("_iso100", LOW_ISO_CAMERA, LOW_ISO) + tuple(table_params(table, LOW_ISO_CAMERA, LOW_ISO)))
        else:
            print(f"warning: {LOW_ISO_CAMERA} not in {a.calib}; low-ISO fixtures skipped", file=sys.stderr)
        mf = write_fixtures(d, backends, "torch32", cml_names[0], settings, {
            "model_id": ml_meta.get("com.lumen.denoise.model_id", side.get("model_id", report["weights_sha256"][:16])),
            "calib_digest": ml_meta.get("com.lumen.denoise.calib_digest", side.get("calib_digest", "")),
            "weights_sha256": report["weights_sha256"],
            "compute_units": cml_names[0].split(":", 1)[1],
            "min_psnr": a.min_psnr})
        for c in mf["cases"]:
            m = c["metrics_coreml_vs_torch32"]
            psnr = m["psnr_tone"]  # None means identical
            if not m["finite"] or (psnr is not None and psnr < a.min_psnr):
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
