"""DNG writer tests. CPU-only synthetic tests always run; the identity round trip through Adobe
DNG Converter needs data/samples and the converter (skipped on the cloud box).
Run: python -m pytest tests/test_dng.py"""
import hashlib
import os
import stat
import sys
import textwrap

import numpy as np
import pytest
import tifffile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from lumen_denoise import dng  # noqa: E402

SAMPLES = ["A7404922-2.ARW", "P1100829.RW2"]
BLACK = 512


def _le_tiles(a):
    le = lambda t: np.ascontiguousarray(t, "<u2").tobytes()
    tiles = [a[y:y + 256, x:x + 256] for y in range(0, a.shape[0], 256) for x in range(0, a.shape[1], 256)]
    return hashlib.md5(b"".join(hashlib.md5(le(t)).digest() for t in tiles)).digest()


def _scene(seed=0, H=400, W=420, dy=2, dx=3):
    """Adobe-like stored raw `data` (with margins) and LibRaw-like visible `orig` at offset (dy, dx);
    a few pixels LibRaw has as 0 (Panasonic defects) are 'repaired' in data."""
    rng = np.random.default_rng(seed)
    data = rng.integers(BLACK, 16000, (H + 6, W + 8), dtype=np.uint16)
    orig = data[dy:dy + H, dx:dx + W].copy()
    defects = (rng.integers(0, H, 20), rng.integers(0, W, 20))
    orig[defects] = 0
    cfa = rng.integers(BLACK, 16000, (H, W), dtype=np.uint16)
    return data, orig, cfa, (dy, dx)


def _write_dng(path, data, tiled, byteorder="<", digest=None, raw_digest=None, uid=True):
    """DNG-like file: IFD0 thumbnail with digest/UID tags, CFA in a SubIFD like Adobe writes."""
    tags0 = [(50706, "B", 4, (1, 6, 0, 0), True)]
    if uid:
        tags0.append((50781, "B", 16, bytes(16), True))
    if raw_digest is not None:
        tags0.append((50858, "B", 16, raw_digest, True))
    if digest is not None:
        tags0.append((51111, "B", 16, digest, True))
    raw_tags = [(33421, "H", 2, (2, 2), True), (33422, "B", 4, (0, 1, 1, 2), True),
                (50713, "H", 2, (2, 2), True), (50714, "2I", 4, [BLACK, 1] * 4, True)]
    with tifffile.TiffWriter(path, byteorder=byteorder) as tw:
        tw.write(np.zeros((8, 8, 3), np.uint8), subifds=1, subfiletype=1, extratags=tags0, metadata=None)
        kw = {"tile": (64, 64)} if tiled else {"rowsperstrip": 17}
        tw.write(data, photometric=32803, subfiletype=0, extratags=raw_tags, metadata=None, **kw)


def _read(path):
    with tifffile.TiffFile(path) as tf:
        page = next(p for p in tf.pages[0].pages if p.photometric == 32803)
        return page.asarray(), {k: t.value for k, t in tf.pages[0].tags.items()}, list(tf.pages[0].tags.keys())


def _expected(data, orig, cfa, off):
    dy, dx = off
    exp = data.copy()
    reg = exp[dy:dy + orig.shape[0], dx:dx + orig.shape[1]]
    np.copyto(reg, cfa, where=reg == orig)
    return exp


# ---------------------------------------------------------------- _find_offset

@pytest.mark.parametrize("dy,dx", [(0, 0), (2, 3), (-3, 5), (-4, -7), (16, -16)])
def test_find_offset(dy, dx):
    rng = np.random.default_rng(1)
    big = rng.integers(0, 4096, (420, 420), dtype=np.uint16)
    vis = big[20 + dy:20 + dy + 360, 20 + dx:20 + dx + 360].copy()  # big[20+dy+i] == vis[i]
    dng_raw = big[20:, 20:]  # dng_raw[dy+i, dx+j] == vis[i, j]
    vis[100, 100] = 0  # a repaired defect must not break alignment
    assert dng._find_offset(dng_raw, vis) == (dy, dx)


