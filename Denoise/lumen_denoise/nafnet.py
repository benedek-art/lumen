"""NAFNet-style backbone (Chen et al., "Simple Baselines for Image Restoration", ECCV 2022),
written from the paper: LayerNorm + 1x1/depthwise convs + SimpleGate + simplified channel
attention, no other nonlinearity. Original implementation (MIT-compatible); no repo code copied.
Why: on SIDD it beats a plain conv baseline by ~0.7 dB at equal MACs, and the paper's raw
(PMRID 4Scenes) model gained +0.29 dB over PMRID at slightly fewer MACs."""
import torch
import torch.nn as nn
import torch.nn.functional as F


class LayerNorm2d(nn.Module):
    """Per-pixel LayerNorm over channels, plain ops (no custom autograd => MPS/fp16 safe).
    Statistics in fp32 so fp16 inference can't overflow on large activations."""

    def __init__(self, c, eps=1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(c)); self.bias = nn.Parameter(torch.zeros(c)); self.eps = eps

    def forward(self, x):
        xf = x.float()
        mu = xf.mean(1, keepdim=True)
        var = (xf - mu).pow(2).mean(1, keepdim=True)
        y = ((xf - mu) * torch.rsqrt(var + self.eps)).to(x.dtype)
        return y * self.weight.view(1, -1, 1, 1) + self.bias.view(1, -1, 1, 1)


def simple_gate(x):
    """Split channels in half and multiply: a nonlinearity with no activation function."""
    a, b = x.chunk(2, 1)
    return a * b


