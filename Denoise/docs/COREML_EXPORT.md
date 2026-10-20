# Core ML export and parity

How the trained PyTorch denoiser becomes `lumen_denoise.mlpackage`, the model Lumen runs natively
(no Python) in its RAW stage, and how we prove the Core ML model matches PyTorch before Lumen ships it.

Two scripts:

| Script | Runs on | Does |
|---|---|---|
| `scripts/export_coreml.py` | anywhere (prediction check: macOS only) | weights `.pt` -> `.mlpackage` + `.coreml.json` |
| `scripts/coreml_parity.py` | macOS only | Core ML vs torch through the shipping tiler; PSNR gate; Swift test fixtures |

## What is exported

The model is `Denoiser.forward` from `lumen_denoise/model.py`, residual scale included:

```
s        = clamp(mean(std over C,H,W), min=1e-5)      # one scalar per tile
denoised = noisy + s * UNet(cat(noisy / s, std / s))
```

| | name | shape | dtype |
|---|---|---|---|
| input | `noisy` | (1, 4, H, W) packed RGGB, `(raw - black) / (white - black)` | Float16 |
| input | `std` | (1, 1, H, W) `sqrt(K * avgpool3x3(mean_c(noisy)) + read_var)` | Float16 |
| output | `denoised` | (1, 4, H, W), same normalization, full strength | Float16 |

H and W are flexible, 16...2048 (default 1024), and **must be multiples of 16** (four 2x max-pools).
Core ML cannot express "multiple of 16", so the caller reflect-pads, exactly like
`infer.Engine.denoise_packed`. Everything outside the network stays in Swift, mirroring the Python:

| Python | Swift (LumenCore, Linux-tested) |
|---|---|
| `train.NoiseTable` + `infer.Engine.noise_params` (ISO clamp, log-log interp) | `RawDenoiseNoiseTable` |
| `train.std_map` (zero-padded 3x3 mean / 9) | `RawDenoiseStdMap` |
| `infer.Engine.denoise_packed` (tile 1024, overlap 64, feathering) | `RawDenoiseTilePlan` / `RawDenoiseTiler` |
| `raw.pack` + `prepare.to_rggb` | `RawDenoisePacking` |
| `strength * d + (1 - strength) * p` | `RawDenoiseTiler.blend` |

Precision: convolutions run in fp16 (as `infer.py` already does on MPS with `.half()`). The one
exception is the tile mean `s`: `reduce_mean` over up to 1024x1024 stds is kept in fp32
(`FP16ComputePrecision(op_selector=...)`), because an fp16 accumulator summing ~1M values of ~0.05 lands
near the fp16 maximum (65504) and loses the low bits long before that. That single fp32 op is cheap but
cannot run on the Neural Engine; see troubleshooting if that matters.

`lumen_denoise.coreml.json` (written next to the package, also copied into the model's
`user_defined_metadata` under `com.lumen.denoise.*`):

| key | meaning |
|---|---|
| `model_id` | first 16 hex of sha256(weights `.pt`). Goes into `RawDenoiseCacheKey.modelID` |
| `calib_digest` | full sha256 hex of `calib.json`. Goes into `RawDenoiseCacheKey.calibDigest` |
| `weights_sha256`, `nf`, `residual` | provenance |
| `dim_range` / `enumerated_shapes`, `dim_multiple`, `tile`, `overlap` | shape contract for the runner |
| `coremltools`, `torch`, `exported_at` | toolchain used |

Changing the weights or the calibration therefore invalidates every cached denoised CFA, which is the
point: a cached result is only reusable if it came from the same network and the same noise model.

## Steps on the Mac (M4)

Use the project venv (training data and weights never leave the Mac).

```sh
cd ~/Projects/lumen-denoise          # or <lumen repo>/Denoise
.venv/bin/pip install "coremltools==9.0"
```

coremltools 9.0 is tested up to torch 2.7. A newer torch prints
`Torch version X has not been tested with coremltools` — harmless as long as conversion finishes (it
does with torch 2.14 on Linux). If conversion fails with an op error, export from a separate venv with
`torch==2.7.0` (the `.pt` state dict loads in either).

### 1. Export

```sh
.venv/bin/python scripts/export_coreml.py \
    --weights weights/lumen_denoise.pt --calib weights/calib.json \
    --out weights/lumen_denoise.mlpackage
```

