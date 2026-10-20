"""Time a backbone BEFORE committing hours of training to it (run on the Mac, takes ~1-2 min).

python -m lumen_denoise.speedcheck --arch nafnet --preset s [--steps 50 --bs 8 --ps 256]

1) inference: eval().half() like infer.py, 12 tiles of 1x5x1024x1024 (= 33 MP), network time only
   (CLI adds ~3.2 s for raw decode / DNG on the M4); budget: < ~6.5 s network.
2) training: --steps fwd+bwd+AdamW steps at the real shape; prints s/step (x 1/duty for wall time)
   and the MPS driver memory. > ~10 GB on a 16 GB Mac: use --bs 4 or a smaller preset.
Wall-time, not MACs: NAFNet's depthwise conv / LayerNorm are memory-bound, MACs understate them."""
import argparse, time
import torch
from .model import Denoiser

DEV = "mps" if torch.backends.mps.is_available() else "cpu"


def _sync():
    if DEV == "mps": torch.mps.synchronize()


def build(a):
    if a.arch == "unet":
        return Denoiser(nf=a.nf, residual=True, zero_init=False)
    return Denoiser(residual=True, zero_init=False, arch="nafnet", preset=a.preset, tlc=a.ps)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arch", choices=("unet", "nafnet"), default="nafnet")
    ap.add_argument("--preset", choices=("s", "m", "l"), default="s")
    ap.add_argument("--nf", type=int, default=48)
    ap.add_argument("--steps", type=int, default=50); ap.add_argument("--bs", type=int, default=8)
    ap.add_argument("--ps", type=int, default=256); ap.add_argument("--tile", type=int, default=1024)
    ap.add_argument("--tiles", type=int, default=12); ap.add_argument("--duty", type=float, default=0.6)
    a = ap.parse_args(argv)
    half = DEV != "cpu"  # CPU fp16 conv is slow / unsupported on some builds
    net = build(a).to(DEV).eval()
    net = net.half() if half else net
    dt = torch.float16 if half else torch.float32
    x = (torch.rand(1, 4, a.tile, a.tile, device=DEV) * 0.2).to(dt)
    s = torch.full_like(x[:, :1], 0.01)
    with torch.no_grad():
        net(x, s); _sync()  # warm-up / kernel compile
        t = time.time()
        for _ in range(a.tiles): net(x, s)
        _sync(); ti = time.time() - t
    print(f"infer {a.arch}{'' if a.arch == 'unet' else ' ' + a.preset}: {ti:.2f} s network per {a.tiles} x {a.tile}^2 "
          f"tiles ({'fp16' if half else 'fp32'} on {DEV}); budget ~6.5 s", flush=True)
    net = build(a).to(DEV).train()
    opt = torch.optim.AdamW(net.parameters(), 2e-4)
    x = torch.rand(a.bs, 4, a.ps, a.ps, device=DEV) * 0.2
    s = torch.full_like(x[:, :1], 0.01)
    y = x * 0.9
    times = []
    for i in range(a.steps + 2):
        t = time.time()
        loss = (net(x, s) - y).abs().mean()
        opt.zero_grad(set_to_none=True); loss.backward(); opt.step(); _sync()
        if i >= 2: times.append(time.time() - t)  # skip warm-up
    st = sorted(times)[len(times) // 2]
    mem = f"{torch.mps.driver_allocated_memory() / 2 ** 30:.1f} GB MPS driver memory" if DEV == "mps" else "(CPU: see RSS)"
    print(f"train bs {a.bs} ps {a.ps}: {st:.3f} s/step median -> {st / a.duty:.3f} s/step at --duty {a.duty} "
          f"(12k steps ~{12000 * st / a.duty / 3600:.1f} h); {mem}", flush=True)


if __name__ == "__main__":
    main()
