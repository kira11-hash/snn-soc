"""
V2C TTFS (time-to-first-spike) input encoding.

Each input neuron fires **at most once** per frame; pixel intensity maps to a spike
TIME (brighter = earlier). ``T`` timesteps give ~log2(T) bits of activation precision.
Zero pixels optionally never fire ("零像素可不发放", plan-v1.md). This is the input-side
temporal code that feeds the digital-CIM MAC (see encoding.py).

Convention: spike time in ``[0, T-1]``, ``t=0`` is the EARLIEST. ``NO_SPIKE = -1`` sentinel.
TTFS latency is dominated by the time-to-first-OUTPUT-spike; encoding the input this way
is what lets the accelerator early-exit (plan-v1.md headline = latency).

Pure numpy. No torch, no analog physics.
"""
import numpy as np

NO_SPIKE = -1


def encode_pixel_to_ttfs(pixels, T, max_val=255, fire_on_zero=False):
    """Intensity -> first-spike time (brighter = earlier).

    pixels  : array [..., in_dim], intensity in [0, max_val].
    T       : timesteps (>= 1).
    returns : int64 array, same shape; brightest -> t=0, dimmest non-zero -> t=T-1;
              intensity 0 -> NO_SPIKE unless ``fire_on_zero`` (then t=T-1).
    """
    if T < 1:
        raise ValueError("T must be >= 1")
    if max_val <= 0:
        raise ValueError("max_val must be > 0")
    p = np.asarray(pixels, dtype=np.float64)
    norm = np.clip(p / float(max_val), 0.0, 1.0)            # brighter -> larger
    t = np.rint((1.0 - norm) * (T - 1)).astype(np.int64)    # brightest->0, dim->T-1
    if fire_on_zero:
        return t
    return np.where(p > 0, t, NO_SPIKE).astype(np.int64)


def ttfs_times_to_stream(times, T):
    """First-spike times ``[in_dim]`` -> binary spike stream ``[T, in_dim]`` (one 1 per fired neuron)."""
    if T < 1:
        raise ValueError("T must be >= 1")
    t0 = np.asarray(times)
    if t0.ndim != 1:
        raise ValueError("times must be 1-D [in_dim]")
    if not np.issubdtype(t0.dtype, np.integer) and not np.all(t0 == np.rint(t0)):
        raise ValueError("times must be integer-valued")
    times = t0.astype(np.int64)
    if np.any(times < NO_SPIKE):
        raise ValueError(f"invalid spike time < {NO_SPIKE} (only {NO_SPIKE}=NO_SPIKE is a valid negative)")
    in_dim = times.shape[0]
    fired = times >= 0
    if np.any(times[fired] >= T):
        raise ValueError("spike time >= T")
    stream = np.zeros((T, in_dim), dtype=np.uint8)
    stream[times[fired], np.nonzero(fired)[0]] = 1
    return stream


def ttfs_stream_to_times(stream):
    """Binary spike stream ``[T, in_dim]`` -> first-spike times ``[in_dim]`` (NO_SPIKE if never)."""
    stream = np.asarray(stream)
    if stream.ndim != 2:
        raise ValueError("stream must be 2-D [T, in_dim]")
    has = stream.any(axis=0)
    first = np.argmax(stream != 0, axis=0).astype(np.int64)  # first t with a spike
    return np.where(has, first, NO_SPIKE).astype(np.int64)
