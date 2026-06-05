"""
V2C export + inference bridge: take a trained surrogate-gradient spiking MLP
(``spiking.V2CSpikingMLP``), export its integer weights and learned integer per-output thresholds,
and run the real digital-CIM TTFS golden forward (``forward.multilayer_ttfs_forward``) to measure
the deployed accuracy.

Pipeline:  spiking model --export--> (cells = encoding.pack(w_int),  threshold = round(θ/scale))
           images       --ttfs encode--> spike stream --> forward.multilayer_ttfs_forward --> pred

The per-output threshold is a single integer register per neuron (no inference-time BN / multiply —
PPA-clean). Because the spiking model was trained *in* this dynamic with threshold-QAT, the golden
accuracy here should match the training accuracy (the train/inference consistency check); any small
residual is the output early-exit / tie ordering, reported via ``fallback_rate``.

Metrics:
  * ``ttfs_acc``      — V2C TTFS classification accuracy (the deployed hardware number).
  * ``fallback_rate`` — fraction with no output spike (decided by membrane argmax fallback).
  * ``algo_latency``  — algorithmic first-output-spike time (fallback samples count as T). Hardware
                        cycle latency (active-rows/stripes/layer-order) is a later part.
"""
from __future__ import annotations

import numpy as np

try:  # package import
    from . import encoding as enc
    from . import ttfs
    from . import forward as fwd
except ImportError:  # direct-module import (v2c on sys.path) — tests / venv
    import encoding as enc
    import ttfs
    import forward as fwd


def export_v2c_layers(model):
    """``spiking.V2CSpikingMLP`` -> ``layers`` for ``forward.multilayer_ttfs_forward``.

    Each entry ``(cells, W, out_dim, threshold)``: ``cells`` = ``encoding.pack`` of the integer
    weights (transposed to ``[in,out]``), ``threshold`` = the layer's learned per-output **integer**
    threshold ``round(softplus(log_thr)/scale)``. Returns ``(layers, meta)`` with per-layer
    ``(W, out_dim)``.
    """
    int_thr = model.export_int_thresholds()                       # list of [out] int64 tensors
    layers, meta = [], []
    for layer, thr in zip(model.layers, int_thr):
        W, out_dim = layer.W, layer.out_features
        w_int = layer.export_int().cpu().numpy()                  # [out, in]
        cells = enc.pack(w_int.T, W)                              # pack wants [in, out]
        theta = thr.cpu().numpy().astype(np.int64)               # [out] per-output integer threshold
        layers.append((cells, W, out_dim, theta))
        meta.append((W, out_dim))
    return layers, meta


def images_to_streams(images: np.ndarray, T: int, max_val: int = 255):
    """``images`` uint8 ``[N,784]`` -> list of TTFS spike streams ``[T,784]`` (one per image)."""
    imgs = np.asarray(images)
    if imgs.ndim != 2:
        raise ValueError("images must be 2-D [N, in_dim]")
    streams = []
    for row in imgs:
        times = ttfs.encode_pixel_to_ttfs(row, T, max_val=max_val)
        streams.append(ttfs.ttfs_times_to_stream(times, T))
    return streams


def eval_ttfs(model, images: np.ndarray, labels: np.ndarray, T: int, n_eval=None):
    """Run the real V2C TTFS golden forward over (a subset of) a dataset; return accuracy + diag.

    Returns dict: ``ttfs_acc``, ``fallback_rate``, ``algo_latency_mean``, ``n`` (samples evaluated),
    plus ``preds`` / ``labels`` arrays. ``n_eval`` caps the count (TTFS forward is per-sample numpy).
    """
    images = np.asarray(images)
    labels = np.asarray(labels)
    n = len(images) if n_eval is None else min(int(n_eval), len(images))
    layers, _ = export_v2c_layers(model)
    streams = images_to_streams(images[:n], T)
    preds = np.empty(n, dtype=np.int64)
    fallback = np.zeros(n, dtype=bool)
    latency = np.empty(n, dtype=np.int64)
    for i, stream in enumerate(streams):
        res = fwd.multilayer_ttfs_forward(stream, layers, T)
        preds[i] = res["pred"]
        fallback[i] = res["fallback_used"]
        fired = res["out_spike_times"][res["out_spike_times"] != ttfs.NO_SPIKE]
        latency[i] = int(fired.min()) if fired.size else T            # fallback -> latency = T
    correct = preds == labels[:n]
    return {
        "ttfs_acc": float(correct.mean()),
        "fallback_rate": float(fallback.mean()),
        "algo_latency_mean": float(latency.mean()),
        "n": n,
        "preds": preds,
        "labels": labels[:n],
    }