def local_sca(h, conv, k):
    """SCA with a local ~k x k mean instead of the tile-global one (TLC, Chu et al. ECCV 2022):
    big inference tiles then see train-patch-sized statistics, so no tile-size mismatch/seams.
    Cheap: k/4 block means -> 4x4 shifted box on that grid (integral image, fp32, window kept
    inside the image) -> 1x1 conv on the grid -> bilinear upsample (conv commutes with it)."""
    _, _, H, W = h.shape
    b = max(k // 4, 1); ph, pw = (-H) % b, (-W) % b
    g = F.avg_pool2d(F.pad(h, (0, pw, 0, ph), mode="replicate") if ph or pw else h, b).float()
    gh, gw = g.shape[2:]
    S = F.pad(g.cumsum(2).cumsum(3), (1, 0, 1, 0))
    def idx(n):
        kk = min(4, n); i0 = (torch.arange(n, device=h.device) - kk // 2).clamp(0, n - kk)
        return i0, i0 + kk, kk
    y0, y1, ky = idx(gh); x0, x1, kx = idx(gw)
    r0, r1 = S[:, :, y0], S[:, :, y1]
    m = conv(((r1[..., x1] - r1[..., x0] - r0[..., x1] + r0[..., x0]) / (ky * kx)).to(h.dtype))
    return F.interpolate(m, size=(H + ph, W + pw), mode="bilinear", align_corners=False)[:, :, :H, :W]


class NAFBlock(nn.Module):
    """Spatial branch: LN -> 1x1 (x2) -> dw3x3 -> gate -> SCA -> 1x1; channel branch:
    LN -> 1x1 (x2) -> gate -> 1x1. Branch scales start at 0, so every block is identity at init."""

    def __init__(self, c, dw_expand=2, ffn_expand=2, win=0):
        super().__init__()
        self.win = win  # eval-time SCA window (0 = always global pooling)
        d, f = c * dw_expand, c * ffn_expand
        self.norm1 = LayerNorm2d(c)
        self.pw1 = nn.Conv2d(c, d, 1)
        self.dw = nn.Conv2d(d, d, 3, padding=1, groups=d)
        self.sca = nn.Conv2d(d // 2, d // 2, 1)  # SCA: global avg pool -> 1x1 -> multiply
        self.pw2 = nn.Conv2d(d // 2, c, 1)
        self.norm2 = LayerNorm2d(c)
        self.ff1 = nn.Conv2d(c, f, 1)
        self.ff2 = nn.Conv2d(f // 2, c, 1)
        self.beta = nn.Parameter(torch.zeros(1, c, 1, 1)); self.gamma = nn.Parameter(torch.zeros(1, c, 1, 1))

    def forward(self, x):
        h = simple_gate(self.dw(self.pw1(self.norm1(x))))
        local = not self.training and self.win and h.shape[2] * h.shape[3] > self.win ** 2
        h = self.pw2(h * (local_sca(h, self.sca, self.win) if local else self.sca(h.mean((2, 3), keepdim=True))))
        x = x + self.beta * h
        h = self.ff2(simple_gate(self.ff1(self.norm2(x))))
        return x + self.gamma * h


class NAFNet(nn.Module):
    """U-shaped NAFNet: stride-2 conv down (C->2C), 1x1 + PixelShuffle up, additive skips.
    len(enc) = number of downsamplings (<= 4: infer pads tiles to a multiple of 16).
    enc/dec[i] = blocks at level i (0 = full res). tlc = train patch (packed px): at eval, SCA pools over that window, not the tile."""

    def __init__(self, in_channels=5, out_channels=4, width=32, enc=(1, 1, 2, 4), middle=4, dec=(1, 1, 1, 1), tlc=256):
        super().__init__()
        assert len(enc) == len(dec) and len(enc) <= 4, "depth must be <= 4 and enc/dec must match"
        self.intro = nn.Conv2d(in_channels, width, 3, padding=1)
        self.encoders, self.downs, self.ups, self.decoders = (nn.ModuleList() for _ in range(4))
        c = width
        win = lambda lvl: tlc >> lvl if tlc else 0
        for lvl, n in enumerate(enc):
            self.encoders.append(nn.Sequential(*[NAFBlock(c, win=win(lvl)) for _ in range(n)]))
            self.downs.append(nn.Conv2d(c, 2 * c, 2, stride=2)); c *= 2
        self.middle = nn.Sequential(*[NAFBlock(c, win=win(len(enc))) for _ in range(middle)])
        for lvl, n in reversed(list(enumerate(dec))):
            self.ups.append(nn.Sequential(nn.Conv2d(c, 2 * c, 1, bias=False), nn.PixelShuffle(2))); c //= 2
            self.decoders.append(nn.Sequential(*[NAFBlock(c, win=win(lvl)) for _ in range(n)]))
        self.ending = nn.Conv2d(width, out_channels, 3, padding=1)

    def forward(self, x):
        h, skips = self.intro(x), []
        for e, d in zip(self.encoders, self.downs):
            h = e(h); skips.append(h); h = d(h)
        h = self.middle(h)
        for u, d in zip(self.ups, self.decoders):
            h = d(u(h) + skips.pop())
        return self.ending(h)


# arch config <-> flat int vector, stored in the state dict so infer.py can rebuild the net
def cfg_to_tensor(width, enc, middle, dec, tlc=256):
    return torch.tensor([width, len(enc), *enc, middle, *dec, tlc], dtype=torch.long)


def tensor_to_cfg(t):
    t = [int(v) for v in t]; n = t[1]
    return dict(width=t[0], enc=tuple(t[2:2 + n]), middle=t[2 + n], dec=tuple(t[3 + n:3 + 2 * n]), tlc=t[3 + 2 * n])


# Speed: MACs understate NAFNet's cost (depthwise conv / LayerNorm / gating are memory-bound).
# Measured CPU WALL-time ratios vs UNet nf32 (eval, 1x5x1024x1024): s 1.86x, m 2.65x, nf48 1.5x
# (MAC ratios: s 0.28x, m 0.65x). Scaled to the M4 anchor (nf32 = 3.0 s net / 6.2 s CLI per 33 MP):
# s ~5.6 s net / ~8.8 s CLI (fits <10 s), m ~8 s / ~11 s (likely OVER budget). Training fwd+bwd at
# bs 8, ps 256 on CPU: m = 2.1x nf48 time and 2.8x its activation memory (~6.4 GB vs 2.3 GB).
# Time on the Mac first: python -m lumen_denoise.speedcheck --arch nafnet --preset s
PRESETS = {
    "s": dict(width=24, enc=(1, 1, 1, 2), middle=2, dec=(1, 1, 1, 1)),    # 3.9M, ~5.6 s net/33 MP, step ~1.3x nf48
    "m": dict(width=32, enc=(1, 1, 2, 4), middle=4, dec=(1, 1, 1, 1)),    # 11.6M, ~8 s net (CLI ~11 s), step ~2.1x nf48
    "l": dict(width=32, enc=(2, 2, 4, 8), middle=12, dec=(2, 2, 2, 2)),   # paper's 36 blocks: far over budget
}
