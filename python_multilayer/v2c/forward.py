"""
V2C single-layer TTFS-IF forward (digital-CIM golden).

One FC layer: consume a TTFS input spike stream ``[T, in_dim]``; each timestep, run the
digital-CIM MAC (``encoding.mac`` over the active/spiking rows) and integrate the membrane;
emit each output neuron's FIRST-spike time (single-spike TTFS — a neuron that crosses
threshold fires once and its time is latched, no reset needed within the frame).

Classification: earliest output spike wins (+ first-spike early-exit); ties -> highest
membrane -> lowest class index; if no output fires, fall back to argmax membrane.
(plan-v1.md TTFS 语义 / 累积微架构 / 决策记录 §7.)

Pure numpy. Hidden-layer chaining (this layer's spike_times -> next layer's input stream)
is done by ``ttfs.ttfs_times_to_stream`` in the multilayer driver (later part).
"""
import numpy as np

try:  # package import (python_multilayer.v2c.forward)
    from . import encoding as enc
    from . import ttfs
except ImportError:  # direct-module import (v2c dir on sys.path) — tests / wheel-bypass env
    import encoding as enc
    import ttfs


def ttfs_layer_forward(spike_stream, cells, W, out_dim, threshold, early_exit=False):
    """Run one TTFS-IF FC layer.

    spike_stream : ``[T, in_dim]`` binary (<=1 spike per input neuron).
    cells        : packed weights ``[in_dim, out_dim*W]`` (``encoding.pack``).
    threshold    : int; output fires when ``membrane >= threshold``.
    early_exit   : if True, stop after the first timestep at which any output fires
                   (classification: the earliest spike already decides the winner).
    returns      : ``(spike_times[out_dim] int64 (NO_SPIKE if never), membrane[out_dim] int64,
                   n_steps_run)``.
    """
    stream = np.asarray(spike_stream)
    if stream.ndim != 2:
        raise ValueError("spike_stream must be 2-D [T, in_dim]")
    if out_dim < 1:
        raise ValueError("out_dim must be >= 1")
    if not np.all((stream == 0) | (stream == 1)):
        raise ValueError("spike_stream must be binary {0,1}")
    if np.any(stream.sum(axis=0) > 1):
        raise ValueError("TTFS: each input neuron may spike at most once per frame")
    T = stream.shape[0]
    if T < 1:
        raise ValueError("T (spike_stream.shape[0]) must be >= 1")
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_times = np.full(out_dim, ttfs.NO_SPIKE, dtype=np.int64)
    n_steps = 0
    for t in range(T):
        membrane += enc.mac(stream[t], cells, W, out_dim)          # digital-CIM partial sum
        newly = (spike_times == ttfs.NO_SPIKE) & (membrane >= threshold)
        spike_times[newly] = t                                     # latch first-spike time
        n_steps = t + 1
        if early_exit and np.any(spike_times != ttfs.NO_SPIKE):
            break
    return spike_times, membrane, n_steps


def ttfs_classify(spike_times, membrane):
    """Decode an output layer -> ``(pred_class, fallback_used)``.

    Earliest output spike wins; ties (same earliest time) -> highest membrane -> lowest
    class index; if no output fired -> fallback to argmax membrane (fallback_used=True).

    Call on an ``early_exit=True`` forward result: for the tie-break, ``membrane`` must be the
    membrane at the earliest-spike timestep (exactly what early-exit returns — all tied neurons
    crossed threshold at that same step, so it is well-defined). The *final* membrane (from a
    full run) is only meaningful for the no-spike fallback, NOT for the tie-break.
    """
    spike_times = np.asarray(spike_times)
    membrane = np.asarray(membrane)
    if spike_times.ndim != 1 or membrane.ndim != 1:
        raise ValueError("spike_times and membrane must be 1-D")
    if spike_times.shape[0] != membrane.shape[0] or spike_times.shape[0] == 0:
        raise ValueError("spike_times and membrane must be the same nonzero length")
    if np.any(spike_times < ttfs.NO_SPIKE):
        raise ValueError(f"invalid spike time < {ttfs.NO_SPIKE} (only {ttfs.NO_SPIKE}=NO_SPIKE)")
    fired = spike_times != ttfs.NO_SPIKE
    if np.any(fired):
        earliest = spike_times[fired].min()
        cand = np.nonzero(fired & (spike_times == earliest))[0]    # ascending index
        best = cand[int(np.argmax(membrane[cand]))]                # max membrane; ties -> lowest idx
        return int(best), False
    return int(np.argmax(membrane)), True                          # fallback: max final membrane


def multilayer_ttfs_forward(input_stream, layers, T):
    """Chain TTFS-IF FC layers (the V2C MLP golden).

    Hidden layers run full (no early-exit) and feed their first-spike times, re-encoded as a TTFS
    stream (``ttfs.ttfs_times_to_stream``), into the next layer. The output (last) layer runs with
    first-spike **early-exit**, and classification uses that early-exit (first-spike) membrane — the
    TTFS tie-break basis — NEVER a full-run final membrane (which could pick a different class).

    input_stream : ``[T, in_dim]`` binary TTFS stream (``shape[0]`` must equal ``T``).
    layers       : list of ``(cells, W, out_dim, threshold)`` (in order; each ``out_dim`` must equal
                   the next layer's input dim).
    returns dict : ``pred``, ``fallback_used``, ``out_spike_times``, ``out_membrane``,
                   ``per_layer_spike_times`` (list), ``n_steps_per_layer`` (list).
    """
    if len(layers) == 0:
        raise ValueError("layers must be non-empty")
    if T < 1:
        raise ValueError("T must be >= 1")
    stream = np.asarray(input_stream)
    if stream.ndim != 2 or stream.shape[0] != T:
        raise ValueError(f"input_stream.shape[0] must equal T={T}; got shape {stream.shape}")
    per_layer_times, per_layer_steps = [], []
    last = len(layers) - 1
    st = mem = None
    for i, (cells, W, out_dim, threshold) in enumerate(layers):
        st, mem, steps = ttfs_layer_forward(stream, cells, W, out_dim, threshold,
                                            early_exit=(i == last))   # output layer early-exits
        per_layer_times.append(st)
        per_layer_steps.append(steps)
        if i != last:
            stream = ttfs.ttfs_times_to_stream(st, T)                 # hidden -> next-layer TTFS input
    pred, fallback = ttfs_classify(st, mem)   # st,mem = output layer's early-exit (first-spike) state
    return {
        "pred": pred,
        "fallback_used": fallback,
        "out_spike_times": st,
        "out_membrane": mem,
        "per_layer_spike_times": per_layer_times,
        "n_steps_per_layer": per_layer_steps,
    }
