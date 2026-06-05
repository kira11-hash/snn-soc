"""V2C algorithmic cost model: SOP (synaptic operations) + a PROJECTED-cycle formula — the bridge to
RTL/PPA (Codex#3 pre-RTL#5). Freezes the counting so the RTL phase aligns and the energy/latency story
is quantified honestly.

★ Two latency numbers, kept separate (Codex#3):
  * ALGORITHMIC latency = the output first-spike timestep ``t_exit`` (0..T) — what the golden measures.
  * PROJECTED RTL latency (cycles) = a parameterized formula below; the per-op cycle costs / pipelining
    / stripe scheduling are HARDWARE parameters to be PINNED by the RTL (left as inputs, not fabricated).

★ SOP honesty: the hidden→output layers are single-spike TTFS (each neuron fires ≤1 → sparse SOP), but
the ramp INPUT layer is MULTI-BIT bit-serial (``in_bits`` binary phases) and is NOT single-spike, so the
input side dominates SOP. We report both; the "single-spike sparsity" energy claim applies to hidden/
output, not the input layer.

Weight-level SOP counts here (one input event × one weight); multiply by ``W`` for binary-cell-level ops
(each W-bit weight = W cells).
"""
from __future__ import annotations

import numpy as np


def input_sop(images: np.ndarray, hid_dim: int, in_bits: int = 4, n_eval=None):
    """Mean INPUT-layer SOP per inference (bit-serial multi-bit input). Each set bit of each pixel's
    ``in_bits`` representation is an event driving ``hid_dim`` synapses: SOP = mean(Σ_pixels popcount(xq))
    × hid_dim. Returns ``(mean_sop, mean_set_bits)``."""
    images = np.asarray(images)
    n = len(images) if n_eval is None else min(int(n_eval), len(images))
    levels = (1 << in_bits) - 1
    xq = np.rint(images[:n].astype(np.float64) / 255.0 * levels).astype(np.int64)   # [n,in] 0..levels
    set_bits = np.unpackbits(xq.astype(np.uint8)[..., None], axis=-1).sum(axis=(1, 2))  # per-sample set bits
    # (in_bits<=8 fits uint8; only the low in_bits matter since xq<=levels<2^in_bits)
    mean_bits = float(set_bits.mean())
    return mean_bits * hid_dim, mean_bits


def output_sop(hidden_fire_count: float, out_dim: int):
    """Mean hidden→output SOP per inference (single-spike TTFS): each fired hidden neuron drives
    ``out_dim`` synapses. ``hidden_fire_count`` = mean # hidden neurons that fire (from the golden)."""
    return hidden_fire_count * out_dim


def sop_summary(images, hidden_fire_count, in_dim=784, hid_dim=246, out_dim=10, in_bits=4, W=4, n_eval=None):
    """Full SOP breakdown per inference. Returns a dict (weight-level + ×W cell-level)."""
    in_sop, mean_bits = input_sop(images, hid_dim, in_bits, n_eval)
    out_sop = output_sop(hidden_fire_count, out_dim)
    total = in_sop + out_sop
    return {
        "mean_set_input_bits": mean_bits,
        "input_sop": in_sop, "output_sop": out_sop, "total_sop": total,
        "input_sop_cells": in_sop * W, "output_sop_cells": out_sop * W, "total_sop_cells": total * W,
        "hidden_fire_count": hidden_fire_count,
    }


def projected_cycles(in_dim=784, hid_dim=246, out_dim=10, W=4, in_bits=4, T=16, t_exit=None,
                     macro_cols=256, row_stream_cyc=1, phase_overhead=0, exit_overhead=0):
    """PROJECTED RTL cycle estimate (PARAMETERIZED — the hw costs are RTL-pinned, not fabricated here).

    Structure (one inference):
      input bit-serial MACs : ``in_bits`` phases × ``stripes`` × (``in_dim`` row-stream × ``row_stream_cyc`` + overhead)
                              where ``stripes = ceil(hid_dim·W / macro_cols)`` (column tiling of the macro)
      ramp accumulate       : folded into the input phase as a per-output register add (no extra array pass)
      hidden TTFS layer     : the hidden→output MAC is single-spike; output early-exits at ``t_exit``
      output decision       : ∝ ``t_exit`` (algorithmic timesteps committed)
    ``row_stream_cyc`` / ``phase_overhead`` / ``exit_overhead`` are HARDWARE TBD (set from RTL/DC).
    Returns a dict with the component cycle counts + total; treat as a projection until RTL pins the params."""
    stripes = int(np.ceil(hid_dim * W / macro_cols))
    input_cyc = in_bits * stripes * (in_dim * row_stream_cyc + phase_overhead)
    te = T if t_exit is None else t_exit
    # hidden/output single-spike layer: a small MAC over the fired-hidden spike train, decided at t_exit
    output_cyc = int(te) + exit_overhead
    total = input_cyc + output_cyc
    return {
        "stripes": stripes, "input_cycles": input_cyc, "output_cycles": output_cyc,
        "projected_total_cycles": total, "algorithmic_t_exit": te,
        "note": "PROJECTION — row_stream_cyc/overheads are RTL-TBD; algorithmic t_exit is separate.",
    }
