"""Unit tests for v2c.ttfs (run in project venv: `python -m pytest python_multilayer/v2c/`)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

import ttfs  # noqa: E402

TS = [1, 16, 32, 64]


@pytest.mark.parametrize("T", TS)
def test_brightest_earliest_and_zero_no_spike(T):
    px = np.array([255, 128, 1, 0], dtype=np.int64)
    t = ttfs.encode_pixel_to_ttfs(px, T)
    assert t[0] == 0                       # brightest fires first
    assert t[3] == ttfs.NO_SPIKE           # zero never fires (default)
    assert t[1] != ttfs.NO_SPIKE and 0 <= t[1] <= T - 1
    if T > 1:
        assert t[2] == T - 1               # dimmest non-zero fires last


@pytest.mark.parametrize("T", TS)
def test_monotonic_nonincreasing_in_intensity(T):
    px = np.arange(0, 256, dtype=np.int64)            # 0..255
    t = ttfs.encode_pixel_to_ttfs(px, T)
    nz = px > 0
    times = t[nz]
    # higher intensity (later index) -> earlier-or-equal spike time
    assert np.all(np.diff(times) <= 0)


def test_fire_on_zero():
    t = ttfs.encode_pixel_to_ttfs(np.array([0, 255]), 16, fire_on_zero=True)
    assert t[0] == 15 and t[1] == 0


@pytest.mark.parametrize("T", TS)
def test_roundtrip_times_stream_times(T):
    rng = np.random.default_rng(T)
    px = rng.integers(0, 256, size=40)
    t = ttfs.encode_pixel_to_ttfs(px, T)
    stream = ttfs.ttfs_times_to_stream(t, T)
    assert stream.shape == (T, 40)
    assert np.all(stream.sum(axis=0) <= 1)            # <= 1 spike per neuron
    assert np.array_equal(ttfs.ttfs_stream_to_times(stream), t)


def test_stream_to_times_picks_first():
    stream = np.zeros((5, 2), dtype=np.uint8)
    stream[3, 0] = 1
    stream[1, 1] = 1
    stream[4, 1] = 1                                   # later spike on neuron 1 ignored
    assert np.array_equal(ttfs.ttfs_stream_to_times(stream), np.array([3, 1]))


def test_T1_all_nonzero_fire_at_zero():
    t = ttfs.encode_pixel_to_ttfs(np.array([0, 1, 255]), 1)
    assert np.array_equal(t, np.array([ttfs.NO_SPIKE, 0, 0]))


def test_stream_time_out_of_range_rejected():
    with pytest.raises(ValueError):
        ttfs.ttfs_times_to_stream(np.array([5]), 5)   # valid times are 0..4


def test_times_to_stream_rejects_negative_below_sentinel():
    with pytest.raises(ValueError):
        ttfs.ttfs_times_to_stream(np.array([-2, 0]), 4)   # only -1 is a valid negative


def test_times_to_stream_rejects_T_lt_1():
    with pytest.raises(ValueError):
        ttfs.ttfs_times_to_stream(np.array([0]), 0)


def test_times_to_stream_rejects_non_integer():
    with pytest.raises(ValueError):
        ttfs.ttfs_times_to_stream(np.array([0.5]), 4)


def test_times_to_stream_rejects_non_1d():
    with pytest.raises(ValueError):
        ttfs.ttfs_times_to_stream(np.zeros((2, 3), dtype=np.int64), 4)


def test_stream_to_times_rejects_non_2d():
    with pytest.raises(ValueError):
        ttfs.ttfs_stream_to_times(np.zeros(5, dtype=np.uint8))


def test_encode_rejects_bad_max_val():
    with pytest.raises(ValueError):
        ttfs.encode_pixel_to_ttfs(np.array([1]), 16, max_val=0)
    with pytest.raises(ValueError):
        ttfs.encode_pixel_to_ttfs(np.array([1]), 16, max_val=-5)
