"""Tests for v2c.model (QuantLinear + V2CMLP). Run in the venv with torch."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import torch  # noqa: E402

import encoding as enc  # noqa: E402
import model as M  # noqa: E402

WIDTHS = [1, 2, 4, 8]


@pytest.mark.parametrize("W", WIDTHS)
def test_quantlinear_forward_shape_and_scale(W):
    layer = M.QuantLinear(12, 5, W)
    assert layer.scale.shape == (5, 1)                       # per-output step size
    assert float(layer.scale.detach().min()) > 0
    y = layer(torch.randn(7, 12))
    assert y.shape == (7, 5)


@pytest.mark.parametrize("W", WIDTHS)
def test_quantlinear_export_int_in_range(W):
    layer = M.QuantLinear(16, 9, W)
    wi = layer.export_int().cpu().numpy()
    lo, hi = enc.value_range(W)
    assert wi.shape == (9, 16) and wi.dtype == np.int64
    assert int(wi.min()) >= lo and int(wi.max()) <= hi
    cells = enc.pack(wi.T, W)                                # [out,in] -> pack wants [in,out]
    assert np.array_equal(enc.unpack(cells, W, wi.shape[0]), wi.T)


@pytest.mark.parametrize("W", WIDTHS)
def test_quantlinear_grad_flows(W):
    layer = M.QuantLinear(12, 5, W)
    layer(torch.randn(4, 12)).sum().backward()
    for name, p in layer.named_parameters():
        assert p.grad is not None and torch.isfinite(p.grad).all(), name
    assert float(layer.weight.grad.abs().sum()) > 0
    assert float(layer.log_scale.grad.abs().sum()) > 0           # step size (softplus-parameterised)


def test_scale_stays_positive_and_grad_flows():
    # softplus parameterisation fixes the dead-zone risk: the step size is strictly POSITIVE for any
    # log_scale (a raw clamped Parameter could be pushed <=0 and freeze, with no sign recovery), and
    # the gradient is live in the realistic regime.
    layer = M.QuantLinear(8, 4, 4)
    with torch.no_grad():
        layer.log_scale.fill_(-50.0)                             # extreme: scale would have flipped sign
    assert float(layer.scale.detach().min()) > 0                 # softplus -> always > 0
    layer.reset_parameters()                                     # realistic init (scale ~ LSQ suggestion)
    layer(torch.randn(6, 8)).sum().backward()
    assert layer.log_scale.grad is not None and float(layer.log_scale.grad.abs().sum()) > 0


def test_quantlinear_no_bias():
    layer = M.QuantLinear(8, 4, 4, bias=False)
    assert layer.bias is None
    assert layer(torch.randn(3, 8)).shape == (3, 4)


@pytest.mark.parametrize("arch,dims", [("main", [784, 246, 10]), ("ablation", [784, 160, 80, 10])])
def test_mlp_arch_dims_and_forward(arch, dims):
    net = M.make_mlp(arch, 4)
    assert net.dims == dims
    assert [l.out_features for l in net.layers] == dims[1:]
    assert [l.in_features for l in net.layers] == dims[:-1]
    y = net(torch.rand(6, 784))
    assert y.shape == (6, 10)


def test_mlp_per_layer_width_list():
    net = M.V2CMLP([784, 64, 10], W=[1, 4])
    assert [l.W for l in net.layers] == [1, 4]


def test_mlp_all_params_get_grad():
    net = M.make_mlp("main", 4)
    out = net(torch.rand(5, 784))
    torch.nn.functional.cross_entropy(out, torch.randint(0, 10, (5,))).backward()
    for name, p in net.named_parameters():
        assert p.grad is not None and torch.isfinite(p.grad).all(), name


def test_bad_arch_and_width_list_raise():
    with pytest.raises(ValueError):
        M.make_mlp("nope", 4)
    with pytest.raises(ValueError):
        M.V2CMLP([784, 64, 10], W=[1, 4, 8])                 # 3 widths for 2 layers
    with pytest.raises(ValueError):
        M.V2CMLP([784], W=4)                                 # too few dims
