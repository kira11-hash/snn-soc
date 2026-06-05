"""Tests for v2c.robustness (digital fault physics + full-frame/deployed sweeps + analog baseline)."""
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


def _imgs(n, s0=3, s1=4):
    return (np.random.default_rng(s0).integers(0, 256, (n, 784)).astype(np.uint8),
            np.random.default_rng(s1).integers(0, 10, n).astype(np.int64))


def test_inject_cell_faults_modes():
    rng = np.random.default_rng(0)
    cells = (np.random.default_rng(1).random((20, 12)) < 0.5).astype(np.int64)
    assert np.array_equal(R.inject_cell_faults(cells, "invert", rng, rate=0.0), cells)     # rate 0 -> clean
    assert (R.inject_cell_faults(cells, "stuck0", rng, rate=1.0) == 0).all()
    assert (R.inject_cell_faults(cells, "stuck1", rng, rate=1.0) == 1).all()
    assert np.array_equal(R.inject_cell_faults(cells, "invert", rng, rate=1.0), 1 - cells)  # rate 1 invert
    rb = R.inject_cell_faults(cells, "read_ber", rng, p10=1.0, p01=0.0)                     # all 1->0, 0 stay
    assert (rb == 0).all()
    assert np.array_equal(cells, (np.random.default_rng(1).random((20, 12)) < 0.5).astype(np.int64))  # untouched
    with pytest.raises(ValueError):
        R.inject_cell_faults(cells, "bogus", rng)


def test_read_ber_from_device():
    p10, p01 = R.read_ber_from_device(mu_lrs=1.0, sigma_lrs=0.15, mu_hrs=0.05, sigma_hrs=0.02, i_th=0.5)
    assert 0.0 <= p10 <= 1.0 and 0.0 <= p01 <= 1.0
    p10b, p01b = R.read_ber_from_device(mu_lrs=1.0, sigma_lrs=0.04, mu_hrs=0.0, sigma_hrs=0.04, i_th=0.5)
    assert p10b < 0.01 and p01b < 0.01                          # wide margin / tight dist -> tiny BER


def test_robustness_full_frame_and_deployed_rate0():
    torch.manual_seed(0)
    T, in_bits = 16, 4
    net = S.V2CSpikingMLP([784, 246, 10], 4, T=T)
    with torch.no_grad():
        net.log_thr[1].fill_(2.0)
    imgs, labs = _imgs(60)
    traj, n = C.ramp_output_trajectories(net, imgs, T, in_bits=in_bits, n_eval=60)
    clean_ff = float((traj[:, -1, :].argmax(1) == labs[:60]).mean())
    sw = R.robustness_sweep(net, imgs, labs, T, in_bits=in_bits, mode="stuck0", rates=(0.0, 0.3),
                            n_eval=60, trials=2)
    assert sw[0.0][0] == pytest.approx(clean_ff) and sw[0.0][1] == 0.0
    # deployed early-exit: rate-0 must equal the clean strict decode (acc AND latency) with frozen theta
    theta = net.export_int_thresholds()[-1].cpu().numpy()
    preds, lat = C.strict_decode_from_traj(traj, theta, T)
    dsw = R.deployed_robustness_sweep(net, theta, imgs, labs, T, in_bits=in_bits, mode="invert",
                                      rates=(0.0, 0.2), n_eval=60, trials=2)
    assert dsw[0.0][0] == pytest.approx(float((preds == labs[:60]).mean()))
    assert dsw[0.0][2] == pytest.approx(float(lat.mean()))      # latency matches at rate 0
    for lv, tup in dsw.items():
        assert 0.0 <= tup[0] <= 1.0 and tup[2] <= T


def test_analog_reference_ideal_limit_matches_ann():
    # σ=0 + no column noise + no ADC must reproduce the matched ANN's own forward exactly.
    torch.manual_seed(0)
    ann = M.make_mlp("main", 4, bias=False, input_bits=4, act_bits=1, act_hi=2.0)
    imgs, labs = _imgs(64, s0=5, s1=6)
    sw = R.analog_reference_sweep(ann, imgs, labs, in_bits=4, adc_bits=None, sigmas=(0.0,),
                                  sigma_gain=0.0, sigma_off=0.0, sigma_read=0.0, n_eval=64, trials=1)
    with torch.no_grad():
        ann_acc = float((ann(torch.from_numpy(imgs.astype("float32") / 255.0)).argmax(1).numpy() == labs).mean())
    assert sw[0.0][0] == pytest.approx(ann_acc)
