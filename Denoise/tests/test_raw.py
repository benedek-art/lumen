"""raw.py: in-process EXIF and normalize/denormalize round trip. Synthetic data only (Linux CPU)."""
import glob
import os
import struct
import sys

import numpy as np
import pytest
import tifffile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from lumen_denoise import raw as rawio  # noqa: E402


def _tiff(e, ver, ifd0, exif=None):
    """Tiny TIFF writer: ifd0/exif = {tag: (type, value)}; type 2=ASCII, 3=SHORT, 4=LONG."""
    def entries(d, base):
        d = dict(sorted(d.items()))
        head, extra = b"", b""
        end = base + 2 + 12 * len(d) + 4
        for tag, (typ, val) in d.items():
            if typ == 2:
                data, cnt = val.encode() + b"\0", len(val) + 1
            else:
                data, cnt = struct.pack(e + ("H" if typ == 3 else "I"), val), 1
            if len(data) <= 4:
                field = data.ljust(4, b"\0")
            else:
                field = struct.pack(e + "I", end + len(extra)); extra += data + b"\0" * (len(data) % 2)
            head += struct.pack(e + "HHI", tag, typ, cnt) + field
        return struct.pack(e + "H", len(d)) + head + b"\0\0\0\0" + extra
    ifd0 = dict(ifd0)
    if exif is not None:
        ifd0[34665] = (4, 0)
        n0 = len(entries(ifd0, 8))
        ifd0[34665] = (4, 8 + n0)
    out = (b"II" if e == "<" else b"MM") + struct.pack(e + "HI", ver, 8) + entries(ifd0, 8)
    if exif is not None:
        out += entries(exif, len(out))
    return out


def test_exif_arw_like(tmp_path):
    p = tmp_path / "a.ARW"
    p.write_bytes(_tiff("<", 42, {271: (2, "SONY"), 272: (2, "ILCE-7M4")}, {34855: (3, 6400)}))
    assert rawio.exif(p) == (6400.0, "SONY", "ILCE-7M4")


def test_exif_big_endian_saturated_iso(tmp_path):
    p = tmp_path / "b.ARW"
    p.write_bytes(_tiff(">", 42, {271: (2, "SONY"), 272: (2, "ILCE-7M4")}, {34855: (3, 65535), 34867: (4, 102400)}))
    assert rawio.exif(p) == (102400.0, "SONY", "ILCE-7M4")


def test_exif_rw2_like(tmp_path):
    p = tmp_path / "c.RW2"
    p.write_bytes(_tiff("<", 0x55, {0x17: (3, 3200), 271: (2, "Panasonic"), 272: (2, "DMC-GX85")}))
    assert rawio.exif(p) == (3200.0, "Panasonic", "DMC-GX85")


def test_exif_tifffile_written(tmp_path):
    p = tmp_path / "d.tif"
    tifffile.imwrite(p, np.zeros((8, 8), np.uint16), extratags=[(271, 2, None, "SONY", True), (272, 2, None, "ILCE-7M4", True), (34855, 3, 1, 800, True)])
    assert rawio.exif(p) == (800.0, "SONY", "ILCE-7M4")


def test_exif_missing_iso_raises(tmp_path, monkeypatch):
    p = tmp_path / "e.ARW"
    p.write_bytes(_tiff("<", 42, {271: (2, "SONY"), 272: (2, "ILCE-7M4")}, {}))
    monkeypatch.setenv("PATH", str(tmp_path))  # no exiftool fallback
    with pytest.raises(ValueError, match="e.ARW"):
        rawio.exif(p)


def _old_denorm(cfa, colors_full, bls, white):
    """The pre-refactor infer.py code path (rawpy raw_colors_visible + black_level_per_channel)."""
    bl = np.array(bls, np.float32)[colors_full]
    scale = white - np.mean(bls)
    return np.clip(np.round(cfa * scale + bl), 0, white).astype(np.uint16)


@pytest.mark.parametrize("pattern,colors", [("RGGB", [[0, 1], [3, 2]]), ("BGGR", [[2, 3], [1, 0]]),
                                            ("GRBG", [[1, 0], [2, 3]]), ("GBRG", [[3, 2], [0, 1]])])
