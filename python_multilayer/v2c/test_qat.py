"""Tests for v2c.qat weight quantizer (run in venv with torch)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import torch  # noqa: E402

import encoding as enc  # noqa: E402
import qat  # noqa: E402

WIDTHS = [1, 2, 4, 8]


@pytest.mark.parametrize("W", WIDTHS)
def test_w_int_in_range_and_packs(W):
    torch.manual_seed(W)
    w = torch.randn(40, 12)
    w_q, w_int, scale = qat.quantize_weight(w, W)
    wi = w_int.cpu().numpy()
    lo, hi = enc.value_range(W)
    assert wi.dtype == np.int64
    assert int(wi.min()) >= lo and int(wi.max()) <= hi
    if W == 1:
        assert set(np.unique(wi).tolist()).issubset({-1, 1})
    if W == 2:
        assert set(np.unique(wi).tolist()).issubset({-1, 0, 1})
    # quantizer output feeds encoding.pack and roundtrips
    cells = enc.pack(wi, W)
    assert np.array_equal(enc.unpack(cells, W, wi.shape[1]), wi)
    # w_q (training forward value) == w_int * scale
    assert torch.allclose(w_q, w_int.float() * scale, atol=1e-5)
    assert float(scale) > 0


@pytest.mark.parametrize("W", WIDTHS)
def test_ste_gradient_flows(W):
    w = torch.randn(20, 8, requires_grad=True)
    w_q, _, _ = qat.quantize_weight(w, W)
    w_q.sum().backward()
    assert w.grad is not None
    assert torch.isfinite(w.grad).all()
    assert float(w.grad.abs().sum()) > 0  # STE passes a real gradient


def test_bnn_no_zeros_and_ternary_sparsifies():
    w = torch.randn(60, 60) * 0.1
    _, wi1, _ = qat.quantize_weight(w, 1)
    assert int((wi1 == 0).sum()) == 0            # BNN has no zero weights
    _, wi2, _ = qat.quantize_weight(w, 2)
    assert int((wi2 == 0).sum()) > 0             # ternary zeros out small weights


@pytest.mark.parametrize("W", [4, 8])
def test_twoscomplement_approximates_weights(W):
    torch.manual_seed(0)
    w = torch.randn(200, 50)
    w_q, _, _ = qat.quantize_weight(w, W)
    # dequantized weights should track the originals (more bits -> tighter)
    rel_err = (w_q - w).abs().mean() / w.abs().mean()
    assert float(rel_err) < (0.2 if W == 4 else 0.03)


def test_unsupported_width_raises():
    with pytest.raises(ValueError):
        qat.quantize_weight(torch.randn(3, 3), 3)


@pytest.mark.parametrize("W", [4, 8])
def test_twoscomplement_symmetric_range(W):
    # symmetric signed quantization: most-negative code -2^(W-1) is reserved but NOT emitted
    torch.manual_seed(0)
    _, w_int, _ = qat.quantize_weight(torch.randn(500, 30) * 5, W)
    qmax = 2 ** (W - 1) - 1
    assert int(w_int.min()) >= -qmax and int(w_int.max()) <= qmax   # never reaches -2^(W-1)


def test_ste_gradient_semantics_bnn():
    # scale = mean|w| = (3+3+0.1)/3 = 2.033; |w/scale|>1 saturated -> grad 0, else -> grad 1
    w = torch.tensor([[3.0, -3.0, 0.1]], requires_grad=True)
    qat.quantize_weight(w, 1)[0].sum().backward()
    assert torch.allclose(w.grad[0], torch.tensor([0.0, 0.0, 1.0]), atol=1e-5)


def test_ste_gradient_semantics_ternary_identity():
    w = torch.randn(8, 4, requires_grad=True)
    qat.quantize_weight(w, 2)[0].sum().backward()
    assert torch.allclose(w.grad, torch.ones_like(w.grad), atol=1e-6)   # identity STE everywhere


@pytest.mark.parametrize("W", [4, 8])
def test_ste_gradient_semantics_twoscomp_identity(W):
    w = torch.randn(8, 4, requires_grad=True)
    qat.quantize_weight(w, W)[0].sum().backward()
    # scale maps max-abs to qmax (within clamp) -> no saturation -> grad 1 everywhere
    assert torch.allclose(w.grad, torch.ones_like(w.grad), atol=1e-6)


@pytest.mark.parametrize("W", WIDTHS)
def test_all_zero_weights_defined(W):
    w_q, w_int, scale = qat.quantize_weight(torch.zeros(5, 3), W)
    assert torch.isfinite(w_q).all() and float(scale) > 0
    wi = w_int.cpu().numpy()
    lo, hi = enc.value_range(W)
    assert int(wi.min()) >= lo and int(wi.max()) <= hi
    if W == 1:
        assert set(np.unique(wi).tolist()).issubset({1})   # all-zero -> all +1 (sign(0)=+1)


# ---- per-output LSQ quantizer (model.QuantLinear path) ----

@pytest.mark.parametrize("W", WIDTHS)
def test_lsq_w_int_in_range_and_packs(W):
    torch.manual_seed(W)
    w = torch.randn(40, 12)                               # [out, in] (nn.Linear layout)
    s = qat.suggested_lsq_scale(w, W, per_output=True)
    assert s.shape == (40, 1) and float(s.min()) > 0
    w_q, w_int = qat.lsq_quantize_weight(w, s, W)
    wi = w_int.cpu().numpy()
    lo, hi = enc.value_range(W)
    assert wi.dtype == np.int64
    assert int(wi.min()) >= lo and int(wi.max()) <= hi
    if W >= 4:                                            # symmetric: never the most-negative code
        assert int(wi.min()) >= -(2 ** (W - 1) - 1)
    if W == 1:
        assert set(np.unique(wi).tolist()).issubset({-1, 1})
    if W == 2:
        assert set(np.unique(wi).tolist()).issubset({-1, 0, 1})
    cells = enc.pack(wi.T, W)                             # [out,in] -> pack wants [in,out]
    assert np.array_equal(enc.unpack(cells, W, wi.shape[0]), wi.T)
    assert torch.allclose(w_q, w_int.float() * s, atol=1e-5)   # training forward == w_int*scale


@pytest.mark.parametrize("W", WIDTHS)
def test_lsq_grad_to_weight_and_scale(W):
    w = torch.randn(20, 8, requires_grad=True)
    s = qat.suggested_lsq_scale(w, W, per_output=True).clone().requires_grad_(True)
    w_q, _ = qat.lsq_quantize_weight(w, s, W)
    w_q.sum().backward()
    assert w.grad is not None and torch.isfinite(w.grad).all() and float(w.grad.abs().sum()) > 0
    assert s.grad is not None and torch.isfinite(s.grad).all() and float(s.grad.abs().sum()) > 0


def test_lsq_per_tensor_scale_ok():
    w = torch.randn(10, 6)
    s = qat.suggested_lsq_scale(w, 4, per_output=False)
    assert s.numel() == 1
    _, w_int = qat.lsq_quantize_weight(w, s, 4)
    assert w_int.shape == (10, 6)


def test_lsq_unsupported_width_raises():
    with pytest.raises(ValueError):
        qat.lsq_quantize_weight(torch.randn(4, 4), torch.ones(4, 1), 3)
