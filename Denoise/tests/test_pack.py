"""pack/unpack and to_rggb/from_rggb on synthetic CFAs (Linux CPU)."""
import numpy as np
import pytest
from lumen_denoise import raw as rawio
from lumen_denoise.prepare import to_rggb, from_rggb

PATTERNS = ["RGGB", "BGGR", "GRBG", "GBRG"]
CODE = {"R": 1, "G": 2, "B": 3}


def _cfa(pattern, h=6, w=8, green_rows=False):
    """Each pixel encodes its color; green_rows=True marks Gr (green on a red row) 20, Gb 30."""
    t = np.array([CODE[c] for c in pattern]).reshape(2, 2)
    if green_rows:
        red_row = 0 if "R" in pattern[:2] else 1
        for i in range(2):
            for j in range(2):
                if pattern[2 * i + j] == "G":
                    t[i, j] = 20 if i == red_row else 30
    return np.tile(t, (h // 2, w // 2)).astype(np.float32)


@pytest.mark.parametrize("shape", [(2, 2), (8, 6), (64, 96)])
@pytest.mark.parametrize("dtype", [np.float32, np.uint16])
def test_pack_unpack_round_trip(shape, dtype):
    a = (np.random.default_rng(0).random(shape) * 60000).astype(dtype)
    p = rawio.pack(a)
    assert p.shape == (4, shape[0] // 2, shape[1] // 2) and p.dtype == dtype
    np.testing.assert_array_equal(rawio.unpack(p), a)


def test_pack_tile_order():
    a = np.arange(16, dtype=np.float32).reshape(4, 4)
    p = rawio.pack(a)
    assert [p[k, 0, 0] for k in range(4)] == [a[0, 0], a[0, 1], a[1, 0], a[1, 1]]


@pytest.mark.parametrize("shape", [(7, 8), (8, 9), (7, 9)])
def test_pack_odd_drops_last_row_col(shape):
    # current behavior: the odd last row/col is dropped; infer.py must restore it from the source
    a = np.random.default_rng(1).random(shape).astype(np.float32)
    h, w = shape[0] // 2 * 2, shape[1] // 2 * 2
    p = rawio.pack(a)
    assert p.shape == (4, h // 2, w // 2)
    np.testing.assert_array_equal(rawio.unpack(p), a[:h, :w])


@pytest.mark.parametrize("pattern", PATTERNS)
def test_rggb_round_trip(pattern):
    p = np.random.default_rng(2).random((4, 5, 7)).astype(np.float32)
    np.testing.assert_array_equal(from_rggb(to_rggb(p, pattern), pattern), p)
    np.testing.assert_array_equal(to_rggb(from_rggb(p, pattern), pattern), p)


@pytest.mark.parametrize("pattern", PATTERNS)
def test_to_rggb_colors(pattern):
    q = to_rggb(rawio.pack(_cfa(pattern)), pattern)
    assert (q[0] == CODE["R"]).all()
    assert (q[1] == CODE["G"]).all() and (q[2] == CODE["G"]).all()
    assert (q[3] == CODE["B"]).all()
    # and back to the original mosaic
    np.testing.assert_array_equal(rawio.unpack(from_rggb(q, pattern)), _cfa(pattern))


# Documents the CURRENT green assignment (training .npy files were prepared with it; do not change
# silently). RGGB/GRBG put Gr (green on the red row) in channel 1; BGGR/GBRG put Gb there.
GREEN_IN_CH1 = {"RGGB": "Gr", "GRBG": "Gr", "BGGR": "Gb", "GBRG": "Gb"}


@pytest.mark.parametrize("pattern", PATTERNS)
def test_to_rggb_green_assignment(pattern):
    q = to_rggb(rawio.pack(_cfa(pattern, green_rows=True)), pattern)
    gr, gb = (20, 30) if GREEN_IN_CH1[pattern] == "Gr" else (30, 20)
    assert (q[1] == gr).all() and (q[2] == gb).all()