def _ramp_quantize(images: np.ndarray, n: int, in_bits: int) -> np.ndarray:
    """Pixels uint8 ``[N,784]`` -> integer ``[n,in]`` in ``0..(2^in_bits-1)`` (the ramp input value)."""
    levels = (1 << in_bits) - 1
    return np.rint(images[:n].astype(np.float64) / 255.0 * levels).astype(np.int64)


def _ramp_hidden_times(v: np.ndarray, cells1, W1, hid, th1, T: int, in_bits: int) -> np.ndarray:
    """First (input) layer of the ramp path: bit-serial digital-CIM MAC ``z1 = Σ_k 2^k·mac(bitplane_k)``
    (== ``v @ w_int``; cells stay binary) + ramp TTFS hidden first-spike times (``membrane(t)=(t+1)·z1``,
    first ``t`` with ``(t+1)·z1 >= th1``, ``z1>0`` only). Returns ``hid_times[hid]`` (NO_SPIKE if never)."""
    z1 = np.zeros(hid, dtype=np.int64)
    for k in range(in_bits):
        z1 += (1 << k) * enc.mac(((v >> k) & 1).astype(np.uint8), cells1, W1, hid)
    hid_times = np.full(hid, ttfs.NO_SPIKE, dtype=np.int64)
    pos = z1 > 0
    tcross = np.ceil(np.where(pos, th1, 1) / np.where(pos, z1, 1)).astype(np.int64) - 1
    tcross = np.clip(tcross, 0, None)
    fires = pos & (tcross <= T - 1)
    hid_times[fires] = tcross[fires]
    return hid_times


def eval_ttfs_ramp(model, images: np.ndarray, labels: np.ndarray, T: int, in_bits: int = 4,
                   n_eval=None):
    """Golden eval for the multi-bit (bit-serial / ramp) INPUT path (Option A).

    First layer = bit-serial digital-CIM MAC: the ``in_bits``-bit pixel value is decomposed into bit
    planes and accumulated with 2^k shift-add — ``z1 = Σ_k 2^k · encoding.mac(bitplane_k, cells1)`` —
    which equals the integer ``v @ w_int`` (full grayscale MAC, cells still binary). The hidden TTFS
    neuron then ramps that constant: ``membrane(t)=(t+1)·z1``, first-spike when ``>= threshold``;
    hidden/output layers are the standard digital-CIM TTFS golden (``forward.py``). Bit-exact with the
    spiking model's hard-classify within the fp32-safe integer range (W<=4, in_bits<=4).

    Returns the same dict as :func:`eval_ttfs`. ``model`` must have >=2 layers (input + TTFS layers).
    """
    images = np.asarray(images)
    labels = np.asarray(labels)
    n = len(images) if n_eval is None else min(int(n_eval), len(images))
    layers, _ = export_v2c_layers(model)
    cells1, W1, hid, th1 = layers[0]                          # input layer (bit-serial MAC + ramp)
    th1 = np.asarray(th1, dtype=np.int64)
    vq = _ramp_quantize(images, n, in_bits)                   # [n,in] in 0..levels
    preds = np.empty(n, dtype=np.int64)
    fallback = np.zeros(n, dtype=bool)
    latency = np.empty(n, dtype=np.int64)
    for i in range(n):
        hid_times = _ramp_hidden_times(vq[i], cells1, W1, hid, th1, T, in_bits)
        st = hid_times                                        # hidden first-spike times
        stream2 = ttfs.ttfs_times_to_stream(st, T)            # hidden spikes -> output layer input
        cells2, W2, out_dim, th2 = layers[1]
        st, mem, _ = fwd.ttfs_layer_forward(stream2, cells2, W2, out_dim, th2, early_exit=True)
        # remaining layers (deeper nets): chain like multilayer_ttfs_forward
        for cells_l, W_l, od_l, th_l in layers[2:]:
            st, mem, _ = fwd.ttfs_layer_forward(ttfs.ttfs_times_to_stream(st, T), cells_l, W_l, od_l,
                                                th_l, early_exit=True)
        pred, fb = fwd.ttfs_classify(st, mem)
        preds[i] = pred
        fallback[i] = fb
        fired = st[st != ttfs.NO_SPIKE]
        latency[i] = int(fired.min()) if fired.size else T
    correct = preds == labels[:n]
    return {
        "ttfs_acc": float(correct.mean()),
        "fallback_rate": float(fallback.mean()),
        "algo_latency_mean": float(latency.mean()),
        "n": n,
        "preds": preds,
        "labels": labels[:n],
    }


