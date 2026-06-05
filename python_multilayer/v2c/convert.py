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
