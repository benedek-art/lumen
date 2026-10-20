"""Write a Bayer CFA array back out as a DNG that renders like the source raw.

write_cfa_dng(src_raw_path, cfa, out_path, orig=None, black=None, pending=None)
    cfa: uint16 (H, W) in the source's raw value space (same black/white level as rawpy),
    shaped like rawpy's raw_image_visible (or raw_image; margins are cropped off).

    orig/black: the source's raw_image_visible / black_level_per_channel (read if None);
    pending: start(src) handle so Adobe pass 1 runs during inference.

Uses Adobe DNG Converter when present (best Lightroom fidelity), else a from-scratch DNG.
"""
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
import warnings
from fractions import Fraction

import numpy as np
import rawpy
import tifffile

CONVERTER_CANDIDATES = [
    "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter",
    os.path.expanduser("~/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"),
]


def _converter():
    cands = [os.environ.get("LUMEN_DNG_CONVERTER", "")] + CONVERTER_CANDIDATES
    return next((c for c in cands if c and os.path.exists(c)), None)


def _visible(raw, cfa):
    s = raw.sizes
    if cfa.shape == (s.height, s.width):
        return cfa
    if cfa.shape == (s.raw_height, s.raw_width):
        return cfa[s.top_margin:s.top_margin + s.height, s.left_margin:s.left_margin + s.width]
    raise ValueError(f"cfa shape {cfa.shape} matches neither visible nor full raw size")


# ---------------------------------------------------------------- approach 1: Adobe

