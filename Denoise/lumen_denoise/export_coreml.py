"""Export the Denoiser to Core ML (mlprogram) with a fixed tile size.

    python -m lumen_denoise.export_coreml --weights weights/lumen_denoise.pt --tile 1024 \
        --out weights/LumenDenoise.mlpackage [--fp32] [--check]

Graph inputs (all fp32): noisy (1,4,T,T) normalized RGGB, std (1,1,T,T) noise-std map, and for
residual models s (1,1,1,1) = global noise-unit scale computed by the caller over the WHOLE image
(max(mean(std_map), 1e-5), as infer.py does), so tiles agree.
Residual models output residual (1,4,T,T) = s * net(cat(noisy/s, std/s)); the caller adds noisy in
fp32 (as infer.py does), since an fp16 add would round the whole image to fp16 (~4 DN in highlights).
Other models output denoised (1,4,T,T) = net(noisy, std).
With FLOAT16 compute precision the division by s must keep the net's inputs O(1..1e3); feeding
raw values with s ~ 1 or a tiny s overflows/underflows fp16 inside the graph.
Core ML prediction (and --check) only works on macOS.
"""
import argparse
import sys

import numpy as np
import torch
import torch.nn as nn

from .model import Denoiser


class Wrap(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.m, self.residual = net, bool(getattr(net, "residual", False))

    def forward(self, noisy, std, s=None):
        if self.residual:
            return s * self.m.net(torch.cat([noisy / s, std / s], 1))
        return self.m(noisy, std)


def inputs(tile, seed=0, K=1e-4, r=1.3e-7):
    from .train import std_map
    g = torch.Generator().manual_seed(seed)
    clean = torch.rand(1, 4, tile, tile, generator=g) * 0.5
    noisy = clean + torch.randn(clean.shape, generator=g) * torch.sqrt(K * clean + r)
    sm = std_map(noisy, K, r)
    s = sm.double().mean().clamp(min=1e-5).float().reshape(1, 1, 1, 1)
    return noisy, sm, s


def convert(net, tile, fp16=True):
    import coremltools as ct
    assert tile % 16 == 0, tile
    w = Wrap(net.float().eval()).eval()
    ex = inputs(tile)
    ex = ex if w.residual else ex[:2]
    names = ["noisy", "std", "s"][:len(ex)]
    with torch.no_grad():
        tr = torch.jit.trace(w, ex)
    return ct.convert(
        tr, convert_to="mlprogram",
        inputs=[ct.TensorType(name=n, shape=tuple(x.shape), dtype=np.float32) for n, x in zip(names, ex)],
        outputs=[ct.TensorType(name="residual" if w.residual else "denoised", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16 if fp16 else ct.precision.FLOAT32)


def parity(ml, net, tile, seed=1):
    """-> (max abs err, PSNR dB) of the denoised image, Core ML (CPU_ONLY) vs PyTorch fp32 on CPU,
    residual models with the fp32 add done here as in infer. macOS only."""
    import coremltools as ct
    if isinstance(ml, str):
        ml = ct.models.MLModel(ml, compute_units=ct.ComputeUnit.CPU_ONLY)
    w = Wrap(net.float().eval()).eval()
    noisy, sm, s = inputs(tile, seed)
    feed = {"noisy": noisy.numpy(), "std": sm.numpy()}
    args = (noisy, sm)
    if w.residual:
        feed["s"], args = s.numpy(), args + (s,)
    with torch.no_grad():
        ref = (noisy + w(*args) if w.residual else w(*args)).numpy()
    o = ml.predict(feed)
    got = noisy.numpy() + o["residual"] if w.residual else o["denoised"]
    err = float(np.abs(got - ref).max())
    mse = float(((got.astype(np.float64) - ref) ** 2).mean())
    return err, float(10 * np.log10(1 / max(mse, 1e-30)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="weights/lumen_denoise.pt")
    ap.add_argument("--tile", type=int, default=1024)
    ap.add_argument("--out", default="weights/LumenDenoise.mlpackage")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--fp16", dest="fp16", action="store_true", default=True)
    g.add_argument("--fp32", dest="fp16", action="store_false")
    ap.add_argument("--check", action="store_true", help="parity vs PyTorch after export (macOS)")
    a = ap.parse_args()
    from .infer import guard_output
    guard_output(a.out)  # realpath + casefold, same rule as infer
    net = Denoiser.from_state_dict(torch.load(a.weights, map_location="cpu"))
    ml = convert(net, a.tile, a.fp16)
    ml.save(a.out)
    print("saved", a.out, "residual" if net.residual else "direct", "fp16" if a.fp16 else "fp32")
    if a.check:
        if sys.platform != "darwin":
            raise SystemExit("--check skipped: Core ML prediction needs macOS")
        err, p = parity(a.out, net, a.tile)
        print("parity max_abs_err %.2e psnr %.1f dB" % (err, p))


if __name__ == "__main__":
    main()
