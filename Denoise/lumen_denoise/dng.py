"""Write a Bayer CFA array back out as a DNG that renders like the source raw.

write_cfa_dng(src_raw_path, cfa, out_path)
    cfa: uint16 (H, W) in the source's raw value space (same black/white level as rawpy),
    shaped like rawpy's raw_image_visible (or raw_image; margins are cropped off).

Uses Adobe DNG Converter when present (best Lightroom fidelity), else a from-scratch DNG.
"""
import hashlib
import os
import shutil
import subprocess
import tempfile
from fractions import Fraction

import numpy as np
import rawpy
import tifffile

CONVERTER_CANDIDATES = [
    os.environ.get("LUMEN_DNG_CONVERTER", ""),
    "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter",
    os.path.expanduser("~/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"),
]


def _converter():
    return next((c for c in CONVERTER_CANDIDATES if c and os.path.exists(c)), None)


def _visible(raw, cfa):
    s = raw.sizes
    if cfa.shape == (s.height, s.width):
        return cfa
    if cfa.shape == (s.raw_height, s.raw_width):
        return cfa[s.top_margin:s.top_margin + s.height, s.left_margin:s.left_margin + s.width]
    raise ValueError(f"cfa shape {cfa.shape} matches neither visible nor full raw size")


# ---------------------------------------------------------------- approach 1: Adobe

def write_cfa_dng_adobe(src_raw_path, cfa, out_path):
    """Adobe DNG Converter -u (uncompressed), overwrite the CFA bytes in place, then run the
    converter again on that DNG (-c lossless): it recompresses, recomputes NewRawImageDigest
    and re-renders the thumbnail from the new data."""
    conv = _converter()
    if conv is None:
        raise FileNotFoundError("Adobe DNG Converter not found (set LUMEN_DNG_CONVERTER)")
    src_raw_path, out_path = os.path.abspath(src_raw_path), os.path.abspath(out_path)
    with rawpy.imread(src_raw_path) as raw:
        cfa = _visible(raw, np.asarray(cfa, np.uint16))
        orig = raw.raw_image_visible.copy()
        black = sorted(set(raw.black_level_per_channel))
    stem = os.path.splitext(os.path.basename(src_raw_path))[0]
    with tempfile.TemporaryDirectory() as tmp:
        a, b = os.path.join(tmp, "a"), os.path.join(tmp, "b")
        os.mkdir(a)
        os.mkdir(b)
        # Adobe writes ColorMatrix/ForwardMatrix, BaselineExposure, lens opcodes, maker notes, EXIF.
        subprocess.run([conv, "-c", "-u", "-p0", "-d", a, src_raw_path], check=True, capture_output=True)
        mid = os.path.join(a, stem + ".dng")
        _patch_cfa(mid, cfa, orig, black)
        subprocess.run([conv, "-c", "-p0", "-d", b, mid], check=True, capture_output=True)
        shutil.move(os.path.join(b, stem + ".dng"), out_path)


def _find_offset(dng_raw, vis, search=16):
    """(dy, dx) such that dng_raw[dy+i, dx+j] == vis[i, j] on the unmodified data."""
    probe = vis[64:320, 64:320]
    for dy in range(-search, search + 1):
        for dx in range(-search, search + 1):
            y, x = 64 + dy, 64 + dx
            # >99% equal: Adobe repairs a few defect pixels (Panasonic stores them as 0)
            if y >= 0 and x >= 0 and (dng_raw[y:y + 256, x:x + 256] == probe).mean() > 0.99:
                return dy, dx
    raise RuntimeError("could not align Adobe DNG raw data with LibRaw raw_image_visible")


