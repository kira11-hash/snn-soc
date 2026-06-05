"""Tests for v2c.spiking (surrogate-gradient TTFS-IF model). Run in the venv with torch."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import torch  # noqa: E402

import convert as C  # noqa: E402
import encoding as enc  # noqa: E402
import forward as fwd  # noqa: E402
import spiking as S  # noqa: E402
import ttfs  # noqa: E402

WIDTHS = [1, 2, 4, 8]


def test_spikefn_forward_and_surrogate_grad():
    x = torch.tensor([-2.0, -0.1, 0.0, 0.1, 2.0], requires_grad=True)
    s = S.SpikeFn.apply(x, 5.0)
    assert s.tolist() == [0.0, 0.0, 1.0, 1.0, 1.0]            # Heaviside at x>=0
    s.sum().backward()
    assert torch.isfinite(x.grad).all()
    assert float(x.grad[2]) == pytest.approx(1.0)            # surrogate peak at x=0: 1/(1+0)^2
    assert float(x.grad[0]) < float(x.grad[1])               # decays with |x|


def test_encode_stream_matches_ttfs_golden():
    rng = np.random.default_rng(0)
    imgs_u8 = rng.integers(0, 256, size=(6, 784)).astype(np.uint8)
    x01 = torch.from_numpy(imgs_u8.astype(np.float32) / 255.0)
    for T in (8, 16, 32):
        st = S.encode_stream(x01, T).numpy().astype(np.uint8)
        for i in range(6):
            ref = ttfs.ttfs_times_to_stream(ttfs.encode_pixel_to_ttfs(imgs_u8[i], T), T)
            assert np.array_equal(st[i], ref)
        assert int(st.sum(axis=1).max()) <= 1                # TTFS: <=1 spike per (sample,input)


@pytest.mark.parametrize("W", WIDTHS)
def test_forward_shapes_and_grads(W):
    torch.manual_seed(W)
    net = S.V2CSpikingMLP([784, 64, 10], W, T=12, thr_init=1.5)
    stream = S.encode_stream(torch.rand(8, 784), 12)
    earliness, mem_int, mem_loss, ft = net(stream)
    assert earliness.shape == (8, 10) and mem_int.shape == (8, 10)
    assert mem_loss.shape == (8, 10) and ft.shape == (8, 10)
    assert ft.dtype == torch.long and int(ft.min()) >= 0 and int(ft.max()) <= 12
    loss = S.ttfs_loss(earliness, mem_loss, torch.randint(0, 10, (8,)))
    loss.backward()
    for layer in net.layers:
        assert layer.weight.grad is not None and float(layer.weight.grad.abs().sum()) > 0
        assert layer.log_scale.grad is not None and torch.isfinite(layer.log_scale.grad).all()
    for t in net.log_thr:
        assert t.grad is not None and torch.isfinite(t.grad).all()


@pytest.mark.parametrize("W", WIDTHS)
def test_export_int_weights_and_thresholds(W):
    net = S.V2CSpikingMLP([784, 64, 10], W, T=16)
    int_thr = net.export_int_thresholds()
    lo, hi = enc.value_range(W)
    for layer, thr in zip(net.layers, int_thr):
        wi = layer.export_int().cpu().numpy()
        assert int(wi.min()) >= lo and int(wi.max()) <= hi
        assert thr.shape == (layer.out_features,) and thr.dtype == torch.long
        assert int(thr.min()) >= 1                            # export clamps θ_int>=1 (no t=0 fire)


def test_thresholds_positive():
    net = S.V2CSpikingMLP([20, 8, 4], 4, T=8, thr_init=1.0)
    for t in net.thresholds():
        assert float(t.detach().min()) > 0                    # softplus keeps threshold positive


def test_hard_classify_semantics():
    T = 8
    # neuron 2 fires earliest -> wins regardless of membrane
    ft = torch.tensor([[5, 3, 1, 7]])
    mem = torch.tensor([[9.0, 9.0, -1.0, 9.0]])
    assert int(S.hard_classify(ft, mem, T)[0]) == 2
    # tie at earliest time between 0 and 3 -> higher membrane (3) wins
    ft2 = torch.tensor([[2, 5, 6, 2]])
    mem2 = torch.tensor([[1.0, 0.0, 0.0, 4.0]])
    assert int(S.hard_classify(ft2, mem2, T)[0]) == 3
    # nobody fires (all == T) -> fallback argmax membrane
    ft3 = torch.tensor([[8, 8, 8, 8]])
    mem3 = torch.tensor([[1.0, 5.0, 2.0, 0.0]])
    assert int(S.hard_classify(ft3, mem3, T)[0]) == 1


def test_hidden_fire_decisions_bit_exact_with_golden():
    # P0 fix: the spiking forward fires on the EXACT integer membrane, so hidden-layer first-spike
    # times must match forward.py bit-for-bit (no float-accumulation boundary drift). Hidden layers
    # run full T in both, so this is an exact equality (the output layer early-exits, tested below).
    torch.manual_seed(0)
    T = 16
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=T, thr_init=2.0)
    rng = np.random.default_rng(0)
    imgs_u8 = rng.integers(0, 256, size=(30, 784)).astype(np.uint8)
    x01 = torch.from_numpy(imgs_u8.astype(np.float32) / 255.0)
    spk_times = net.per_layer_first_times(S.encode_stream(x01, T))            # list per layer [B,out]
    layers, _ = C.export_v2c_layers(net)
    for i in range(30):
        s_i = ttfs.ttfs_times_to_stream(ttfs.encode_pixel_to_ttfs(imgs_u8[i], T), T)
        res = fwd.multilayer_ttfs_forward(s_i, layers, T)
        gold_hidden = res["per_layer_spike_times"][0]                        # [246], NO_SPIKE=-1
        gold_hidden = np.where(gold_hidden == ttfs.NO_SPIKE, T, gold_hidden)
        assert np.array_equal(spk_times[0][i].numpy(), gold_hidden)          # bit-exact hidden fire


def test_spiking_matches_golden_forward():
    # the spiking model's hard-classify must agree with the golden forward.py on the SAME exported
    # integer weights + thresholds. With integer-exact fire + integer-membrane classification, the
    # only residual is the output layer's early-exit / same-step tie ordering.
    torch.manual_seed(0)
    T = 16
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=T, thr_init=2.0)
    rng = np.random.default_rng(0)
    imgs_u8 = rng.integers(0, 256, size=(60, 784)).astype(np.uint8)
    x01 = torch.from_numpy(imgs_u8.astype(np.float32) / 255.0)
    _, mem_int, _, ft = net(S.encode_stream(x01, T))
    preds_spk = S.hard_classify(ft, mem_int, T).numpy()
    layers, _ = C.export_v2c_layers(net)
    preds_gold = np.array([
        fwd.multilayer_ttfs_forward(ttfs.ttfs_times_to_stream(ttfs.encode_pixel_to_ttfs(imgs_u8[i], T), T),
                                    layers, T)["pred"]
        for i in range(60)
    ])
    assert (preds_spk == preds_gold).mean() >= 0.95          # only output early-exit/tie can differ


def test_can_overfit_tiny_batch():
    # a few SGD steps on a fixed tiny batch must reduce the loss (gradients actually learn).
    torch.manual_seed(0)
    T = 12
    net = S.V2CSpikingMLP([784, 64, 10], 4, T=T, thr_init=1.5)
    stream = S.encode_stream(torch.rand(16, 784), T)
    y = torch.randint(0, 10, (16,))
    opt = torch.optim.AdamW(net.parameters(), lr=5e-3)
    e0, _, m0, _ = net(stream)
    loss0 = float(S.ttfs_loss(e0, m0, y).detach())
    for _ in range(40):
        e, _, m, _ = net(stream)
        loss = S.ttfs_loss(e, m, y)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
    assert float(loss.detach()) < loss0                      # learning happens


@pytest.mark.parametrize("in_bits", [1, 4, 8])
def test_encode_ramp_multibit(in_bits):
    # multi-bit grayscale ramp input (Option A): same quantized value every timestep, integer 0..levels
    x01 = torch.rand(4, 784)
    r = S.encode_ramp(x01, T=8, in_bits=in_bits)
    levels = (1 << in_bits) - 1
    assert r.shape == (4, 8, 784)
    assert float(r.min()) >= 0 and float(r.max()) <= levels
    assert torch.allclose(r, r.round())                      # integer-valued levels
    assert torch.allclose(r[:, 0, :], r[:, 5, :])            # ramp = value repeated over T


def test_ramp_forward_grad_finite():
    # data-driven threshold init on the large ramp membrane exercises the stable softplus^{-1}
    # (log(expm1(y)) overflows for y>~88 -> NaN gradient); finite grad confirms the fix.
    torch.manual_seed(0)
    net = S.V2CSpikingMLP([784, 64, 10], 4, T=8)
    ramp = S.encode_ramp(torch.rand(8, 784), 8, in_bits=4)
    net.init_thresholds_from_data(ramp, fire_fraction=0.5)
    e, _, ml, _ = net(ramp)
    S.ttfs_loss(e, ml, torch.randint(0, 10, (8,))).backward()
    g = net.layers[0].weight.grad
    assert g is not None and torch.isfinite(g).all()


def test_fp32_membrane_guard_raises_unsafe_config():
    # the integer membrane is accumulated in fp32 (exact only < 2^24). W=8 + 8-bit input + T=32 pushes
    # it past that -> not bit-exact with the int64 golden -> must raise loudly (not silently lose bits).
    torch.manual_seed(0)
    net = S.V2CSpikingMLP([784, 64, 10], 8, T=32)
    ramp = S.encode_ramp(torch.rand(4, 784), 32, in_bits=8)
    with pytest.raises(ValueError):
        net(ramp)
