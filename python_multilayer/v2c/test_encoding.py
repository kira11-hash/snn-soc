"""Unit tests for v2c.encoding (run in the project venv: `python -m pytest python_multilayer/v2c/`)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

import encoding as enc  # noqa: E402

WIDTHS = [1, 2, 4, 8]


def _rand_weights(rng, in_dim, out_dim, W):
    lo, hi = enc.value_range(W)
    if W == 1:
        return rng.choice([-1, 1], size=(in_dim, out_dim))
    if W == 2:
        return rng.integers(-1, 2, size=(in_dim, out_dim))  # {-1,0,1}
    return rng.integers(lo, hi + 1, size=(in_dim, out_dim))


def _explicit_mac(spikes, cells, W, out_dim):
    """Reference MAC with EXPLICIT col=out*W+bit indexing — independent of enc's k::W slicing."""
    in_dim = spikes.shape[0]
    n_active = int(spikes.sum())
    out = np.zeros(out_dim, dtype=np.int64)
    for o in range(out_dim):
        if W == 1:
            pc = sum(int(spikes[i]) * int(cells[i, o]) for i in range(in_dim))
            out[o] = 2 * pc - n_active
        elif W == 2:
            pos = sum(int(spikes[i]) * int(cells[i, o * 2 + 0]) for i in range(in_dim))
            neg = sum(int(spikes[i]) * int(cells[i, o * 2 + 1]) for i in range(in_dim))
            out[o] = pos - neg
        else:
            acc = 0
            for k in range(W):
                pc = sum(int(spikes[i]) * int(cells[i, o * W + k]) for i in range(in_dim))
                acc += -(1 << k) * pc if k == W - 1 else (1 << k) * pc
            out[o] = acc
    return out


@pytest.mark.parametrize("W", WIDTHS)
def test_outputs_per_macro(W):
    assert enc.outputs_per_macro(W) == 1024 // W
    assert enc.outputs_per_macro(W) == {1: 1024, 2: 512, 4: 256, 8: 128}[W]


@pytest.mark.parametrize("W", WIDTHS)
def test_roundtrip(W):
    rng = np.random.default_rng(0)
    in_dim, out_dim = 37, 11
    w = _rand_weights(rng, in_dim, out_dim, W)
    cells = enc.pack(w, W)
    assert cells.shape == (in_dim, out_dim * W)
    assert set(np.unique(cells).tolist()).issubset({0, 1})
    assert np.array_equal(enc.unpack(cells, W, out_dim), w)


@pytest.mark.parametrize("W", WIDTHS)
def test_mac_equals_reference(W):
    rng = np.random.default_rng(W)
    in_dim, out_dim = 53, 7
    for _ in range(20):
        w = _rand_weights(rng, in_dim, out_dim, W)
        cells = enc.pack(w, W)
        spikes = rng.integers(0, 2, size=in_dim)
        got = enc.mac(spikes, cells, W, out_dim)
        ref = spikes.astype(np.int64) @ enc.unpack(cells, W, out_dim)
        assert np.array_equal(got, ref)


@pytest.mark.parametrize("W", [4, 8])
def test_twoscomp_extremes(W):
    lo, hi = enc.value_range(W)
    w = np.array([[lo, hi, 0, -1, 1]], dtype=np.int64)
    cells = enc.pack(w, W)
    assert np.array_equal(enc.unpack(cells, W, w.shape[1]), w)
    spikes = np.ones(1, dtype=np.int64)  # one active row -> partial == the weights
    assert np.array_equal(enc.mac(spikes, cells, W, w.shape[1]), w[0])


def test_bnn_rejects_zero():
    with pytest.raises(ValueError):
        enc.pack(np.array([[0]], dtype=np.int64), 1)


def test_out_of_range_rejected():
    with pytest.raises(ValueError):
        enc.pack(np.array([[8]], dtype=np.int64), 4)  # max is +7 for W=4


def test_ternary_illegal_detected_and_decodes_zero():
    rng = np.random.default_rng(1)
    w = rng.integers(-1, 2, size=(10, 4))
    cells = enc.pack(w, 2)
    assert enc.count_ternary_illegal(cells) == 0  # legal pack never produces (1,1)
    # force an illegal (1,1) on output 0
    bad = cells.copy()
    bad[0, 0] = 1  # pos of out0
    bad[0, 1] = 1  # neg of out0
    assert enc.count_ternary_illegal(bad) == 1
    assert enc.unpack(bad, 2, 4)[0, 0] == 0  # decodes to 0, not silently wrong
    spikes = np.zeros(10, dtype=np.int64)
    spikes[0] = 1
    assert enc.mac(spikes, bad, 2, 4)[0] == 0


@pytest.mark.parametrize("W", WIDTHS)
def test_mac_matches_explicit_index_reference(W):
    rng = np.random.default_rng(100 + W)
    in_dim, out_dim = 23, 5
    w = _rand_weights(rng, in_dim, out_dim, W)
    cells = enc.pack(w, W)
    spikes = rng.integers(0, 2, size=in_dim)
    assert np.array_equal(enc.mac(spikes, cells, W, out_dim),
                          _explicit_mac(spikes, cells, W, out_dim))


def test_mac_shape_mismatch_raises():
    cells = enc.pack(np.array([[1, -1], [1, 1]], dtype=np.int64), 1)  # in=2,out=2 -> [2,2]
    with pytest.raises(ValueError):
        enc.mac(np.array([1]), cells, 1, 2)        # spikes len 1 vs 2 rows (would broadcast)
    with pytest.raises(ValueError):
        enc.mac(np.array([1, 0]), cells, 1, 5)     # wrong out_dim


def test_unpack_shape_mismatch_raises():
    cells = enc.pack(np.array([[3, -2]], dtype=np.int64), 4)  # [1,8]
    with pytest.raises(ValueError):
        enc.unpack(cells, 4, 3)                     # expects 12 cols, has 8


def test_pack_rejects_non_integer():
    with pytest.raises(ValueError):
        enc.pack(np.array([[0.9]]), 2)


def test_pack_negative_out_of_range():
    with pytest.raises(ValueError):
        enc.pack(np.array([[-9]], dtype=np.int64), 4)  # min is -8


@pytest.mark.parametrize("W", WIDTHS)
def test_empty_out_dim(W):
    cells = enc.pack(np.zeros((3, 0), dtype=np.int64), W)
    assert cells.shape == (3, 0)
    assert np.array_equal(enc.mac(np.array([1, 0, 1]), cells, W, 0), np.zeros(0, dtype=np.int64))