def _layer_membrane_trajectory(stream, cells, W, out_dim, threshold):
    """One TTFS layer over the FULL frame (no early exit): returns ``(spike_times[out]`` (NO_SPIKE if
    never), ``membrane_traj[T,out])``. The decision policies below need the membrane at the chosen
    decision step (which early-exit discards), so we keep the whole trajectory."""
    stream = np.asarray(stream)
    T = stream.shape[0]
    membrane = np.zeros(out_dim, dtype=np.int64)
    spike_times = np.full(out_dim, ttfs.NO_SPIKE, dtype=np.int64)
    traj = np.empty((T, out_dim), dtype=np.int64)
    for t in range(T):
        membrane = membrane + enc.mac(stream[t], cells, W, out_dim)
        newly = (spike_times == ttfs.NO_SPIKE) & (membrane >= threshold)
        spike_times[newly] = t
        traj[t] = membrane
    return spike_times, traj


def _decide_guard(spike_times, traj, delta: int) -> int:
    """Guard-window decode: wait ``delta`` cycles after the first output spike, then among the neurons
    that have fired by ``t_first+delta`` pick the highest membrane at that step (ties -> lowest index);
    no spike -> argmax final membrane. ``delta=0`` is exactly strict early-exit (only the earliest-firing
    neurons compete, judged on the membrane at the first-spike step — the ``ttfs_classify`` basis)."""
    T = traj.shape[0]
    fired = spike_times != ttfs.NO_SPIKE
    if not np.any(fired):
        return int(np.argmax(traj[-1]))                       # fallback: final membrane
    t1 = int(spike_times[fired].min())
    td = min(t1 + delta, T - 1)
    elig = np.nonzero(fired & (spike_times <= td))[0]         # ascending index
    return int(elig[int(np.argmax(traj[td][elig]))])          # max membrane at td; ties -> lowest idx


def eval_ttfs_ramp_modes(model, images: np.ndarray, labels: np.ndarray, T: int, in_bits: int = 4,
                         deltas=(1, 2, 4), n_eval=None):
    """Ramp golden eval under several decision policies, for the latency-accuracy Pareto:
      * ``strict``     — first-spike early-exit (the deployed number; == :func:`eval_ttfs_ramp`).
      * ``guard[Δ]``   — wait Δ cycles after the first spike before deciding (curbs a wrong class that
                         happens to spike one cycle early; Δ=0 == strict).
      * ``full_frame`` — argmax of the final membrane, timing ignored (the accuracy ceiling, latency T).

    Hidden layers run the full frame and only the OUTPUT layer's decision varies (correct for deeper
    nets too, unlike :func:`eval_ttfs_ramp`'s early-exit chaining). Returns per-mode ``acc`` + mean
    decision ``latency`` (the cycle the class is committed; fallback counts as T)."""
    images = np.asarray(images)
    labels = np.asarray(labels)
    n = len(images) if n_eval is None else min(int(n_eval), len(images))
    layers, _ = export_v2c_layers(model)
    cells1, W1, hid, th1 = layers[0]
    th1 = np.asarray(th1, dtype=np.int64)
    vq = _ramp_quantize(images, n, in_bits)
    preds = {0: np.empty(n, np.int64), "full": np.empty(n, np.int64)}
    preds.update({d: np.empty(n, np.int64) for d in deltas})
    lat = {0: np.empty(n, np.int64), "full": np.full(n, T, np.int64)}
    lat.update({d: np.empty(n, np.int64) for d in deltas})
    for i in range(n):
        st = _ramp_hidden_times(vq[i], cells1, W1, hid, th1, T, in_bits)
        for cells_l, W_l, od_l, th_l in layers[1:-1]:         # middle hidden layers run full
            st, _, _ = fwd.ttfs_layer_forward(ttfs.ttfs_times_to_stream(st, T), cells_l, W_l, od_l,
                                              th_l, early_exit=False)
        cells_o, W_o, od_o, th_o = layers[-1]                 # output layer: full membrane trajectory
        out_st, traj = _layer_membrane_trajectory(ttfs.ttfs_times_to_stream(st, T), cells_o, W_o, od_o, th_o)
        fired = out_st != ttfs.NO_SPIKE
        t1 = int(out_st[fired].min()) if np.any(fired) else T
        for d in (0, *deltas):
            preds[d][i] = _decide_guard(out_st, traj, d)
            lat[d][i] = min(t1 + d, T - 1) if t1 < T else T
        preds["full"][i] = int(np.argmax(traj[-1]))
    y = labels[:n]
    out = {
        "n": n,
        "strict": {"acc": float((preds[0] == y).mean()), "latency": float(lat[0].mean())},
        "full_frame": {"acc": float((preds["full"] == y).mean()), "latency": float(T)},
        "guard": {d: {"acc": float((preds[d] == y).mean()), "latency": float(lat[d].mean())}
                  for d in deltas},
    }
    return out