def _patch_cfa(path, cfa, orig, black):
    with tifffile.TiffFile(path) as tf:
        page = next(p for p in tf.pages[0].pages if p.photometric == 32803)
        assert page.compression == 1 and page.bitspersample == 16 and page.samplesperpixel == 1
        assert 50712 not in page.tags, "LinearizationTable present; inverse mapping not implemented"
        bl = page.tags[50714].value
        dng_black = sorted({round(bl[i] / bl[i + 1]) for i in range(0, len(bl), 2)})
        assert dng_black == [round(x) for x in black], f"black mismatch {dng_black} vs {black}"
        data = page.asarray()
        dy, dx = _find_offset(data, orig)
        # Paste the overlap; pixels only Adobe has (outside DefaultCrop) stay as-is, and so do
        # pixels Adobe already changed vs the source (defect repair, e.g. Panasonic's zeroed pixels).
        y0, x0 = max(dy, 0), max(dx, 0)
        h = min(data.shape[0] - y0, cfa.shape[0] - (y0 - dy))
        w = min(data.shape[1] - x0, cfa.shape[1] - (x0 - dx))
        region = data[y0:y0 + h, x0:x0 + w]
        src = (slice(y0 - dy, y0 - dy + h), slice(x0 - dx, x0 - dx + w))
        np.copyto(region, cfa[src], where=region == orig[src])
        if page.is_tiled:
            tl, tw = page.tilelength, page.tilewidth
            ny, nx = -(-data.shape[0] // tl), -(-data.shape[1] // tw)
            padded = np.zeros((ny * tl, nx * tw), np.uint16)
            padded[:data.shape[0], :data.shape[1]] = data
            chunks = [padded[i * tl:(i + 1) * tl, j * tw:(j + 1) * tw] for i in range(ny) for j in range(nx)]
        else:
            rps = page.rowsperstrip
            chunks = [data[i:i + rps] for i in range(0, data.shape[0], rps)]
        offsets, dtype = page.dataoffsets, np.dtype(tf.byteorder + "u2")
        uid_off = tf.pages[0].tags[50781].valueoffset if 50781 in tf.pages[0].tags else None
    with open(path, "r+b") as f:
        for off, chunk in zip(offsets, chunks):
            f.seek(off)
            f.write(np.ascontiguousarray(chunk).astype(dtype).tobytes())
        if uid_off is not None:  # new RawDataUniqueID so Lightroom doesn't reuse the original's caches
            f.seek(uid_off)
            f.write(hashlib.md5(data.tobytes()).digest())


# ---------------------------------------------------------------- approach 2: from scratch

def _rat(x, den=10000):
    f = Fraction(float(x)).limit_denominator(den)
    return [f.numerator, f.denominator]


def write_cfa_dng_scratch(src_raw_path, cfa, out_path):
    """Minimal DNG via tifffile + EXIF/maker notes copied with exiftool. Single D65 matrix from
    LibRaw; no BaselineExposure, ForwardMatrix or lens opcodes (Lightroom fidelity is lower)."""
    with rawpy.imread(str(src_raw_path)) as raw:
        cfa = np.ascontiguousarray(_visible(raw, np.asarray(cfa, np.uint16)))
        s = raw.sizes
        desc = raw.color_desc.decode()
        pattern = ["RGB".index(desc[c]) for c in raw.raw_pattern.flatten()]
        black = [float(raw.black_level_per_channel[c]) for c in raw.raw_pattern.flatten()]
        wb = np.array(raw.camera_whitebalance[:3], float)
        neutral = wb[1] / wb
        cm = np.array(raw.rgb_xyz_matrix[:3], float)  # XYZ(D65) -> camera, Adobe tables
        white = int(raw.white_level)
        crop = (s.crop_left_margin, s.crop_top_margin, s.crop_width, s.crop_height)
        if not crop[2]:
            crop = (0, 0, s.width, s.height)
    make, model = subprocess.run(["exiftool", "-s3", "-Make", "-Model", str(src_raw_path)],
                                 capture_output=True, text=True, check=True).stdout.splitlines()
    tags = [
        (50706, "B", 4, (1, 4, 0, 0), True),          # DNGVersion
        (50707, "B", 4, (1, 1, 0, 0), True),          # DNGBackwardVersion
        (50708, "s", 0, f"{make.strip().title()} {model.strip()}", True),  # UniqueCameraModel
        (33421, "H", 2, (2, 2), True),                # CFARepeatPatternDim
        (33422, "B", 4, pattern, True),               # CFAPattern
        (50710, "B", 3, (0, 1, 2), True),             # CFAPlaneColor
        (50711, "H", 1, 1, True),                     # CFALayout
        (50713, "H", 2, (2, 2), True),                # BlackLevelRepeatDim
        (50714, "2I", 4, sum((_rat(b) for b in black), []), True),  # BlackLevel
        (50717, "I", 1, white, True),                 # WhiteLevel
        (50719, "I", 2, crop[:2], True),              # DefaultCropOrigin
        (50720, "I", 2, crop[2:], True),              # DefaultCropSize
        (50721, "2i", 9, sum((_rat(v) for v in cm.flatten()), []), True),  # ColorMatrix1
        (50778, "H", 1, 21, True),                    # CalibrationIlluminant1 = D65
        (50728, "2I", 3, sum((_rat(v) for v in neutral), []), True),  # AsShotNeutral
    ]
    tifffile.imwrite(out_path, cfa, photometric=32803, subfiletype=0, extratags=tags,
                     metadata=None, software="lumen-denoise")
    subprocess.run(["exiftool", "-q", "-overwrite_original", "-tagsFromFile", str(src_raw_path),
                    "-exif:all", "-makernotes:all", "-Make", "-Model", "-Orientation",
                    str(out_path)], check=True)


write_cfa_dng = write_cfa_dng_adobe if _converter() else write_cfa_dng_scratch