def test_find_offset_order_and_failure():
    rng = np.random.default_rng(2)
    a = rng.integers(0, 4096, (400, 400), dtype=np.uint16)
    flat = np.zeros_like(a)  # every offset matches: (0, 0) must win
    assert dng._find_offset(flat, flat) == (0, 0)
    with pytest.raises(RuntimeError):
        dng._find_offset(a, rng.integers(0, 4096, (400, 400), dtype=np.uint16))


# ---------------------------------------------------------------- _patch_cfa

@pytest.mark.parametrize("tiled", [True, False])
@pytest.mark.parametrize("byteorder", ["<", ">"])
def test_patch_cfa(tmp_path, tiled, byteorder):
    data, orig, cfa, off = _scene()
    p = str(tmp_path / "a.dng")
    _write_dng(p, data, tiled, byteorder)
    before = open(p, "rb").read()
    assert dng._patch_cfa(p, cfa, orig, [BLACK] * 4) == {}
    got, tags0, _ = _read(p)
    exp = _expected(data, orig, cfa, off)
    np.testing.assert_array_equal(got, exp)
    assert (got != data).sum() == (exp != data).sum() > 0
    dy, dx = off
    assert (got[dy:dy + orig.shape[0], dx:dx + orig.shape[1]][orig == 0] != cfa[orig == 0]).all()  # defects kept
    assert bytes(tags0[50781]) == hashlib.md5(exp.tobytes()).digest()
    assert len(open(p, "rb").read()) == len(before)


def test_patch_cfa_no_uid_and_black_mismatch(tmp_path):
    data, orig, cfa, off = _scene()
    p = str(tmp_path / "a.dng")
    _write_dng(p, data, True, uid=False)
    dng._patch_cfa(p, cfa, orig, [BLACK] * 4)
    np.testing.assert_array_equal(_read(p)[0], _expected(data, orig, cfa, off))
    with pytest.raises(AssertionError, match="black mismatch"):
        dng._patch_cfa(p, cfa, orig, [BLACK + 1] * 4)


# ---------------------------------------------------------------- single-pass digests

@pytest.mark.parametrize("tiled", [True, False])
def test_single_pass_recomputes_known_digest(tmp_path, tiled):
    data, orig, cfa, off = _scene()
    p = str(tmp_path / "a.dng")
    _write_dng(p, data, tiled, ">", digest=_le_tiles(data), raw_digest=hashlib.md5(data.astype("<u2").tobytes()).digest())
    assert dng._patch_cfa(p, cfa, orig, [BLACK] * 4, fix_digests=True) == {51111: "recomputed", 50858: "recomputed"}
    got, tags0, _ = _read(p)
    exp = _expected(data, orig, cfa, off)
    np.testing.assert_array_equal(got, exp)
    assert bytes(tags0[51111]) == _le_tiles(exp)
    assert bytes(tags0[50858]) == hashlib.md5(exp.astype("<u2").tobytes()).digest()


def test_single_pass_neutralizes_unknown_digest(tmp_path):
    data, orig, cfa, off = _scene()
    p = str(tmp_path / "a.dng")
    _write_dng(p, data, True, digest=b"\x01" * 16, raw_digest=b"\x02" * 16)
    assert dng._patch_cfa(p, cfa, orig, [BLACK] * 4, fix_digests=True) == {51111: "neutralized", 50858: "neutralized"}
    got, tags0, ids = _read(p)
    np.testing.assert_array_equal(got, _expected(data, orig, cfa, off))
    assert 51111 not in tags0 and 50858 not in tags0
    assert ids == sorted(ids)  # IFD stays sorted
    new = [t for t in ids if t not in (50706, 50781) and t >= 32768]
    assert len(new) == 2 and not set(new) & dng._KNOWN
    assert {bytes(tags0[t]) for t in new} == {b"\x01" * 16, b"\x02" * 16}  # payload kept, tag ignored


def test_two_pass_leaves_digest_alone(tmp_path):
    data, orig, cfa, _ = _scene()
    p = str(tmp_path / "a.dng")
    _write_dng(p, data, True, digest=b"\x01" * 16)
    dng._patch_cfa(p, cfa, orig, [BLACK] * 4)
    assert bytes(_read(p)[1][51111]) == b"\x01" * 16