class _Pass1:
    """Adobe pass 1 (-u, uncompressed) running in the background; it only needs the source."""
    def __init__(self, conv, src):
        self.src, self.tmp = src, tempfile.mkdtemp(prefix="lumen-dng-")
        self.proc = subprocess.Popen([conv, "-c", "-u", "-p0", "-d", self.tmp, src],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def result(self):
        err = self.proc.communicate()[1]
        mid = os.path.join(self.tmp, os.path.splitext(os.path.basename(self.src))[0] + ".dng")
        if self.proc.returncode or not os.path.exists(mid):
            raise RuntimeError(f"Adobe DNG Converter failed on {self.src} (rc={self.proc.returncode}): "
                               f"{err.decode(errors='replace').strip()}")
        return mid

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        shutil.rmtree(self.tmp, ignore_errors=True)


def start(src):
    """Start Adobe pass 1 in the background (overlaps inference); None without the converter."""
    conv = _converter()
    return _Pass1(conv, os.path.abspath(str(src))) if conv else None


def cancel(pending):
    if pending is not None:
        pending.close()


def _single_pass():
    return os.environ.get("LUMEN_DNG_SINGLE_PASS", "") not in ("", "0")


def write_cfa_dng_adobe(src_raw_path, cfa, out_path, orig=None, black=None, pending=None, single_pass=None):
    """Adobe DNG Converter -u (uncompressed), overwrite the CFA bytes in place, then run the
    converter again on that DNG (-c lossless): it recompresses, recomputes NewRawImageDigest
    and re-renders the thumbnail from the new data. single_pass (or LUMEN_DNG_SINGLE_PASS=1)
    skips pass 2 and fixes the digests in place instead (docs/DNG_SINGLE_PASS.md)."""
    conv = _converter()
    if conv is None:
        raise FileNotFoundError("Adobe DNG Converter not found (set LUMEN_DNG_CONVERTER)")
    src_raw_path, out_path = os.path.abspath(str(src_raw_path)), os.path.abspath(str(out_path))
    single_pass = _single_pass() if single_pass is None else single_pass
    p1 = pending if pending is not None else _Pass1(conv, src_raw_path)
    try:
        if orig is None or black is None or np.shape(cfa) != np.shape(orig):
            with rawpy.imread(src_raw_path) as raw:
                cfa = _visible(raw, np.asarray(cfa, np.uint16))
                orig = raw.raw_image_visible.copy() if orig is None else orig
                black = list(raw.black_level_per_channel) if black is None else black
        cfa, black = np.asarray(cfa, np.uint16), sorted(set(float(b) for b in black))
        # Adobe writes ColorMatrix/ForwardMatrix, BaselineExposure, lens opcodes, maker notes, EXIF.
        mid = p1.result()
        _patch_cfa(mid, cfa, orig, black, fix_digests=single_pass)
        if single_pass:
            shutil.move(mid, out_path)
        else:
            b = os.path.join(p1.tmp, "b")
            os.mkdir(b)
            r = subprocess.run([conv, "-c", "-p0", "-d", b, mid], capture_output=True)
            if r.returncode:
                raise RuntimeError(f"Adobe DNG Converter pass 2 failed (rc={r.returncode}): "
                                   f"{r.stderr.decode(errors='replace').strip()}")
            shutil.move(os.path.join(b, os.path.basename(mid)), out_path)
    finally:
        p1.close()


def _find_offset(dng_raw, vis, search=16):
    """(dy, dx) such that dng_raw[dy+i, dx+j] == vis[i, j] on the unmodified data."""
    probe = vis[64:320, 64:320]
    offs = sorted(((dy, dx) for dy in range(-search, search + 1) for dx in range(-search, search + 1)),
                  key=lambda o: (abs(o[0]) + abs(o[1]), o))
    for dy, dx in offs:
        y, x = 64 + dy, 64 + dx
        win = dng_raw[y:y + 256, x:x + 256]
        # >99% equal: Adobe repairs a few defect pixels (Panasonic stores them as 0)
        if win.shape == probe.shape and (win == probe).mean() > 0.99:
            return dy, dx
    raise RuntimeError("could not align Adobe DNG raw data with LibRaw raw_image_visible")


def _digest_candidates(data, chunks, dtype):
    """Candidate implementations of the DNG raw digests, keyed by tag. Each is only trusted if it
    reproduces Adobe's own value on the unmodified pass-1 file (checked in _patch_cfa)."""
    le = lambda a: np.ascontiguousarray(a, "<u2").tobytes()
    tiles = [data[y:y + 256, x:x + 256] for y in range(0, data.shape[0], 256) for x in range(0, data.shape[1], 256)]
    new = hashlib.md5(b"".join(hashlib.md5(le(t)).digest() for t in tiles)).digest()
    return {51111: [new, hashlib.md5(le(data)).digest()],  # DNG SDK 1.4+ tiled MD5; spec's plain MD5
            50972: [hashlib.md5(le(data)).digest(),
                    hashlib.md5(b"".join(np.ascontiguousarray(c).astype(dtype).tobytes() for c in chunks)).digest()]}


# Known TIFF/EXIF/DNG tag ids a neutralized digest tag must not be renamed to.
_KNOWN = {50879, 50931, 50932, 50933, 50934, 50935, 50936, 50937, 50938, 50939, 50940, 50941, 50942,
          50964, 50965, 50966, 50967, 50968, 50969, 50970, 50971, 50972, 50973, 50974, 50975, 50981, 50982,
          51008, 51009, 51022, 51023, 51041, 51043, 51044, 51058, 51081, 51089, 51090, 51091, 51107, 51108,
          51109, 51110, 51111, 51112, 51113, 51114, 51125, 51157, 51158, 51159, 51160, 51161, 51162,
          51163, 51164, 51165, 51166, 51167, 51168, 51169, 51170, 51171, 51172, 51173, 51174, 51175, 51176,
          51177, 51178, 51179, 51180, 51181, 51182}


def _free_tag(ids, tag):
    """An unused tag id between tag's neighbours, so the IFD stays sorted (TIFF 6.0)."""
    ids = sorted(ids)
    i = ids.index(tag)
    lo, hi = ids[i - 1] if i else 32768, ids[i + 1] if i + 1 < len(ids) else 65535
    free = [t for t in range(max(lo + 1, 32768), hi) if t not in _KNOWN]
    if not free:
        raise RuntimeError(f"no free tag id between {lo} and {hi} to neutralize tag {tag}")
    return free[0]


def _patch_cfa(path, cfa, orig, black, fix_digests=False):
    """Overwrite the CFA pixels of an uncompressed DNG in place. fix_digests: recompute
    NewRawImageDigest/RawImageDigest (if our algorithm reproduces the stored value) or else
    neutralize the tag by renaming it to an unused private id, so readers don't flag the file."""
    with tifffile.TiffFile(path) as tf:
        page = next(p for p in tf.pages[0].pages if p.photometric == 32803)
        assert page.compression == 1 and page.bitspersample == 16 and page.samplesperpixel == 1
        assert 50712 not in page.tags, "LinearizationTable present; inverse mapping not implemented"
        bl = page.tags[50714].value
        dng_black = sorted({round(bl[i] / bl[i + 1]) for i in range(0, len(bl), 2)})
        assert dng_black == sorted({round(x) for x in black}), f"black mismatch {dng_black} vs {black}"
        data = page.asarray()
        dtype = np.dtype(tf.byteorder + "u2")

        def chunks():
            if page.is_tiled:
                tl, tw = page.tilelength, page.tilewidth
                ny, nx = -(-data.shape[0] // tl), -(-data.shape[1] // tw)
                padded = np.zeros((ny * tl, nx * tw), np.uint16)
                padded[:data.shape[0], :data.shape[1]] = data
                return [padded[i * tl:(i + 1) * tl, j * tw:(j + 1) * tw] for i in range(ny) for j in range(nx)]
            rps = page.rowsperstrip
            return [data[i:i + rps] for i in range(0, data.shape[0], rps)]

        ifd0 = tf.pages[0].tags
        digests = {t: ifd0[t] for t in (50972, 51111) if t in ifd0} if fix_digests else {}
        algo = {}
        if digests:
            cands = _digest_candidates(data, chunks(), dtype)
            for t, tag in digests.items():
                algo[t] = next((k for k, d in enumerate(cands[t]) if d == bytes(tag.value)), None)
        dy, dx = _find_offset(data, orig)
        # Paste the overlap; pixels only Adobe has (outside DefaultCrop) stay as-is, and so do
        # pixels Adobe already changed vs the source (defect repair, e.g. Panasonic's zeroed pixels).
        y0, x0 = max(dy, 0), max(dx, 0)
        h = min(data.shape[0] - y0, cfa.shape[0] - (y0 - dy))
        w = min(data.shape[1] - x0, cfa.shape[1] - (x0 - dx))
        region = data[y0:y0 + h, x0:x0 + w]
        src = (slice(y0 - dy, y0 - dy + h), slice(x0 - dx, x0 - dx + w))
        np.copyto(region, cfa[src], where=region == orig[src])
        out_chunks = chunks()
        offsets = page.dataoffsets
        uid_off = ifd0[50781].valueoffset if 50781 in ifd0 else None
        fixes = []  # (file offset, bytes)
        if digests:
            cands = _digest_candidates(data, out_chunks, dtype)
            ids = list(ifd0.keys())
            for t, tag in digests.items():
                if algo[t] is not None:
                    fixes.append((tag.valueoffset, cands[t][algo[t]]))
                else:
                    fixes.append((tag.offset, struct.pack(tf.byteorder + "H", _free_tag(ids, t))))
    with open(path, "r+b") as f:
        for off, chunk in zip(offsets, out_chunks):
            f.seek(off)
            f.write(np.ascontiguousarray(chunk).astype(dtype).tobytes())
        if uid_off is not None:  # new RawDataUniqueID so Lightroom doesn't reuse the original's caches
            f.seek(uid_off)
            f.write(hashlib.md5(data.tobytes()).digest())
        for off, b in fixes:
            f.seek(off)
            f.write(b)
    return {t: ("recomputed" if algo[t] is not None else "neutralized") for t in algo}


# ---------------------------------------------------------------- approach 2: from scratch

def _rat(x, den=10000):
    f = Fraction(float(x)).limit_denominator(den)
    return [f.numerator, f.denominator]


def write_cfa_dng_scratch(src_raw_path, cfa, out_path, orig=None, black=None, pending=None):
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
    from .raw import exif
    _, make, model = exif(src_raw_path)
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
    if not shutil.which("exiftool"):
        warnings.warn(f"exiftool not found: {out_path} has no EXIF/maker notes copied from the source")
        return
    subprocess.run(["exiftool", "-q", "-overwrite_original", "-tagsFromFile", str(src_raw_path),
                    "-exif:all", "-makernotes:all", "-Make", "-Model", "-Orientation",
                    str(out_path)], check=True)


ARCHIVE = "/Volumes/Offload Drive"


def write_cfa_dng(src_raw_path, cfa, out_path, orig=None, black=None, pending=None, **kw):
    """Adobe path when the converter exists (checked per call, so LUMEN_DNG_CONVERTER can be set
    late), else the from-scratch writer. pending: handle from start()."""
    p = os.path.realpath(str(out_path)).casefold()  # macOS volumes are case-insensitive
    if p == ARCHIVE.casefold() or p.startswith(ARCHIVE.casefold() + "/"):
        cancel(pending)
        raise PermissionError(f"refusing to write into the read-only archive: {out_path}")
    if _converter():
        return write_cfa_dng_adobe(src_raw_path, cfa, out_path, orig, black, pending, **kw)
    cancel(pending)
    return write_cfa_dng_scratch(src_raw_path, cfa, out_path)