Expected output (plus coremltools progress bars, the torch.jit deprecation warning, and a harmless
`RuntimeWarning: overflow encountered in cast`, which is the clamp's `max=inf` being written as fp16 inf):

```
{"mlpackage": ".../weights/lumen_denoise.mlpackage", "meta": ".../weights/lumen_denoise.coreml.json", "model_id": "<16 hex>", "calib_digest": "<64 hex>"}
{"verify_shape": [256, 256], "max_abs_err": ...}
{"verify_shape": [64, 48], "max_abs_err": ...}
{"verify_shape": [1024, 1024], "max_abs_err": ...}
{"verify_shape": [512, 768], "max_abs_err": ...}
```

`max_abs_err` should be around 1e-3 or below (fp16 has ~5e-4 resolution near 0.5). A non-finite
output aborts the script. This is only a smoke test; step 2 is the gate.

### 2. Parity gate

```sh
.venv/bin/python scripts/coreml_parity.py \
    data/samples/A7404922-2.ARW data/samples/P1100829.RW2 \
    --compute-units ALL,CPU_AND_GPU,CPU_ONLY --json reports/coreml_parity.json
```

Pick at least one high-ISO RAW per camera (the A7 IV at 12800+, the GX85 at 3200+): shadows at high
ISO are where fp16 and the tone curve are least forgiving.

What it does, per backend (`torch32` reference, `torch16` = today's CLI, `coreml:<units>`):

- random synthetic tiles (shadows, near-clip highlights, a hard line) at ISO 100/1600/6400/25600 from
  the first camera in `calib.json`, model-level at 256², 64x48, 512x768, 1024², and a 1300x1900 image
  through the tiler;
- every RAW on the command line, full image, production tile 1024 / overlap 64.

All tiled runs call `infer.Engine.denoise_packed` itself with the backend swapped in as `self.net`, so
the tiling, reflect padding, fp16 std map and feathering are the shipping code, not a copy. One JSON line
per case, then:

```
{"result": "PASS", "min_psnr_gate": 50.0, "worst_coreml_psnr_tone": <dB>, "failures": 0}
```

(A Linux dry run that emulates fp16 output rounding gives ~87-90 dB; real fp16 convolutions will be
lower. Anything comfortably above 50 is fine.)

The gate: every Core ML output must be finite and at least `--min-psnr` (default 50 dB) vs torch32 in
`train.tone()` space. For scale, `torch16_vs_torch32` shows what the current CLI already ships; Core ML
should be in the same range. Exit status 1 on failure.

### 3. Fixtures for the Swift runner test

The parity run also writes `weights/coreml_fixtures/` (override with `--fixtures`, skip with
`--no-fixtures`): `manifest.json` plus, per array, a `.npy` and a headerless little-endian float32
`.bin` (C order) that Swift can read with `Data` -> `[Float]`.

| case | kind | what it pins |
|---|---|---|
| `model_32x48` | model | one forward: `noisy`, `std` (fp32 `train.std_map`), expected output |
| `tiled_200x232_t128_o16` | tiled | several tiles, clamped last row/column of tiles, feathering |
| `tiled_40x56_t1024_o64` | tiled | image smaller than a tile: reflect pad 40x56 -> 48x64 and crop |

Each case has `expected_torch32` and `expected_coreml` (Core ML through the Python tiler, same
compute units as the first `--compute-units` entry) plus `K`, `read_var`, `tile`, `overlap`.
`suggested_tolerance` in the manifest: max abs 2e-3 vs `expected_coreml`, and the PSNR gate vs
`expected_torch32`. The Swift side differs from the Python Core ML run only by the std map's rounding
(Swift fp32 -> fp16, infer.py computes it in fp16) and compute-unit nondeterminism.

Run the macOS runner test against them:

```sh
LUMEN_DENOISE_MLMODEL=$PWD/weights/lumen_denoise.mlpackage \
LUMEN_DENOISE_FIXTURES=$PWD/weights/coreml_fixtures \
swift test --filter RawDenoise                   # from the Lumen repo root; the runner test skips without these
```

Neither the package nor the fixtures belong in git (weights stay on the Mac). The Lumen app loads the
package at runtime; compile it once with `xcrun coremlcompiler compile lumen_denoise.mlpackage <dir>`
or let `MLModel.compileModel(at:)` do it on first use and cache the `.mlmodelc`.

## Troubleshooting

**The model never runs on the Neural Engine (RangeDim vs EnumeratedShapes).** The ANE plans
fixed or enumerated shapes; flexible `RangeDim` models are commonly placed on the GPU instead, and the
fp32 `reduce_mean` is always CPU/GPU. Check placement with Xcode's Core ML performance report (open the
`.mlpackage`, Performance tab) or `MLComputePlan` (macOS 14.4+). If the ANE is wanted, export enumerated
shapes:

```sh
.venv/bin/python scripts/export_coreml.py --enumerated 1024x1024,512x512 --out weights/lumen_denoise_ane.mlpackage
```

This costs nothing for full frames: the tiler clamps every tile to the full 1024 whenever the image is
at least 1024 packed px in that dimension, and both cameras exceed that (A7 IV ~3516x2344, GX85
~2296x1724 packed), so only 1024x1024 tiles occur. Smaller images (heavy crops, tests) produce
other shapes; the runner must then either use the flexible model or pad up to an enumerated shape.
Only switch if parity still passes with `--compute-units CPU_AND_NE` and it is actually faster; GPU
fp16 on the M4 is already the path `infer.py` measures at ~6 s per 33 MP frame.

**fp16 overflow (`non-finite` in verify or parity).** The network sees `noisy / s` and `std / s`. With
real calibrations `s >= sqrt(read_var)` (~3.5e-4 on the A7 IV at base ISO), so `noisy / s` stays
below ~3e3, far from 65504. It overflows only if `s` collapses toward the 1e-5 clamp, which in fp16 is
already subnormal (fp16's smallest normal is 6.1e-5): a camera entry with `read_var ~ 0`, or a std map
computed on the wrong scale (e.g. DN instead of 0..1). Fix the input, not the model: check the
`calib.json` entry and that Swift normalizes like `raw.load`. Do not raise the clamp in the export; it
must stay identical to `model.py` or parity against the trained net is meaningless. `--fp16-mean`
exists only to measure what the fp32 mean buys; keep it off.

**Parity fails only for `CPU_AND_NE` or only on real RAWs.** Compare against `torch16_vs_torch32` on
the same case. If torch16 fails too, it is a property of the weights in fp16 (re-train with fp16-aware
evaluation, or export with more ops kept fp32 via `op_selector`); if only Core ML fails, re-export with
`--enumerated`/different compute units and file the case.

**`Failed to load _MLModelProxy` / prediction raises on Linux.** Expected: coremltools converts on
Linux but predicts only on macOS. Export works anywhere; run parity on the Mac.

**Wrong I/O names or shapes in Swift.** Opening the package in Xcode (or
`coremltools.utils.load_spec(path).description`) must show inputs `noisy`, `std` and output `denoised`, Float16, ranges 16...2048. The
names are the contract with `RawDenoiseCoreMLRunner.swift`.