def test_free_tag():
    assert dng._free_tag([50781, 51111], 51111) not in dng._KNOWN
    with pytest.raises(RuntimeError):
        dng._free_tag([51110, 51111, 51112], 51111)


# ---------------------------------------------------------------- Adobe path with a fake converter

@pytest.fixture
def fake_conv(tmp_path, monkeypatch):
    """Stand-in for Adobe DNG Converter: -u copies a prebuilt uncompressed DNG, otherwise copies the
    input DNG (pass 2). Logs its calls."""
    data, orig, cfa, off = _scene()
    pre = str(tmp_path / "pre.dng")
    _write_dng(pre, data, True, ">", digest=_le_tiles(data))
    log = tmp_path / "calls.log"
    exe = tmp_path / "conv"
    exe.write_text(textwrap.dedent(f"""\
        #!{sys.executable}
        import os, shutil, sys
        a = sys.argv[1:]
        open({str(log)!r}, "a").write(" ".join(a) + "\\n")
        if os.environ.get("FAKE_FAIL"):
            sys.stderr.write("boom"); sys.exit(3)
        d, src = a[a.index("-d") + 1], a[-1]
        stem = os.path.splitext(os.path.basename(src))[0]
        shutil.copy({pre!r} if "-u" in a else src, os.path.join(d, stem + ".dng"))
        """))
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("LUMEN_DNG_CONVERTER", str(exe))  # set after import: dispatch is per call
    src = tmp_path / "IMG_1.ARW"
    src.write_bytes(b"raw")
    return dict(data=data, orig=orig, cfa=cfa, off=off, log=log, src=str(src), tmp=tmp_path)


def _tmpdirs():
    import tempfile
    return {d for d in os.listdir(tempfile.gettempdir()) if d.startswith("lumen-dng-")}


@pytest.mark.parametrize("single", [False, True])
@pytest.mark.parametrize("early", [False, True])
def test_adobe_path(fake_conv, monkeypatch, single, early):
    f = fake_conv
    monkeypatch.delenv("LUMEN_DNG_SINGLE_PASS", raising=False)
    if single:
        monkeypatch.setenv("LUMEN_DNG_SINGLE_PASS", "1")
    before = _tmpdirs()
    pending = dng.start(f["src"]) if early else None
    assert (pending is not None) == early
    out = str(f["tmp"] / "out.dng")
    dng.write_cfa_dng(f["src"], f["cfa"], out, orig=f["orig"], black=[BLACK] * 4, pending=pending)
    got, tags0, _ = _read(out)
    exp = _expected(f["data"], f["orig"], f["cfa"], f["off"])
    np.testing.assert_array_equal(got, exp)
    calls = f["log"].read_text().splitlines()
    assert len(calls) == (1 if single else 2) and "-u" in calls[0]
    if single:
        assert bytes(tags0[51111]) == _le_tiles(exp)
    assert _tmpdirs() == before  # temp dir cleaned up


def test_adobe_failure_cleans_up(fake_conv, monkeypatch):
    f = fake_conv
    monkeypatch.setenv("FAKE_FAIL", "1")
    before = _tmpdirs()
    pending = dng.start(f["src"])
    with pytest.raises(RuntimeError, match="boom"):
        dng.write_cfa_dng(f["src"], f["cfa"], str(f["tmp"] / "o.dng"), orig=f["orig"], black=[BLACK] * 4,
                          pending=pending)
    assert _tmpdirs() == before and not os.path.exists(f["tmp"] / "o.dng")


def test_cancel_cleans_up(fake_conv):
    before = _tmpdirs()
    dng.cancel(dng.start(fake_conv["src"]))
    dng.cancel(None)
    assert _tmpdirs() == before


def test_start_none_without_converter(monkeypatch):
    monkeypatch.setenv("LUMEN_DNG_CONVERTER", "/nonexistent/conv")
    monkeypatch.setattr(dng, "CONVERTER_CANDIDATES", [])
    assert dng.start("x.ARW") is None