@pytest.mark.parametrize("shape", [(64, 96), (63, 95)])
def test_denormalize_round_trip(pattern, colors, shape):
    rng = np.random.default_rng(0)
    colors = np.array(colors)
    bls, white = [509, 512, 515, 511], 16383
    full = np.tile(colors, (shape[0] // 2 + 1, shape[1] // 2 + 1))[:shape[0], :shape[1]]
    raw = rng.integers(0, white + 1, shape).astype(np.uint16)
    raw[0, 0], raw[1, 1] = 0, white  # below black and at white
    # load()'s normalization, done the old way (full black map)
    bl = np.array(bls, np.float32)[colors.flatten()]
    black = np.tile(bl.reshape(2, 2), (shape[0] // 2 + 1, shape[1] // 2 + 1))[:shape[0], :shape[1]]
    cfa = (raw.astype(np.float32) - black) / (float(white) - bl.mean())
    r = rawio.Raw(cfa, pattern, bl, float(white), np.ones(4, np.float32), 100.0, "X",
                  raw, np.array(bls, np.float32), colors, "")
    out = rawio.denormalize(r, cfa)
    assert out.dtype == np.uint16 and out.shape == shape
    np.testing.assert_array_equal(out, raw)
    noisy = cfa + rng.normal(0, 0.05, shape).astype(np.float32)  # incl. values outside [0, 1]
    np.testing.assert_array_equal(rawio.denormalize(r, noisy), _old_denorm(noisy, full, bls, white))


def test_load_real_file():
    files = glob.glob(os.path.join(ROOT, "data", "samples", "*.ARW")) + glob.glob(os.path.join(ROOT, "data", "samples", "*.RW2"))
    if not files:
        pytest.skip("no real RAW samples in data/samples (only on the user's Mac)")
    import rawpy
    for f in files:
        r = rawio.load(f)
        with rawpy.imread(f) as rr:
            ref = rr.raw_image_visible.copy()
            assert list(r.black_levels) == list(rr.black_level_per_channel)
        np.testing.assert_array_equal(r.raw, ref)
        np.testing.assert_array_equal(rawio.denormalize(r, r.cfa), ref)
        assert r.iso > 0 and r.model and r.make


def test_load_synthetic_dng(tmp_path):
    """load() end to end through rawpy on a tiny tifffile-written CFA DNG (BGGR, per-channel black)."""
    import rawpy
    p = str(tmp_path / "t.dng")
    a = np.random.default_rng(0).integers(400, 4096, (64, 96)).astype(np.uint16)
    eye = (1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1)
    tags = [(50706, 1, 4, (1, 4, 0, 0), True), (33421, 3, 2, (2, 2), True), (33422, 1, 4, (2, 1, 1, 0), True),
            (50710, 1, 3, (0, 1, 2), True), (50713, 3, 2, (2, 2), True), (50714, 3, 4, (500, 510, 520, 530), True),
            (50717, 3, 1, 4095, True), (50721, 10, 9, eye, True), (50728, 5, 3, (1, 2, 1, 1, 1, 2), True),
            (271, 2, None, "SONY", True), (272, 2, None, "ILCE-7M4", True), (34855, 3, 1, 1600, True)]
    tifffile.imwrite(p, a, photometric=32803, subfiletype=0, extratags=tags)
    r = rawio.load(p)
    assert (r.pattern, r.iso, r.make, r.model) == ("BGGR", 1600.0, "SONY", "ILCE-7M4")
    np.testing.assert_array_equal(r.raw, a)
    with rawpy.imread(p) as rr:  # old load() normalization: full float32 black map
        bl = np.array(rr.black_level_per_channel, np.float32)[rr.raw_colors_visible[:2, :2].flatten()]
        black = np.tile(bl.reshape(2, 2), (33, 49))[:64, :96]
        old = (rr.raw_image_visible.astype(np.float32) - black) / (float(rr.white_level) - bl.mean())
        full, bls, white = rr.raw_colors_visible.copy(), list(rr.black_level_per_channel), rr.white_level
    np.testing.assert_array_equal(r.cfa, old)
    np.testing.assert_array_equal(r.black, bl)
    np.testing.assert_array_equal(rawio.denormalize(r, r.cfa), a)
    noisy = r.cfa * np.float32(0.9) + np.float32(0.01)
    np.testing.assert_array_equal(rawio.denormalize(r, noisy), _old_denorm(noisy, full, bls, white))


def test_denormalize_keeps_values_above_white():
    """GX85 RW2 stores some blown px at 4096-4097 with white_level 4095: strength 0 must stay lossless."""
    bls, white = [128, 128, 128, 128], 4095
    raw = np.full((4, 6), 2000, np.uint16)
    raw[0, 0], raw[1, 3] = 4096, 4097
    colors = np.array([[0, 1], [3, 2]])
    bl = np.array(bls, np.float32)
    cfa = (raw.astype(np.float32) - 128) / (white - 128)
    r = rawio.Raw(cfa, "RGGB", bl, float(white), np.ones(4, np.float32), 100.0, "DMC-GX85",
                  raw, bl, colors, "Panasonic")
    np.testing.assert_array_equal(rawio.denormalize(r, cfa), raw)
    assert rawio.denormalize(r, cfa + 1).max() == 4097  # still clipped, at the source's max
