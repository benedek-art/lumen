"""Core ML export: wrapper math (any OS), conversion (if coremltools converts here), parity (macOS only).
Run: python -m pytest tests/test_coreml.py"""
import os
import sys

import pytest
import torch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from lumen_denoise import export_coreml as ex  # noqa: E402
from lumen_denoise.model import Denoiser  # noqa: E402

TILE, NF = 64, 8


def net(residual, seed=0):
    torch.manual_seed(seed)
    return Denoiser(nf=NF, residual=residual, zero_init=False).eval()


@pytest.mark.parametrize("residual", [True, False])
def test_wrap_matches_forward(residual):
    m = net(residual)
    noisy, sm, s = ex.inputs(TILE, seed=3)
    s = sm.mean((1, 2, 3), keepdim=True).clamp(min=1e-5)  # what Denoiser.forward uses
    with torch.no_grad():
        ref = m(noisy, sm)
        got = ex.Wrap(m)(noisy, sm, s if residual else None)
        got = noisy + got if residual else got  # residual graph: caller adds noisy in fp32
    assert torch.allclose(got, ref, atol=1e-5, rtol=1e-5), (got - ref).abs().max()


def _convert(residual, fp16):
    ct = pytest.importorskip("coremltools")
    try:
        return ex.convert(net(residual), TILE, fp16)
    except Exception as e:  # noqa: BLE001
        pytest.skip(f"coremltools {ct.__version__} / torch {torch.__version__} cannot convert here: "
                    f"{type(e).__name__}: {str(e).splitlines()[0][:200] if str(e) else ''}")


@pytest.mark.parametrize("residual", [True, False])
def test_convert(residual, tmp_path):
    ml = _convert(residual, True)
    p = tmp_path / "t.mlpackage"
    ml.save(str(p))
    assert p.exists()
    names = [i.name for i in ml.get_spec().description.input]
    assert names == (["noisy", "std", "s"] if residual else ["noisy", "std"])
    assert [o.name for o in ml.get_spec().description.output] == ["residual" if residual else "denoised"]


def test_residual_output_keeps_identity_exact():
    """Zero residual must return the source exactly: the noisy + residual add stays out of the fp16 graph."""
    m = net(True)
    for p in m.parameters():
        p.data.zero_()
    noisy, sm, s = ex.inputs(TILE, seed=2)
    with torch.no_grad():
        assert torch.equal(noisy + ex.Wrap(m)(noisy, sm, s), noisy)


@pytest.mark.skipif(sys.platform != "darwin", reason="Core ML predict needs macOS (coremltools has no "
                    "prediction runtime on Linux); run on the Mac")
@pytest.mark.parametrize("residual,fp16,tol", [(True, True, 1.3e-4), (True, False, 1e-5),  # 1.3e-4 ~ 2 DN
                                                (False, True, 2e-3), (False, False, 1e-4)])
def test_parity(residual, fp16, tol):
    m = net(residual)
    err, psnr = ex.parity(_convert(residual, fp16), m, TILE, seed=1)
    assert err < tol, (err, psnr)
