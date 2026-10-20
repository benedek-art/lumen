"""Export the trained denoiser to Core ML so Lumen can run it natively (no Python).

python scripts/export_coreml.py [--weights weights/lumen_denoise.pt] [--calib weights/calib.json]
                                [--out weights/lumen_denoise.mlpackage] [--no-verify]

Produces:
  weights/lumen_denoise.mlpackage    inputs  noisy (1,4,H,W) + std (1,1,H,W), output denoised (1,4,H,W),
                                     Float16 I/O, H/W flexible 16...2048 (default 1024)
  weights/lumen_denoise.coreml.json  model id / calib digest / I/O contract, read by Lumen's runner + cache

The model is Denoiser.forward verbatim, residual scale included: Lumen's Swift side only computes the
std map (RawDenoiseStdMap, identical to train.std_map) and does the tiling (identical to
infer.Engine.denoise_packed). H and W must be multiples of 16 (four 2x max-pools); padding to that is
the caller's job, exactly as in infer.py. See docs/COREML_EXPORT.md.
"""
import argparse, datetime, hashlib, json, sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from lumen_denoise.model import Denoiser  # noqa: E402

TRACE_SHAPE = (256, 256)
DIM_MIN, DIM_MAX, DIM_DEFAULT = 16, 2048, 1024
META_PREFIX = "com.lumen.denoise."


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Exported(torch.nn.Module):
    """forward(noisy, std) -> denoised with both inputs required. Denoiser.forward takes std_map as an
    optional kwarg; tracing through a wrapper pins the positional (noisy, std) signature Core ML sees."""

    def __init__(self, net: Denoiser):
        super().__init__()
        self.net = net

    def forward(self, noisy, std):
        return self.net(noisy, std)


def load(weights):
    sd = torch.load(weights, map_location="cpu")
    net = Denoiser.from_state_dict(sd).eval().float()
    if not net.residual:
        # The Swift contract (and the cache key's "full-strength result") assume the residual net;
        # a direct-output checkpoint would still convert, but say so loudly.
        print("warning: checkpoint is NOT residual (no residual_flag); exporting direct-output net", file=sys.stderr)
    return net, sd


def parse_shapes(text):
    """"1024x1024,512x768" -> [(1024, 1024), (512, 768)] (H x W in packed pixels)."""
    out = []
    for tok in text.split(","):
        h, w = (int(v) for v in tok.lower().split("x"))
        if h % 16 or w % 16:
            raise SystemExit(f"enumerated shape {tok} is not a multiple of 16")
        out.append((h, w))
    return out


