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
                     read_bits=128, fired_hidden_by_exit=None, row_stream_cyc=1,
                     phase_overhead=0, exit_overhead=0):
    """PROJECTED RTL cycle estimate (PARAMETERIZED — the hw costs are RTL-pinned, not fabricated here).

    The datapath is HETEROGENEOUS (the ramp input is dense, the hidden→output side is sparse):
      INPUT layer  (784→hid, dense multi-bit bit-serial) : ``in_bits`` phases × ``in_stripes`` column
        stripes × (``in_dim`` row-stream × ``row_stream_cyc`` + ``phase_overhead``). The ramp accumulate
        folds into the phase as a per-output register add (no extra array pass). DENSE → no row sparsity.
      OUTPUT layer (hid→out, event-driven row-serial)    : each hidden neuron that has FIRED by ``t_exit``
        is streamed ONCE into the hidden→output MAC, across ``out_stripes`` output column stripes. The
        cycle count therefore scales with the number of ACTIVE (fired) hidden rows, NOT with the
        algorithmic timestep ``t_exit``. If ``fired_hidden_by_exit`` is not supplied we fall back to the
        conservative worst case (all ``hid_dim`` rows).

    ★ Column stripes use the FIXED read width ``read_bits`` (plan-v1.md:33 ``P_READ_BITS=128`` →
    ``outputs_per_stripe = read_bits // W``; W=4 → 32 out/stripe → hidden 246=8 stripes, output 10=1).
    ★ ALGORITHMIC ``t_exit`` (first-output-spike timestep) is reported SEPARATELY as
    ``algorithmic_t_exit`` and is NOT conflated into the projected cycle count.
    ``row_stream_cyc`` / ``phase_overhead`` / ``exit_overhead`` are HARDWARE TBD (set from RTL/DC)."""
    te = T if t_exit is None else t_exit
    in_stripes = int(np.ceil(hid_dim * W / read_bits))
    input_cyc = in_bits * in_stripes * (in_dim * row_stream_cyc + phase_overhead)
    out_stripes = int(np.ceil(out_dim * W / read_bits))
    active_rows = hid_dim if fired_hidden_by_exit is None else int(fired_hidden_by_exit)
    output_cyc = active_rows * out_stripes * row_stream_cyc + exit_overhead * int(te)
    total = input_cyc + output_cyc
    return {
        "in_stripes": in_stripes, "out_stripes": out_stripes,
        "input_cycles": input_cyc, "output_cycles": output_cyc, "active_hidden_rows": active_rows,
        "projected_total_cycles": total, "algorithmic_t_exit": te,
        "note": "PROJECTION — read_bits=128 (plan P_READ_BITS); output cycles scale with ACTIVE hidden "
                "rows (event-driven), kept separate from algorithmic t_exit; row_stream_cyc/overheads RTL-TBD. "
                "input_cycles here = DENSE baseline; skip-zero projection (event口径) -> input_skip_cycles().",
    }


def input_skip_cycles(images, in_dim=784, hid_dim=246, W=4, in_bits=4, read_bits=128, n_eval=None):
    """★ INPUT-layer cycle distribution under the 3 PINNED event-count conventions (Codex P0 — keep
    spec / RTL counters / cost.py / paper on ONE口径). Per-image best+honest (best/mean/p95/worst).

    Pinned names (input zero-skip only depends on the IMAGE, not weights):
      dense       = in_bits × in_stripes × in_dim                 (baseline, no skip)
      row_event   = count(vq != 0)   — # nonzero pixels (a row with any set bit)
      bit_event   = Σ popcount(vq)   — # set input bits          (= §K0b cycle model, 首版最稳)
      value_event = row_event        — one nonzero pixel read ONCE, its in_bits fused in-lane (DC A/B 候选)
    skip cycle = in_stripes × event_count.  value_event ≈ ½ bit_event (nnz < Σpopcount), bit-exact.
    `in_stripes = ceil(hid_dim·W / read_bits)`."""
    images = np.asarray(images)
    n = len(images) if n_eval is None else min(int(n_eval), len(images))
    levels = (1 << in_bits) - 1
    vq = np.rint(images[:n].astype(np.float64) / 255.0 * levels).astype(np.int64)        # [n,in]
    in_stripes = int(np.ceil(hid_dim * W / read_bits))
    set_bits = np.unpackbits(vq.astype(np.uint8)[..., None], axis=-1).sum(axis=(1, 2))   # [n] Σpopcount
    nnz = (vq > 0).sum(axis=1)                                                            # [n] nonzero pixels

    def _stats(x):
        x = np.asarray(x)
        return {"best": int(x.min()), "mean": float(x.mean()),
                "p95": float(np.percentile(x, 95)), "worst": int(x.max())}

    return {
        "in_stripes": in_stripes,
        "dense": in_bits * in_stripes * in_dim,                       # baseline (no skip)
        "bit_event_cycles": _stats(in_stripes * set_bits),           # 首版 (= §K0b)
        "value_event_cycles": _stats(in_stripes * nnz),              # DC A/B candidate (~2× fewer)
        "row_event_count": _stats(nnz), "bit_event_count": _stats(set_bits),
    }
