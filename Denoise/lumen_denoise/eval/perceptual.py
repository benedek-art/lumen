"""Optional LPIPS (Zhang et al., CVPR 2018) on packed RGGB crops, CPU. Returns None when unavailable.

python -m lumen_denoise.eval.perceptual        # prints whether LPIPS can run here
Enable inside detail.crop_metrics with LUMEN_LPIPS=1 (off by default so the suite stays fast).

Licence findings (checked on lpips-0.1.4 wheel, 2026-10):
- `lpips` pip package (github.com/richzhang/PerceptualSimilarity): BSD-2-Clause; the wheel ships the
  learned linear-layer weights (lpips/weights/v0.1/{alex,vgg,squeeze}.pth) under the same licence.
- The backbone (AlexNet by default) comes from torchvision (code BSD-3-Clause). Its ImageNet-trained
  weights are fetched by torchvision from download.pytorch.org on first construction, i.e. NOT shipped
  with lpips; their terms follow the ImageNet dataset terms (research use), which is fine for an
  offline evaluation metric on the user's Mac but they must not be bundled into Lumen.
Hence: never import torch/lpips at module import time, never download implicitly. The net is built
only if the AlexNet checkpoint is already in the torch hub cache, or LUMEN_LPIPS_DOWNLOAD=1.
"""
import os
from pathlib import Path
import numpy as np

ALEX_CKPT = "alexnet-owt-7be5be79.pth"   # torchvision AlexNet_Weights.IMAGENET1K_V1 file name
WB = (2.0, 1.0, 1.5)                     # crude daylight multipliers R,G,B for a viewable render
_net = None


def available():
    """lpips + torchvision importable and backbone weights cached (or download explicitly allowed)."""
    try:
        import importlib.util as u
        if u.find_spec("lpips") is None or u.find_spec("torchvision") is None:
            return False
        import torch
        cached = (Path(torch.hub.get_dir()) / "checkpoints" / ALEX_CKPT).exists()
        return cached or os.environ.get("LUMEN_LPIPS_DOWNLOAD") == "1"
    except Exception:
        return False


def to_rgb(x):
    """Packed RGGB (4,h,w) linear -> (3,h,w) display-ish RGB in [0,1]: R, mean(G1,G2), B, WB, gamma 2.2.
    lpips_distance then scales both by the clean render's 99.5th pct so dark crops are not judged as black."""
    x = np.asarray(x, np.float32)
    rgb = np.stack([x[0], 0.5 * (x[1] + x[2]), x[3]]) * np.array(WB, np.float32)[:, None, None]
    return np.clip(np.clip(rgb, 0, None) ** (1 / 2.2), 0, 1)


def lpips_distance(clean, out):
    """LPIPS(alex, v0.1) between renders of clean and out (same normalisation for both); None if unavailable."""
    global _net
    if not available():
        return None
    import torch, lpips
    if _net is None:
        _net = lpips.LPIPS(net="alex", verbose=False).eval()
    a, b = to_rgb(clean), to_rgb(out)
    s = max(float(np.percentile(a, 99.5)), 1e-3)
    ta = torch.from_numpy(np.clip(a / s, 0, 1) * 2 - 1)[None]
    tb = torch.from_numpy(np.clip(b / s, 0, 1) * 2 - 1)[None]
    with torch.no_grad():
        return float(_net(ta, tb).item())


if __name__ == "__main__":
    print("lpips available:", available())
