"""Tests for v2c.convert (spiking model -> golden TTFS forward bridge). Run in the venv with torch."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import torch  # noqa: E402

import convert as C  # noqa: E402
import encoding as enc  # noqa: E402
import spiking as S  # noqa: E402


def _imgs(n, seed=0):
    rng = np.random.default_rng(seed)
    return (rng.integers(0, 256, size=(n, 784)).astype(np.uint8),
            rng.integers(0, 10, size=n).astype(np.int64))


@pytest.mark.parametrize("W", [1, 2, 4, 8])
def test_export_v2c_layers_shapes(W):
    net = S.V2CSpikingMLP([784, 246, 10], W, T=16)
    layers, meta = C.export_v2c_layers(net)
    assert meta == [(W, 246), (W, 10)]
    for (cells, Wl, out_dim, thr), in_dim in zip(layers, [784, 246]):
        assert cells.shape == (in_dim, out_dim * Wl)
        assert set(np.unique(cells).tolist()).issubset({0, 1})       # binary cells
        assert thr.shape == (out_dim,) and thr.dtype == np.int64     # per-output integer threshold


def test_images_to_streams():
    imgs, _ = _imgs(5)
    streams = C.images_to_streams(imgs, T=8)
    assert len(streams) == 5
    for s in streams:
        assert s.shape == (8, 784)
        assert set(np.unique(s).tolist()).issubset({0, 1})
        assert int(s.sum(axis=0).max()) <= 1                         # TTFS: <=1 spike per input


def test_eval_ttfs_end_to_end():
    imgs, labs = _imgs(20, seed=1)
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=8)
    r = C.eval_ttfs(net, imgs, labs, T=8, n_eval=12)
    assert r["n"] == 12
    assert 0.0 <= r["ttfs_acc"] <= 1.0
    assert 0.0 <= r["fallback_rate"] <= 1.0
    assert 0.0 <= r["algo_latency_mean"] <= 8
    assert r["preds"].shape == (12,) and r["labels"].shape == (12,)


def test_high_threshold_forces_fallback():
    # huge learned thresholds -> no membrane can cross -> every sample falls back (latency = T).
    # confirms the per-output integer threshold array actually reaches the golden forward.
    imgs, labs = _imgs(8, seed=2)
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=8)
    with torch.no_grad():
        for t in net.log_thr:
            t.fill_(20.0)                                            # softplus(20) ~ 20 -> /scale huge
    r = C.eval_ttfs(net, imgs, labs, T=8, n_eval=8)
    assert r["fallback_rate"] == 1.0
    assert r["algo_latency_mean"] == 8


def test_ramp_bitserial_equivalence_and_golden():
    # (1) the bit-serial first-layer golden MAC must equal the direct integer MAC v@w_int (the
    # hardware claim: in_bits binary phase-planes + 2^k shift-add == multi-bit grayscale MAC).
    # (2) the ramp golden (eval_ttfs_ramp) must match the spiking model's hard-classify.
    torch.manual_seed(0)
    T, in_bits = 16, 4
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=T)
    imgs, labs = _imgs(30, seed=5)
    layers, _ = C.export_v2c_layers(net)
    cells1, W1, hid, _ = layers[0]
    w_int1 = net.layers[0].export_int().cpu().numpy()                # [hid, in]
    levels = (1 << in_bits) - 1
    v = np.rint(imgs[0].astype(np.float64) / 255.0 * levels).astype(np.int64)
    z_bitserial = sum((1 << k) * enc.mac(((v >> k) & 1).astype(np.uint8), cells1, W1, hid)
                      for k in range(in_bits))
    assert np.array_equal(z_bitserial, v @ w_int1.T)                 # bit-serial == direct integer MAC
    x01 = torch.from_numpy(imgs.astype(np.float32) / 255.0)
    _, mem_int, _, ft = net(S.encode_ramp(x01, T, in_bits))
    preds_spk = S.hard_classify(ft, mem_int, T).numpy()
    g = C.eval_ttfs_ramp(net, imgs, labs, T, in_bits=in_bits, n_eval=30)
    assert g["n"] == 30 and (preds_spk == g["preds"]).mean() >= 0.9  # only output early-exit/tie differs
