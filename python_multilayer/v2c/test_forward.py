"""Unit tests for v2c.forward (run in project venv: `python -m pytest python_multilayer/v2c/`)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

import encoding as enc  # noqa: E402
import forward as fwd  # noqa: E402
import ttfs  # noqa: E402

WIDTHS = [1, 2, 4, 8]


def _rand_weights(rng, in_dim, out_dim, W):
    lo, hi = enc.value_range(W)
    if W == 1:
        return rng.choice([-1, 1], size=(in_dim, out_dim))
    if W == 2:
        return rng.integers(-1, 2, size=(in_dim, out_dim))
    return rng.integers(lo, hi + 1, size=(in_dim, out_dim))


def _ref_forward(stream, cells, W, out_dim, threshold, early_exit=False):
    """Reference forward via unpack + matmul (independent of mac's popcount path)."""
    T = stream.shape[0]
    w = enc.unpack(cells, W, out_dim)
    membrane = np.zeros(out_dim, dtype=np.int64)
    times = np.full(out_dim, ttfs.NO_SPIKE, dtype=np.int64)
    for t in range(T):
        membrane += stream[t].astype(np.int64) @ w
        for j in range(out_dim):
            if times[j] == ttfs.NO_SPIKE and membrane[j] >= threshold:
                times[j] = t
        if early_exit and np.any(times != ttfs.NO_SPIKE):
            break
    return times, membrane


@pytest.mark.parametrize("W", WIDTHS)
def test_forward_matches_reference(W):
    rng = np.random.default_rng(W)
    in_dim, out_dim, T = 30, 6, 16
    for _ in range(10):
        cells = enc.pack(_rand_weights(rng, in_dim, out_dim, W), W)
        px = rng.integers(0, 256, size=in_dim)
        stream = ttfs.ttfs_times_to_stream(ttfs.encode_pixel_to_ttfs(px, T), T)
        threshold = int(rng.integers(1, 40))
        st, mem, _ = fwd.ttfs_layer_forward(stream, cells, W, out_dim, threshold)
        rst, rmem = _ref_forward(stream, cells, W, out_dim, threshold)
        assert np.array_equal(st, rst)
        assert np.array_equal(mem, rmem)


def test_classify_earliest_wins():
    st = np.array([5, 2, ttfs.NO_SPIKE, 8])
    pred, fb = fwd.ttfs_classify(st, np.zeros(4, dtype=np.int64))
    assert pred == 1 and not fb


def test_classify_tiebreak_membrane_then_index():
    st = np.array([2, 2, 2])                 # all earliest at t=2
    mem = np.array([5, 9, 9])                # neurons 1,2 tie on max membrane
    pred, fb = fwd.ttfs_classify(st, mem)
    assert pred == 1 and not fb              # max membrane, lowest index among ties


def test_classify_fallback_argmax_membrane():
    st = np.full(4, ttfs.NO_SPIKE)
    pred, fb = fwd.ttfs_classify(st, np.array([3, 7, 7, 1]))
    assert pred == 1 and fb                  # no spike -> argmax membrane (lowest idx on tie)


def test_early_exit_stops_at_first_spike_and_captures_earliest():
    rng = np.random.default_rng(7)
    in_dim, out_dim, T, W = 40, 8, 32, 4
    cells = enc.pack(_rand_weights(rng, in_dim, out_dim, W), W)
    stream = ttfs.ttfs_times_to_stream(
        ttfs.encode_pixel_to_ttfs(rng.integers(0, 256, size=in_dim), T), T)
    thr = 20
    st_full, _, steps_full = fwd.ttfs_layer_forward(stream, cells, W, out_dim, thr)
    st_ee, mem_ee, steps_ee = fwd.ttfs_layer_forward(stream, cells, W, out_dim, thr, early_exit=True)
    fired = st_full != ttfs.NO_SPIKE
    if np.any(fired):
        earliest = int(st_full[fired].min())
        at_earliest = fired & (st_full == earliest)
        assert steps_ee == earliest + 1                              # stops right after first spike
        assert np.array_equal(st_ee != ttfs.NO_SPIKE, at_earliest)   # captured exactly the earliest firers
        winner, fb = fwd.ttfs_classify(st_ee, mem_ee)                # tie-break uses membrane-at-earliest
        assert (not fb) and at_earliest[winner]
    else:
        assert steps_ee == steps_full == T                           # no spike -> ran full T


def test_forward_rejects_bad_stream():
    cells = enc.pack(np.array([[1, -1]], dtype=np.int64), 1)
    with pytest.raises(ValueError):
        fwd.ttfs_layer_forward(np.zeros(5, dtype=np.uint8), cells, 1, 2, 1)  # 1-D stream


def test_forward_rejects_repeated_input_spike():
    cells = enc.pack(np.array([[1], [1]], dtype=np.int64), 1)   # in=2, out=1
    stream = np.array([[1, 0], [1, 0]], dtype=np.uint8)         # input neuron 0 spikes at t0 AND t1
    with pytest.raises(ValueError):
        fwd.ttfs_layer_forward(stream, cells, 1, 1, 1)


def test_forward_rejects_bad_T_and_out_dim():
    cells = enc.pack(np.array([[1, -1]], dtype=np.int64), 1)    # in=1, out=2
    with pytest.raises(ValueError):
        fwd.ttfs_layer_forward(np.zeros((0, 1), dtype=np.uint8), cells, 1, 2, 1)  # T=0
    with pytest.raises(ValueError):
        fwd.ttfs_layer_forward(np.zeros((4, 1), dtype=np.uint8), cells, 1, 0, 1)  # out_dim=0


def test_classify_rejects_length_mismatch():
    with pytest.raises(ValueError):
        fwd.ttfs_classify(np.array([0, 1]), np.array([1, 2, 3]))


def test_classify_rejects_illegal_negative_and_empty():
    with pytest.raises(ValueError):
        fwd.ttfs_classify(np.array([-2, 0]), np.array([1, 2]))      # -2 < NO_SPIKE
    with pytest.raises(ValueError):
        fwd.ttfs_classify(np.array([], dtype=np.int64), np.array([], dtype=np.int64))


def test_tiebreak_uses_early_exit_membrane_not_final():
    """Both outputs fire at t=0; membrane@t0 favors out0, but full-run final membrane favors out1.
    Correct TTFS classification (early-exit membrane) must pick out0."""
    W, out_dim, T = 4, 2, 4
    w = np.array([[2, 1], [1, 1], [0, 5]], dtype=np.int64)      # in=3, out=2
    cells = enc.pack(w, W)
    stream = ttfs.ttfs_times_to_stream(np.array([0, 0, 2]), T)  # inputs 0,1 at t0; input 2 at t2
    thr = 2
    st_ee, mem_ee, steps_ee = fwd.ttfs_layer_forward(stream, cells, W, out_dim, thr, early_exit=True)
    st_full, mem_full, _ = fwd.ttfs_layer_forward(stream, cells, W, out_dim, thr)
    assert steps_ee == 1 and np.array_equal(st_ee, [0, 0])
    assert np.array_equal(mem_ee, [3, 2]) and np.array_equal(mem_full, [3, 7])
    assert fwd.ttfs_classify(st_ee, mem_ee)[0] == 0            # correct: early-exit (first-spike) membrane
    assert fwd.ttfs_classify(st_full, mem_full)[0] == 1        # final membrane would wrongly pick out1


def _ref_multilayer(input_stream, layers, T):
    """Chained reference: hidden layers full, output layer early-exit (matches multilayer_ttfs_forward)."""
    stream = input_stream
    st = mem = None
    last = len(layers) - 1
    for i, (cells, W, out_dim, thr) in enumerate(layers):
        st, mem = _ref_forward(stream, cells, W, out_dim, thr, early_exit=(i == last))
        if i != last:
            stream = ttfs.ttfs_times_to_stream(st, T)
    return st, mem


@pytest.mark.parametrize("W", [1, 4])
def test_multilayer_matches_chained_reference(W):
    rng = np.random.default_rng(200 + W)
    T = 16
    dims = [(20, 8), (8, 5)]                                   # (in,out) per layer; chained
    stream0 = ttfs.ttfs_times_to_stream(
        ttfs.encode_pixel_to_ttfs(rng.integers(0, 256, size=dims[0][0]), T), T)
    layers = [(enc.pack(_rand_weights(rng, i, o, W), W), W, o, int(rng.integers(1, 10)))
              for (i, o) in dims]
    res = fwd.multilayer_ttfs_forward(stream0, layers, T)
    rst, rmem = _ref_multilayer(stream0, layers, T)   # reference: hidden full, output early-exit
    assert np.array_equal(res["out_spike_times"], rst)
    assert np.array_equal(res["out_membrane"], rmem)
    assert res["pred"] == fwd.ttfs_classify(rst, rmem)[0]
    assert len(res["per_layer_spike_times"]) == len(layers)


def test_multilayer_single_layer_equals_output_layer():
    rng = np.random.default_rng(9)
    T, W = 16, 4
    stream = ttfs.ttfs_times_to_stream(ttfs.encode_pixel_to_ttfs(rng.integers(0, 256, 12), T), T)
    cells = enc.pack(_rand_weights(rng, 12, 5, W), W)
    res = fwd.multilayer_ttfs_forward(stream, [(cells, W, 5, 6)], T)
    st, mem, _ = fwd.ttfs_layer_forward(stream, cells, W, 5, 6, early_exit=True)
    assert res["pred"] == fwd.ttfs_classify(st, mem)[0]


def test_multilayer_rejects_empty():
    with pytest.raises(ValueError):
        fwd.multilayer_ttfs_forward(np.zeros((4, 3), dtype=np.uint8), [], 4)


def test_multilayer_pred_uses_early_exit_membrane_not_final():
    # single output layer where early-exit membrane (->out0) and full-run final membrane (->out1) disagree
    W, out_dim, T = 4, 2, 4
    cells = enc.pack(np.array([[2, 1], [1, 1], [0, 5]], dtype=np.int64), W)
    stream = ttfs.ttfs_times_to_stream(np.array([0, 0, 2]), T)
    res = fwd.multilayer_ttfs_forward(stream, [(cells, W, out_dim, 2)], T)
    assert res["pred"] == 0          # output always early-exits -> first-spike membrane -> out0


def test_multilayer_rejects_T_mismatch():
    cells = enc.pack(np.array([[1, -1]], dtype=np.int64), 1)   # in=1, out=2
    with pytest.raises(ValueError):
        fwd.multilayer_ttfs_forward(np.zeros((2, 1), dtype=np.uint8), [(cells, 1, 2, 1)], 4)  # T=2 != 4
    with pytest.raises(ValueError):
        fwd.multilayer_ttfs_forward(np.zeros((0, 1), dtype=np.uint8), [(cells, 1, 2, 1)], 0)  # T=0