def test_refuses_archive_drive(tmp_path):
    with pytest.raises(PermissionError):
        dng.write_cfa_dng("x.ARW", np.zeros((4, 4), np.uint16), "/Volumes/Offload Drive/x.dng")
    with pytest.raises(PermissionError):
        dng.write_cfa_dng("x.ARW", np.zeros((4, 4), np.uint16), "/volumes/OFFLOAD drive/x.dng")


def test_scratch_writer_roundtrip(tmp_path, monkeypatch):
    """From-scratch writer on a synthetic DNG source: rawpy reads back the same CFA/levels and a
    missing exiftool only warns (no crash)."""
    rawpy = pytest.importorskip("rawpy")
    monkeypatch.setenv("LUMEN_DNG_CONVERTER", "/nonexistent/conv")
    monkeypatch.setattr(dng, "CONVERTER_CANDIDATES", [])
    rng = np.random.default_rng(3)
    src_cfa = rng.integers(BLACK, 16000, (64, 96), dtype=np.uint16)
    tags = [(271, "s", 0, "Sony", True), (272, "s", 0, "ILCE-7M4", True), (34855, "H", 1, 3200, True),
            (50706, "B", 4, (1, 4, 0, 0), True), (50708, "s", 0, "Sony ILCE-7M4", True),
            (33421, "H", 2, (2, 2), True), (33422, "B", 4, (0, 1, 1, 2), True), (50713, "H", 2, (2, 2), True),
            (50714, "2I", 4, [BLACK, 1] * 4, True), (50717, "I", 1, 16383, True),
            (50721, "2i", 9, [1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1], True),
            (50778, "H", 1, 21, True), (50728, "2I", 3, [1, 2, 1, 1, 1, 2], True)]
    src = str(tmp_path / "src.dng")
    tifffile.imwrite(src, src_cfa, photometric=32803, subfiletype=0, extratags=tags, metadata=None)
    cfa = rng.integers(BLACK, 16000, (64, 96), dtype=np.uint16)
    out = str(tmp_path / "out.dng")
    if dng.shutil.which("exiftool"):
        dng.write_cfa_dng(src, cfa, out)
    else:
        with pytest.warns(UserWarning, match="exiftool"):
            dng.write_cfa_dng(src, cfa, out)
    with rawpy.imread(out) as d:
        np.testing.assert_array_equal(d.raw_image_visible, cfa)
        assert list(d.black_level_per_channel) == [BLACK] * 4 and d.white_level == 16383


# ---------------------------------------------------------------- real files (Mac only)

@pytest.mark.parametrize("name", SAMPLES)
def test_identity_roundtrip(tmp_path, name):
    """Unmodified CFA -> DNG -> rawpy gives back the same raw values."""
    rawpy = pytest.importorskip("rawpy")
    src = os.path.join(ROOT, "data", "samples", name)
    if not os.path.exists(src):
        pytest.skip(f"needs real sample {src} (not on the cloud box)")
    if not dng._converter():
        pytest.skip("needs Adobe DNG Converter (set LUMEN_DNG_CONVERTER)")
    with rawpy.imread(src) as r:
        cfa = r.raw_image_visible.copy()
        black, white = list(r.black_level_per_channel), r.white_level
    for single in (False, True):
        out = str(tmp_path / f"out{int(single)}.dng")
        dng.write_cfa_dng(src, cfa, out, pending=dng.start(src), single_pass=single)
        with rawpy.imread(out) as d:
            back = d.raw_image_visible.copy()
            assert list(d.black_level_per_channel) == black, (name, d.black_level_per_channel, black)
            assert d.white_level == white, (name, d.white_level, white)
        # Adobe's raw area can differ from LibRaw's by a few edge rows/cols (outside the crop).
        h, w = min(back.shape[0], cfa.shape[0]), min(back.shape[1], cfa.shape[1])
        assert h > cfa.shape[0] - 8 and w > cfa.shape[1] - 16, (name, back.shape, cfa.shape)
        diff = back[:h, :w] != cfa[:h, :w]
        # Only defect pixels the source stores as 0 (Panasonic) may differ: Adobe repairs them.
        assert (cfa[:h, :w][diff] == 0).all(), (name, int(diff.sum()))
        assert diff.mean() < 1e-4, (name, int(diff.sum()))
