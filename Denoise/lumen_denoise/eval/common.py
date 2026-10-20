"""Shared plumbing for the eval suite: method specs, clean-frame sources, noise params, seeds.

A method is f(noisy (4,h,w) float32, K, r) -> (4,h,w) float32 (same contract as bench.get).
Specs: noisy | identity | bm3d | blur:<sigma> | wiener | net:<path.pt>
Clean frames come from data/gt_val (+ data/gt_meta.json) when present, otherwise from a
deterministic procedural scene generator so everything runs on a CPU-only box with no photos.
"""
import json, math
from dataclasses import dataclass
from pathlib import Path
import numpy as np
from scipy.ndimage import gaussian_filter, uniform_filter

ROOT = Path(__file__).resolve().parents[2]  # Denoise/
DEFAULT_CALIB = ROOT / "weights" / "calib.json"
CAMERAS = ("ILCE-7M4", "DMC-GX85")
SEED = 1234
CROP = 256          # benchmark crop side, packed px (all regions)
CENTRE = 512        # extra centre crop, same as train.validate (ps=512) so numbers line up


# ---------------------------------------------------------------- noise ----
class NoiseTable:
    """Per-camera (ISO -> K, read_var), log-log interpolated. Same maths as train.NoiseTable,
    duplicated so the eval suite does not import torch just to read calib.json."""

    def __init__(self, path=DEFAULT_CALIB):
        self.t = {m: np.array(sorted(v)) for m, v in json.load(open(path)).items()}

    def params(self, model, iso):
        a = self.t[model]
        lo, hi = a[0, 0], a[-1, 0]
        li = math.log(min(max(iso, lo), hi))
        K = math.exp(np.interp(li, np.log(a[:, 0]), np.log(a[:, 1])))
        r = math.exp(np.interp(li, np.log(a[:, 0]), np.log(a[:, 2])))
        return K, r

    def iso_range(self, model):
        a = self.t[model]
        return a[0, 0], a[-1, 0]

    def cameras(self):
        return list(self.t)


def add_noise(clean, K, r, seed):
    """Poisson-Gaussian noise with a fixed seed (numpy, so results do not depend on torch RNG).
    Clipped at white like a real raw."""
    rng = np.random.default_rng(seed)
    x = np.clip(clean, 0, None).astype(np.float64)
    shot = rng.poisson(x / K) * K
    return np.minimum(shot + rng.normal(0, math.sqrt(r), x.shape), 1.0).astype(np.float32)


def noise_std(img, K, r):
    """Predicted per-pixel noise std from a (4,h,w) image (smoothed so noise does not bias it)."""
    sig = uniform_filter(np.clip(img.mean(0), 0, None), 3)
    return np.sqrt(K * sig + r)[None].astype(np.float32)


def tone(x):
    """Same gamma-ish perceptual space as train.tone (numpy)."""
    return (np.clip(x, 0, None) + 1e-3) ** (1 / 2.2)


# -------------------------------------------------------------- methods ----
def m_identity(x, K, r):
    return x


def make_blur(sigma):
    def f(x, K, r):
        return np.stack([gaussian_filter(c, sigma) for c in x]).astype(np.float32)
    return f


def m_wiener(x, K, r):
    """Local adaptive Wiener filter with the known noise model: a cheap, honest CPU baseline that
    removes noise without a model file (used for tests and the synthetic gate run)."""
    out = []
    nv = K * np.clip(uniform_filter(x.mean(0), 5), 0, None) + r
    for c in x:
        mu = uniform_filter(c, 5)
        var = np.maximum(uniform_filter(c * c, 5) - mu * mu, 0)
        g = np.maximum(var - nv, 0) / np.maximum(var, 1e-12)
        out.append(mu + g * (c - mu))
    return np.stack(out).astype(np.float32)


def get_method(spec):
    """Resolve a method spec to f(noisy, K, r). net:/bm3d go through bench.get (needs torch/bm3d)."""
    if spec in ("noisy", "identity"):
        return m_identity
    if spec == "wiener":
        return m_wiener
    if spec.startswith("blur:"):
        return make_blur(float(spec[5:]))
    from ..bench import get  # lazy: pulls in torch
    return get(spec)


def short_name(spec):
    if spec.startswith("net:"):
        p = Path(spec[4:].split("@")[0])
        return f"{p.parent.name}/{p.stem}" if p.parent.name else p.stem
    return spec


def run_padded(f, x, K, r, mult=16):
    """Reflect-pad to a multiple of `mult` (UNet needs /16), run, crop back."""
    _, h, w = x.shape
    ph, pw = (-h) % mult, (-w) % mult
    y = f(np.pad(x, ((0, 0), (0, ph), (0, pw)), mode="reflect"), K, r)
    return np.asarray(y, np.float32)[:, :h, :w]


