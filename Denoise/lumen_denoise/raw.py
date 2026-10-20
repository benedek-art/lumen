"""RAW loading + Bayer packing. All arrays are float32, normalized so black=0, white=1."""
from dataclasses import dataclass
import numpy as np
import rawpy


@dataclass
class Raw:
    cfa: np.ndarray        # (H, W) float32, normalized, visible area
    pattern: str           # e.g. "RGGB" — order of the 2x2 tile at (0,0)
    black: np.ndarray      # per-channel black level in DN (4,), tile order
    white: float
    wb: np.ndarray         # camera as-shot WB multipliers (4,), tile order
    iso: float
    model: str


def load(path) -> Raw:
    with rawpy.imread(str(path)) as r:
        cfa = r.raw_image_visible.astype(np.float32)
        colors = r.raw_colors_visible[:2, :2]
        desc = r.color_desc.decode()  # e.g. "RGBG"
        pattern = "".join(desc[c] for c in colors.flatten())
        # per-pixel black level for each of the 4 tile positions
        bl = np.array(r.black_level_per_channel, np.float32)[colors.flatten()]
        white = float(r.white_level)
        wb = np.array(r.camera_whitebalance, np.float32)
        wb = wb[colors.flatten()] if wb[3] > 0 else np.where(colors.flatten() == 3, wb[1], wb[colors.flatten()])
    black = np.tile(bl.reshape(2, 2), (cfa.shape[0] // 2 + 1, cfa.shape[1] // 2 + 1))[: cfa.shape[0], : cfa.shape[1]]
    cfa = (cfa - black) / (white - bl.mean())
    iso, model = _exif(path)
    return Raw(cfa, pattern, bl, white, wb, iso, model)


def _exif(path):
    import subprocess
    out = subprocess.run(["exiftool", "-s3", "-ISO", "-Model", str(path)], capture_output=True, text=True).stdout.splitlines()
    return float(out[0].split()[0]), out[1].strip()


def pack(cfa: np.ndarray) -> np.ndarray:
    """(H, W) -> (4, H/2, W/2) in tile order [0,0],[0,1],[1,0],[1,1]."""
    h, w = cfa.shape[0] // 2 * 2, cfa.shape[1] // 2 * 2
    c = cfa[:h, :w]
    return np.stack([c[0::2, 0::2], c[0::2, 1::2], c[1::2, 0::2], c[1::2, 1::2]])


def unpack(p: np.ndarray) -> np.ndarray:
    _, h, w = p.shape
    out = np.empty((h * 2, w * 2), p.dtype)
    out[0::2, 0::2], out[0::2, 1::2], out[1::2, 0::2], out[1::2, 1::2] = p
    return out
