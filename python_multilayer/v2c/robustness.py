"""V2C Phase 3: non-ideal robustness of the digital binary CIM (the project's SOTA-able axis).

The V2C cells are BINARY and read by a 1-bit digital sense amp (no ADC). Device non-idealities are
therefore digital bit errors on the packed cells — not the analog conductance variation / ADC-
quantization that costs analog CIM 10-50%+ accuracy (and which a digital binary array is immune to
by construction). This module injects those digital faults and sweeps accuracy vs fault rate, so we
can draw the "digital binary stays flat where analog collapses" curve (no such head-to-head curve is
published — see V2C_Codex审查_Phase2 research notes).

Fault models (on the packed binary cells ``[in, out*W]`` from ``encoding.pack``):
  * ``stuck0`` / ``stuck1`` — a fraction of cells permanently 0 / 1 (stuck-at faults, write-fail).
  * ``flip``               — a fraction of cells read inverted (read bit-flip; the read-BER from the
                             on/off ratio + sense-margin noise maps to this rate).

The deployed accuracy metric here is FULL-FRAME (argmax of the final output membrane) — it is output-
threshold-independent, so it isolates how faults corrode the discrimination itself. Pure numpy (the
golden path); no GPU.
"""
from __future__ import annotations

import numpy as np

try:  # package import
    from . import convert as C
except ImportError:  # direct-module import (v2c on sys.path) — tests / venv
    import convert as C

FAULT_MODES = ("stuck0", "stuck1", "flip")


def inject_cell_faults(cells: np.ndarray, rate: float, mode: str, rng: np.random.Generator) -> np.ndarray:
    """Return a faulted COPY of packed binary ``cells``: each cell independently faulted w.p. ``rate``.
    ``stuck0``->0, ``stuck1``->1, ``flip``->1-cell (read inversion). ``rate<=0`` returns a clean copy."""
    cells = np.asarray(cells)
    out = cells.copy()
    if rate <= 0:
        return out
    if mode not in FAULT_MODES:
        raise ValueError(f"unknown fault mode {mode!r}; use one of {FAULT_MODES}")
    mask = rng.random(cells.shape) < rate
    if mode == "stuck0":
        out[mask] = 0
    elif mode == "stuck1":
        out[mask] = 1
    else:  # flip
        out[mask] = 1 - out[mask]
    return out


def _inject_layers(layers, rate, mode, rng):
    """Apply :func:`inject_cell_faults` to the ``cells`` of every exported layer (W/out/threshold kept)."""
    return [(inject_cell_faults(cells, rate, mode, rng), W, out_dim, thr)
            for (cells, W, out_dim, thr) in layers]


def faulted_full_frame_acc(layers, images, labels, T, in_bits, rate, mode, n_eval, rng):
    """Full-frame (argmax final membrane) accuracy of the ramp golden forward with ``rate`` cell faults
    of ``mode`` injected into ``layers`` (a fresh i.i.d. fault pattern from ``rng``)."""
    faulted = _inject_layers(layers, rate, mode, rng)
    traj, n = C.ramp_output_trajectories(None, images, T, in_bits=in_bits, n_eval=n_eval, layers=faulted)
    preds = traj[:, -1, :].argmax(axis=1)
    return float((preds == np.asarray(labels)[:n]).mean())


def robustness_sweep(model, images, labels, T, in_bits=4, mode="flip",
                     rates=(0.0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2), n_eval=2000, trials=5, seed=0):
    """Accuracy-vs-fault-rate sweep for one fault ``mode`` on ``model``'s exported cells. Each rate is
    averaged over ``trials`` independent fault patterns. Returns ``{rate: (mean_acc, std_acc)}``."""
    rng = np.random.default_rng(seed)
    layers, _ = C.export_v2c_layers(model)
    out = {}
    for r in rates:
        accs = [faulted_full_frame_acc(layers, images, labels, T, in_bits, r, mode, n_eval, rng)
                for _ in range(trials)]
        out[float(r)] = (float(np.mean(accs)), float(np.std(accs)))
    return out
