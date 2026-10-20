"""SID-style UNet on packed Bayer (4ch). Layer names match ELD/PMN/LED `UNetSeeInDark` so their weights load."""
import torch
import torch.nn as nn
import torch.nn.functional as F


def _lrelu(x):
    return F.leaky_relu(x, 0.2)


class UNetSeeInDark(nn.Module):
    def __init__(self, in_channels=4, out_channels=4, nf=32):
        super().__init__()
        c = [nf, nf * 2, nf * 4, nf * 8, nf * 16]
        self.conv1_1 = nn.Conv2d(in_channels, c[0], 3, padding=1)
        self.conv1_2 = nn.Conv2d(c[0], c[0], 3, padding=1)
        for i in range(1, 5):
            setattr(self, f"conv{i+1}_1", nn.Conv2d(c[i - 1], c[i], 3, padding=1))
            setattr(self, f"conv{i+1}_2", nn.Conv2d(c[i], c[i], 3, padding=1))
        for j, i in enumerate(range(6, 10)):
            hi, lo = c[4 - j], c[3 - j]
            setattr(self, f"upv{i}", nn.ConvTranspose2d(hi, lo, 2, stride=2))
            setattr(self, f"conv{i}_1", nn.Conv2d(hi, lo, 3, padding=1))
            setattr(self, f"conv{i}_2", nn.Conv2d(lo, lo, 3, padding=1))
        self.conv10_1 = nn.Conv2d(c[0], out_channels, 1)

    def forward(self, x):
        skips = []
        h = x
        for i in range(1, 6):
            h = _lrelu(getattr(self, f"conv{i}_2")(_lrelu(getattr(self, f"conv{i}_1")(h))))
            if i < 5:
                skips.append(h)
                h = F.max_pool2d(h, 2)
        for i in range(6, 10):
            h = getattr(self, f"upv{i}")(h)
            h = torch.cat([h, skips.pop()], 1)
            h = _lrelu(getattr(self, f"conv{i}_2")(_lrelu(getattr(self, f"conv{i}_1")(h))))
        return self.conv10_1(h)


class Denoiser(nn.Module):
    """Wraps the UNet: input = noisy packed (4ch, normalized) [+ noise-std map];
    output = clean estimate directly (same convention as published SID/ELD/LED weights)."""

    def __init__(self, noise_map=True, nf=32, residual=False, zero_init=True):
        super().__init__()
        self.noise_map = noise_map
        self.net = UNetSeeInDark(4 + int(noise_map), 4, nf)
        self.residual = residual
        if residual:
            # predict the noise to subtract; zero-init => starts as identity, so it can't
            # degrade clean input (direct-output nets hit a ~45 dB reconstruction ceiling)
            self.register_buffer("residual_flag", torch.ones(1))
            if zero_init:
                nn.init.zeros_(self.net.conv10_1.weight); nn.init.zeros_(self.net.conv10_1.bias)

    def forward(self, noisy, std_map=None):
        if self.residual:
            # work in noise units: divide by this image's typical noise std so every ISO looks
            # alike and inputs are O(1) (raw values ~0.01 starve a freshly initialised net)
            s = std_map.mean((1, 2, 3), keepdim=True).clamp(min=1e-5)
            x = torch.cat([noisy / s, std_map / s], 1)
            return noisy + s * self.net(x)
        x = torch.cat([noisy, std_map], 1) if self.noise_map else noisy
        return self.net(x)

    @staticmethod
    def from_state_dict(sd):
        m = Denoiser(nf=sd["net.conv1_1.weight"].shape[0], residual="residual_flag" in sd)
        m.load_state_dict(sd)
        return m


if __name__ == "__main__":
    m = Denoiser()
    y = m(torch.zeros(1, 4, 64, 64), torch.zeros(1, 1, 64, 64))
    assert y.shape == (1, 4, 64, 64)
    print("params %.2fM" % (sum(p.numel() for p in m.parameters()) / 1e6))
