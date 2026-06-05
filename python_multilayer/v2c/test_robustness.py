"""Tests for v2c.robustness (digital cell-fault injection + accuracy-vs-fault-rate sweep)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402
import torch  # noqa: E402

import convert as C  # noqa: E402
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