def convert(net, ct, fp32_mean=True, enumerated=None):
    wrapped = Exported(net).eval()
    h, w = TRACE_SHAPE
    ex = (torch.rand(1, 4, h, w) * 0.2, torch.full((1, 1, h, w), 0.01))
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, ex)

    # One RangeDim object per axis, shared by both inputs, so the converter knows noisy and std have
    # the same H and W (cat along channels requires it). The multiple-of-16 constraint can't be
    # expressed here; the caller pads (reflect) like infer.py.
    if enumerated:
        # ANE fallback: the Neural Engine plans fixed/enumerated shapes, while RangeDim models often run
        # on the GPU. The default (first) shape should be the 1024x1024 production tile.
        def shapes(c):
            return ct.EnumeratedShapes(shapes=[(1, c, h, w) for h, w in enumerated], default=(1, c) + enumerated[0])
        noisy_shape, std_shape = shapes(4), shapes(1)
    else:
        H = ct.RangeDim(lower_bound=DIM_MIN, upper_bound=DIM_MAX, default=DIM_DEFAULT, symbol="H")
        W = ct.RangeDim(lower_bound=DIM_MIN, upper_bound=DIM_MAX, default=DIM_DEFAULT, symbol="W")
        noisy_shape, std_shape = ct.Shape(shape=(1, 4, H, W)), ct.Shape(shape=(1, 1, H, W))
    inputs = [
        ct.TensorType(name="noisy", shape=noisy_shape, dtype=np.float16),
        ct.TensorType(name="std", shape=std_shape, dtype=np.float16),
    ]
    outputs = [ct.TensorType(name="denoised", dtype=np.float16)]

    if fp32_mean:
        # s = mean(std) over a whole tile: 1M fp16 adds can lose precision or overflow (sum of 1024^2
        # stds ~0.05 is ~5e4, near fp16 max 65504) depending on the backend's accumulator. Keep that one
        # reduction in fp32; everything else (the convs) runs fp16.
        precision = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type != "reduce_mean")
    else:
        precision = ct.precision.FLOAT16

    return ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=inputs,
        outputs=outputs,
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS15,
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--weights", default=str(ROOT / "weights" / "lumen_denoise.pt"))
    ap.add_argument("--calib", default=str(ROOT / "weights" / "calib.json"))
    ap.add_argument("--out", default=str(ROOT / "weights" / "lumen_denoise.mlpackage"))
    ap.add_argument("--meta", default=None, help="metadata json (default: <out stem>.coreml.json next to --out)")
    ap.add_argument("--fp16-mean", action="store_true", help="also run the tile-mean reduction in fp16 (not recommended)")
    ap.add_argument("--enumerated", default=None, metavar="HxW,...",
                    help="export fixed enumerated shapes instead of the 16...2048 range (ANE fallback), e.g. 1024x1024,512x512")
    ap.add_argument("--no-verify", action="store_true", help="skip the post-export Core ML vs torch check (macOS only)")
    a = ap.parse_args()

    import coremltools as ct

    net, sd = load(a.weights)
    weights_sha = sha256(a.weights)
    calib_sha = sha256(a.calib) if Path(a.calib).exists() else ""
    if not calib_sha:
        print(f"warning: {a.calib} not found; calib_digest left empty", file=sys.stderr)
    model_id = weights_sha[:16]
    nf = int(sd["net.conv1_1.weight"].shape[0])

    enumerated = parse_shapes(a.enumerated) if a.enumerated else None
    ml = convert(net, ct, fp32_mean=not a.fp16_mean, enumerated=enumerated)

    meta = {
        "model_id": model_id,
        "weights_sha256": weights_sha,
        "weights_file": Path(a.weights).name,
        "calib_digest": calib_sha,
        "residual": bool(net.residual),
        "nf": nf,
        "inputs": {"noisy": [1, 4, "H", "W"], "std": [1, 1, "H", "W"]},
        "outputs": {"denoised": [1, 4, "H", "W"]},
        "dtype": "float16",
        "dim_range": None if enumerated else [DIM_MIN, DIM_MAX],
        "enumerated_shapes": [list(t) for t in enumerated] if enumerated else None,
        "dim_default": DIM_DEFAULT,
        "dim_multiple": 16,
        "tile": 1024,
        "overlap": 64,
        "fp32_mean": not a.fp16_mean,
        "minimum_deployment_target": "macOS15",
        "coremltools": ct.__version__,
        "torch": torch.__version__,
        "exported_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    }

    ml.short_description = "Lumen raw-domain denoiser: packed RGGB (black=0, white=1) + per-pixel noise std -> denoised"
    ml.author = "Lumen Denoise"
    ml.version = model_id
    ml.input_description["noisy"] = "Packed RGGB planes, normalized (raw-black)/(white-black), H,W multiples of 16"
    ml.input_description["std"] = "Per-pixel noise std map sqrt(K*avgpool3x3(mean_c(noisy)) + read_var)"
    ml.output_description["denoised"] = "Denoised packed RGGB planes, same normalization (full strength)"
    for k, v in meta.items():
        # user_defined_metadata is string -> string
        ml.user_defined_metadata[META_PREFIX + k] = v if isinstance(v, str) else json.dumps(v)

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    ml.save(str(out))
    meta_path = Path(a.meta) if a.meta else out.with_name(out.stem + ".coreml.json")
    meta_path.write_text(json.dumps(meta, indent=1) + "\n")
    print(json.dumps({"mlpackage": str(out), "meta": str(meta_path), "model_id": model_id, "calib_digest": calib_sha}))

    if a.no_verify:
        return
    if sys.platform != "darwin":
        print("note: not macOS, skipping Core ML prediction check (run scripts/coreml_parity.py on the Mac)")
        return
    verify(net, ml, enumerated or [(256, 256), (64, 48), (1024, 1024), (512, 768)])


def verify(net, ml, shapes):
    """Quick sanity check of the saved model on a few shapes, incl. non-square and the range ends.
    The real gate is scripts/coreml_parity.py (tiling + real RAWs + PSNR threshold)."""
    torch.manual_seed(0)
    for h, w in shapes:
        clean = torch.rand(1, 4, h, w) * 0.3
        std = torch.full((1, 1, h, w), 0.01) + torch.rand(1, 1, h, w) * 0.01
        noisy = clean + torch.randn_like(clean) * std
        with torch.no_grad():
            ref = net(noisy, std).numpy()
        got = ml.predict({"noisy": noisy.numpy().astype(np.float16), "std": std.numpy().astype(np.float16)})["denoised"]
        err = float(np.abs(got.astype(np.float32) - ref).max())
        print(json.dumps({"verify_shape": [h, w], "max_abs_err": err}))
        if not np.isfinite(got).all():
            raise SystemExit(f"Core ML output has non-finite values at {h}x{w} (fp16 overflow?)")


if __name__ == "__main__":
    main()
