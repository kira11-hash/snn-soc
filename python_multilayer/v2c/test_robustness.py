"""Tests for v2c.robustness (digital cell-fault injection + accuracy-vs-fault-rate sweep)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import torch  # noqa: E402

import convert as C  # noqa: E402
import model as M  # noqa: E402
import robustness as R  # noqa: E402
import spiking as S  # noqa: E402


def test_inject_cell_faults_modes():
    rng = np.random.default_rng(0)
    cells = (np.random.default_rng(1).random((20, 12)) < 0.5).astype(np.int64)
    assert np.array_equal(R.inject_cell_faults(cells, 0.0, "flip", rng), cells)    # rate 0 -> clean copy
    assert (R.inject_cell_faults(cells, 1.0, "stuck0", rng) == 0).all()            # all stuck low
    assert (R.inject_cell_faults(cells, 1.0, "stuck1", rng) == 1).all()            # all stuck high
    assert np.array_equal(R.inject_cell_faults(cells, 1.0, "flip", rng), 1 - cells)  # rate 1 flip = invert
    out = R.inject_cell_faults(cells, 0.3, "flip", rng)
    assert set(np.unique(out).tolist()).issubset({0, 1}) and not np.array_equal(out, cells)
    assert np.array_equal(cells, (np.random.default_rng(1).random((20, 12)) < 0.5).astype(np.int64))  # input untouched
    with pytest.raises(ValueError):
        R.inject_cell_faults(cells, 0.5, "bogus", rng)


def test_robustness_sweep_rate0_matches_clean():
    torch.manual_seed(0)
    T, in_bits = 16, 4
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=T)
    imgs, labs = (np.random.default_rng(3).integers(0, 256, (60, 784)).astype(np.uint8),
                  np.random.default_rng(4).integers(0, 10, 60).astype(np.int64))
    sw = R.robustness_sweep(net, imgs, labs, T, in_bits=in_bits, mode="stuck0",
                            rates=(0.0, 0.3), n_eval=60, trials=2, seed=0)
    traj, n = C.ramp_output_trajectories(net, imgs, T, in_bits=in_bits, n_eval=60)
    clean = float((traj[:, -1, :].argmax(1) == labs[:60]).mean())
    assert sw[0.0][0] == pytest.approx(clean) and sw[0.0][1] == 0.0   # rate 0 == clean, zero variance
    for r, (m, s) in sw.items():
        assert 0.0 <= m <= 1.0 and s >= 0.0


def test_analog_reference_sigma0_matches_ann():
    # the analog baseline at σ=0 + ideal ADC must reproduce the matched ANN's own forward exactly.
    torch.manual_seed(0)
    ann = M.make_mlp("main", 4, bias=False, input_bits=4, act_bits=1, act_hi=2.0)
    imgs = np.random.default_rng(5).integers(0, 256, (64, 784)).astype(np.uint8)
    labs = np.random.default_rng(6).integers(0, 10, 64).astype(np.int64)
    x_in = np.round(imgs.astype(np.float64) / 255.0 * 15) / 15
    a = R.analog_reference_acc(ann, x_in, labs, sigma=0.0, adc_bits=None, rng=np.random.default_rng(0))
    with torch.no_grad():
        ann_acc = float((ann(torch.from_numpy(imgs.astype("float32") / 255.0)).argmax(1).numpy() == labs).mean())
    assert a == pytest.approx(ann_acc)
