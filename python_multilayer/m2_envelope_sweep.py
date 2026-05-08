#!/usr/bin/env python3
"""
audit-v2/python_multilayer/m2_envelope_sweep.py — M2 4-dim sweep driver.

Per essay/m2_design_2026_05_07.md round-2-NIT-inline §3 + §5.2.

CLI:
  --config-id <#1 / #4>     V1 8x8 MNIST or V2.B LeNet-5 MNIST 28x28
  --dim <drift / read / d2d / adc>
  --n-seed N                default 5; round-2-NIT-inline M2-Q5
                            escalation triggers N=10 reruns externally
  --out-dir <path>          default essay/exp_m2_envelope/

Outputs `m2_envelope_<config>_<dim>.csv` with columns:
  dim, sweep_value, seed, accuracy, sample_indices_md5, baseline_output_md5

Per Codex round-2-NIT-inline M2-R2-N1: at the start of EACH non-anchor
sweep iteration, sets `snn_engine_multilayer.M2_NONIDEALITY_OFF = False`
and prints
  M2_NONIDEALITY_OFF=False (sweep_point=<v>, dim=<d>, seed=<s>)
to stdout. The anchor row keeps the flag True and prints
  M2_NONIDEALITY_OFF=True (anchor)
so post-hoc CSV inspection can prove anchor rows were truly
unperturbed and sweep rows were truly perturbed. Without this
discipline, a missed flag-toggle would silently produce flat
all-anchor CSVs and the envelope would falsely look "robust".

Sweep ranges per design doc §2.2-§2.5:
  drift  α ∈ {-0.10, -0.05, -0.02, 0.0, 0.02, 0.05, 0.10}
  read   σ ∈ {0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0}  (LSB)
  d2d    σ ∈ {0.0, 0.05, 0.10, 0.15, 0.20, 0.30, 0.50}
  adc    σ ∈ {0.0, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0}  (LSB)

Anchor (sweep_value == 0.0) MUST coincide with paper headline
accuracy ±0.5% (m2_anchor_check enforces this).

NOTE: this driver is a scaffold. The per-config inference call
(loading model.pt + iterating 100-sample test set) needs to be
wired to the existing per-config drivers in this directory
(`run_baseline_64to10.py` for #1; a CONV equivalent for #4). The
Codex close-out autonomous run has full edit authority to wire
those calls.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import snn_engine_multilayer as eng
import m2_real_inference as real_inf


SWEEP_RANGES = {
    "drift": [-0.10, -0.05, -0.02, 0.0, 0.02, 0.05, 0.10],
    "read":  [0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0],
    "d2d":   [0.0, 0.05, 0.10, 0.15, 0.20, 0.30, 0.50],
    "adc":   [0.0, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0],
}

CONFIG_LABELS = {"1": real_inf.CONFIG_V1, "4": real_inf.CONFIG_LENET5}


def run_inference_anchor(config_id: str) -> tuple:
    """Run one anchor inference (M2_NONIDEALITY_OFF=True, all knobs 0).

    Returns: (accuracy_pct, correct_count, total_count,
              sample_indices_md5, baseline_output_md5).
    """
    eng.m2_reset()
    print(f"M2_NONIDEALITY_OFF=True (anchor) config_id={config_id}")
    result = real_inf.run_anchor(config_id)
    return (result.accuracy_pct, result.correct_count, result.total_count,
            result.sample_indices_md5, result.baseline_output_md5)


def run_inference_perturbed(config_id: str, dim: str,
                            sweep_value: float, seed: int) -> tuple:
    """Run one perturbed inference.

    Returns: (accuracy_pct, correct_count, total_count,
              sample_indices_md5, baseline_output_md5).
    """
    knob_kwargs = {
        "drift": {"drift_alpha": sweep_value},
        "read":  {"sigma_read_lsb": sweep_value},
        "d2d":   {"sigma_d2d_lognormal": sweep_value},
        "adc":   {"sigma_adc_offset_lsb": sweep_value},
    }[dim]
    eng.m2_set_state(
        config_id=config_id, sweep_dim=dim, sweep_value=sweep_value,
        seed_base=seed, **knob_kwargs,
    )
    print(
        f"M2_NONIDEALITY_OFF=False (sweep_point={sweep_value}, "
        f"dim={dim}, seed={seed}) config_id={config_id}"
    )
    result = real_inf.run_perturbed(config_id, dim, sweep_value, seed)
    anchor = real_inf.run_anchor(config_id)
    eng.m2_reset()
    return (result.accuracy_pct, result.correct_count, result.total_count,
            anchor.sample_indices_md5, anchor.baseline_output_md5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-id", required=True,
                        choices=list(CONFIG_LABELS.values()) + list(CONFIG_LABELS.keys()))
    parser.add_argument("--dim", required=True, choices=list(SWEEP_RANGES.keys()))
    parser.add_argument("--n-seed", type=int, default=5)
    parser.add_argument("--out-dir", default="../../SoC Design/essay/exp_m2_envelope")
    args = parser.parse_args()

    # Allow user to pass "1" or "4" as shorthand
    config_id = CONFIG_LABELS.get(args.config_id, args.config_id)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_csv = out_dir / f"m2_envelope_{config_id}_{args.dim}.csv"

    rows = []
    for sweep_value in SWEEP_RANGES[args.dim]:
        for seed in range(args.n_seed):
            # Keep every anchor-point row truly unperturbed so the 7xN CSV
            # shape stays regular without silently mixing anchor and sweep
            # semantics at sweep_value=0.
            if sweep_value == 0.0:
                acc, correct, total, idx_md5, base_md5 = run_inference_anchor(config_id)
            else:
                acc, correct, total, idx_md5, base_md5 = run_inference_perturbed(
                    config_id, args.dim, sweep_value, seed
                )
            # Column order (per user 2026-05-08 Q4 SCI replot requirement):
            #   - correct_count + total_count immediately after seed so a
            #     re-plotter can recompute accuracy / Wilson CI / cumulative
            #     metrics without parsing the float `accuracy` field.
            rows.append({
                "dim": args.dim,
                "sweep_value": sweep_value,
                "seed": seed,
                "correct_count": correct,
                "total_count": total,
                "accuracy": acc,
                "sample_indices_md5": idx_md5,
                "baseline_output_md5": base_md5,
            })

    with out_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"\n[ok] wrote {len(rows)} rows -> {out_csv}")
    print(f"M2_ENVELOPE_SWEEP_DONE config={config_id} dim={args.dim} n_seed={args.n_seed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
