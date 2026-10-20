"""RAW loading + Bayer packing. All arrays are float32, normalized so black=0, white=1."""
import struct
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
    raw: np.ndarray = None           # (H, W) uint16 raw_image_visible
    black_levels: np.ndarray = None  # (4,) float32 black_level_per_channel, color-index order
    colors: np.ndarray = None        # (2, 2) int raw_colors_visible[:2, :2]
    make: str = ""


def load(path) -> Raw:
    with rawpy.imread(str(path)) as r:
        raw = r.raw_image_visible.copy()
        colors = r.raw_colors_visible[:2, :2].copy()
        desc = r.color_desc.decode()  # e.g. "RGBG"
        pattern = "".join(desc[c] for c in colors.flatten())
        bls = np.array(r.black_level_per_channel, np.float32)
        bl = bls[colors.flatten()]  # black level for each of the 4 tile positions
        white = float(r.white_level)
        wb = np.array(r.camera_whitebalance, np.float32)
        wb = wb[colors.flatten()] if wb[3] > 0 else np.where(colors.flatten() == 3, wb[1], wb[colors.flatten()])
    cfa = raw.astype(np.float32)
    for k in range(4):
        cfa[k // 2::2, k % 2::2] -= bl[k]
    cfa /= np.float32(white - bl.mean())
    iso, make, model = exif(path)
    return Raw(cfa, pattern, bl, white, wb, iso, model, raw, bls, colors, make)


def denormalize(r: Raw, cfa_norm) -> np.ndarray:
    """Exact inverse of load's normalization -> uint16 (H, W) DN."""
    bls = np.asarray(r.black_levels, np.float32)
    scale = r.white - np.mean(bls.astype(np.float64))
    out = np.empty(cfa_norm.shape, np.uint16)
    for k in range(4):
        i, j = k // 2, k % 2
        v = cfa_norm[i::2, j::2] * scale + bls[r.colors[i, j]]
        out[i::2, j::2] = np.clip(np.round(v), 0, r.white)
    return out


def exif(path):
    """(iso, make, model) read in-process from the TIFF/RW2 header; exiftool as fallback."""
    try:
        iso, make, model = _exif_tiff(path)
    except (ValueError, KeyError, struct.error, UnicodeError):
        iso = None
    if not iso or iso <= 0:
        try:
            iso, make, model = _exiftool(path)
        except (OSError, ValueError, IndexError) as e:
            raise ValueError(f"no ISO found in {path} (header parse and exiftool failed: {e})") from None
    return float(iso), make, model


_SIZE = {2: 1, 3: 2, 4: 4}


def _exif_tiff(path):
    with open(path, "rb") as f:
        h = f.read(8)
        e = {b"II": "<", b"MM": ">"}[h[:2]]
        ver, off = struct.unpack(e + "HI", h[2:8])
        if ver not in (42, 0x55):  # TIFF/ARW/DNG, Panasonic RW2
            raise ValueError(f"not a TIFF-like raw: {path}")

        def ifd(off):
            f.seek(off)
            n, = struct.unpack(e + "H", f.read(2))
            return {t: (typ, cnt, v) for t, typ, cnt, v in (struct.unpack(e + "HHI4s", f.read(12)) for _ in range(n))}

        def get(d, tag):
            if tag not in d or d[tag][0] not in _SIZE:
                return None
            typ, cnt, v = d[tag]
            if _SIZE[typ] * cnt > 4:
                f.seek(struct.unpack(e + "I", v)[0]); v = f.read(_SIZE[typ] * cnt)
            if typ == 2:
                return v[:cnt].split(b"\0")[0].decode("latin-1").strip()
            return struct.unpack(e + ("H" if typ == 3 else "I"), v[:_SIZE[typ]])[0]

        d = ifd(off)
        make, model = get(d, 271) or "", get(d, 272) or ""
        iso = get(d, 0x17) if ver == 0x55 else None
        if not iso:
            if get(d, 34665):
                d = {**d, **ifd(get(d, 34665))}
            iso = get(d, 34855)
            if not iso or iso == 65535:  # saturated SHORT: ISOSpeed / RecommendedExposureIndex
                iso = get(d, 34867) or get(d, 34866) or iso
    return iso, make, model


def _exiftool(path):
    import subprocess
    out = subprocess.run(["exiftool", "-s3", "-f", "-ISO", "-Make", "-Model", str(path)],
                         capture_output=True, text=True).stdout.splitlines()
    return float(out[0].split()[0]), out[1].strip(), out[2].strip()


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