# --------------------------------------------------------- clean frames ----
@dataclass
class Frame:
    name: str
    camera: str
    clean: np.ndarray   # (4,h,w) float32, RGGB, normalized
    synthetic: bool


def synthetic_scene(h=768, w=768, seed=0):
    """Deterministic packed RGGB scene with every region type the benchmark needs:
    deep shadow, flat mid-tone sky gradient, fine texture (fabric/foliage-like), hard edges, text-like
    strokes, a bright highlight. Values are linear, black=0 white=1."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    yy /= h; xx /= w
    base = 0.18 + 0.10 * xx                                    # flat mid-tone gradient (sky)
    q = (yy > 0.5) & (xx < 0.5)                                # bottom-left: fine texture
    tex = gaussian_filter(rng.standard_normal((h, w)), 0.8) * 0.9
    tex += 0.5 * np.sin(2 * np.pi * (xx * w / 3.3 + yy * h / 7.1))
    base = np.where(q, 0.20 + 0.06 * tex, base)
    s = (yy > 0.5) & (xx >= 0.5)                               # bottom-right: deep shadow + faint detail
    base = np.where(s, 0.006 + 0.002 * (np.sin(xx * w / 4.0) > 0), base)
    e = (yy <= 0.5) & (xx >= 0.5)                              # top-right: edges, bars, strokes
    bars = ((xx * w // 6) % 2).astype(np.float32) * (yy < 0.25)
    disk = ((xx - 0.75) ** 2 + (yy - 0.37) ** 2 < 0.006).astype(np.float32)
    base = np.where(e, 0.08 + 0.35 * bars + 0.5 * disk, base)
    for _ in range(6):                                         # thin strokes everywhere ("text")
        y0, x0 = rng.integers(0, h - 40), rng.integers(0, w - 40)
        base[y0:y0 + 1, x0:x0 + 36] *= 1.6
    tint = np.array([0.55, 1.0, 1.0, 0.75], np.float32)[:, None, None]  # rough WB-less raw colour
    out = np.clip(base[None] * tint, 0, 1).astype(np.float32)
    out[:, h // 8:h // 8 + 6, w // 8:w // 8 + 6] = 0.95        # near-white highlight
    return out


def clean_frames(val_dir="data/gt_val", meta="data/gt_meta.json", n=0, synthetic=None, n_synth=4):
    """Held-out clean frames. synthetic=None -> real if available else synthetic; True/False forces."""
    vd, mp = Path(val_dir), Path(meta)
    real_ok = vd.is_dir() and mp.exists() and any(vd.glob("*.npy"))
    if synthetic is False and not real_ok:
        raise FileNotFoundError(f"no clean frames in {vd}")
    if real_ok and not synthetic:
        m = json.load(open(mp))
        files = sorted(vd.glob("*.npy"))[: n or None]
        return [Frame(fp.stem, m[fp.stem], np.asarray(np.load(fp, mmap_mode="r"), np.float32), False) for fp in files]
    cams = CAMERAS
    return [Frame(f"synth{i}", cams[i % len(cams)], synthetic_scene(seed=SEED + i), True)
            for i in range(n or n_synth)]


def crop_seed(frame_idx, region_idx, iso):
    """One seed per (frame, region, ISO): every method sees the identical noise realisation."""
    return (SEED * 1_000_003 + frame_idx * 7919 + region_idx * 104_729 + int(iso)) % (2 ** 32)


# ------------------------------------------------------------ gate API ----
@dataclass
class Check:
    """One row of the release table. status: PASS | FAIL | SKIP (data missing) | INFO (reported, not gating)."""
    section: str        # e.g. "synthetic", "detail", "real-noise", "low-iso", "stars", "a/b"
    name: str           # short id, e.g. "psnr_gain_vs_baseline@6400"
    value: float | None
    threshold: str      # human-readable rule, e.g. ">= +0.3 dB"
    status: str
    note: str = ""


@dataclass
class Ctx:
    """Everything a module's gate_checks(model, baseline, ctx) may use. model/baseline are method fns."""
    table: NoiseTable
    frames: list            # list[Frame] (real held-out or synthetic)
    isos: tuple = (1600, 6400, 25600)
    real_files: list = None     # high-ISO RAW paths (may be empty -> SKIP real checks)
    lowiso_files: list = None   # base-ISO RAW paths (may be empty)
    quick: bool = False         # fewer frames/crops; used by tests and the cloud smoke run
    out_dir: Path = Path("reports/gate")
    model_name: str = "model"
    baseline_name: str = "baseline"


def status(ok, skip=False):
    return "SKIP" if skip else ("PASS" if ok else "FAIL")
