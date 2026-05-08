#!/usr/bin/env python3
"""
audit-v2/python_multilayer/m2_envelope_plot.py — plot 4-dim envelope.

Per essay/m2_design_2026_05_07.md round-2-NIT-inline §3.2 + §5.4.

Reads 4 CSVs (one per dim) from `essay/exp_m2_envelope/` and emits
one 2x2 grid figure per config (PDF + PNG):

  +-----------+-----------+
  |  drift α  |  read σ   |
  +-----------+-----------+
  |  D2D σ    |  ADC σ    |
  +-----------+-----------+

Each subplot shows 3 envelope lines (best/median/worst seed) at each
sweep point. Median curve must pass through paper headline at the
anchor point ±0.5%.

Per Codex round-2-NIT-inline M2-Q5, also auto-detects N→10 escalation
triggers and prints
  M2_ESCALATE_TO_N10 config=<id> dim=<...> reason=<anchor-spread / line-crossing>
to stdout when:
  - (acc_max - acc_min) at anchor > 1.0% (anchor-spread instability)
  - best/median/worst ordering inverts at any sweep point (line-crossing)

Per §5.4 paper integration: each subplot caption includes the
"single-axis sweeps; joint robustness not characterized" reminder
directly under the figure (Codex round-1 NIT M2-Q7).

Usage:
  python3 m2_envelope_plot.py --config-id v2b_lenet5_mnist_28x28
  python3 m2_envelope_plot.py --config-id v1_fc_8x8_mnist
"""

from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path


def _read_csv(csv_path: Path):
    """Return dict[sweep_value] -> list of (seed, accuracy)."""
    rows = defaultdict(list)
    with csv_path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            sv = float(row["sweep_value"])
            seed = int(row["seed"])
            acc = float(row["accuracy"])
            rows[sv].append((seed, acc))
    return rows


def _envelope(rows):
    """Return (sweep_values, mins, medians, maxs, escalate_reasons)."""
    svs = sorted(rows.keys())
    mins, meds, maxs = [], [], []
    reasons = []
    for sv in svs:
        accs = sorted(a for _, a in rows[sv])
        n = len(accs)
        if n == 0:
            continue
        mn, mx = accs[0], accs[-1]
        if n % 2:
            md = accs[n // 2]
        else:
            md = (accs[n // 2 - 1] + accs[n // 2]) / 2
        mins.append(mn)
        meds.append(md)
        maxs.append(mx)
        # Anchor instability: spread > 1.0%
        if abs(sv) < 1e-9 and (mx - mn) > 1.0:
            reasons.append(("anchor-spread", sv, mx - mn))
    # Line-crossing instability: any sweep point where ordering inverts
    if mins and maxs:
        for i in range(len(svs)):
            if mins[i] > maxs[i]:
                reasons.append(("line-crossing", svs[i], maxs[i] - mins[i]))
    return svs, mins, meds, maxs, reasons


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-id", required=True,
                        help="e.g. v1_fc_8x8_mnist or v2b_lenet5_mnist_28x28")
    parser.add_argument("--in-dir", default="../../SoC Design/essay/exp_m2_envelope")
    parser.add_argument("--out-dir", default="../../SoC Design/essay/exp_m2_envelope")
    args = parser.parse_args()

    in_dir = Path(args.in_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    dims = ["drift", "read", "d2d", "adc"]
    csvs = {}
    for d in dims:
        p = in_dir / f"m2_envelope_{args.config_id}_{d}.csv"
        if not p.exists():
            print(f"[FAIL] missing CSV: {p}")
            return 1
        csvs[d] = _read_csv(p)

    # Lazy import matplotlib (allow CSV inspection without plotting deps)
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[warn] matplotlib not installed; skipping plots")
        plt = None

    if plt:
        fig, axes = plt.subplots(2, 2, figsize=(11, 8))
        for ax, dim in zip(axes.flat, dims):
            svs, mins, meds, maxs, reasons = _envelope(csvs[dim])
            ax.fill_between(svs, mins, maxs, alpha=0.3, label="best–worst envelope")
            ax.plot(svs, meds, "o-", linewidth=2, label="median")
            ax.plot(svs, mins, "v--", linewidth=1, alpha=0.7, label="worst")
            ax.plot(svs, maxs, "^--", linewidth=1, alpha=0.7, label="best")
            ax.set_title({
                "drift": "drift surrogate (α)",
                "read":  "read noise σ (LSB)",
                "d2d":   "D2D variation σ (log)",
                "adc":   "ADC offset σ (LSB)",
            }[dim])
            ax.set_xlabel("sweep value")
            ax.set_ylabel("accuracy (%)")
            ax.grid(alpha=0.3)
            if dim == "drift":
                ax.legend(loc="lower center", fontsize=8)
            for reason, sv, val in reasons:
                print(f"M2_ESCALATE_TO_N10 config={args.config_id} dim={dim} "
                      f"reason={reason} sweep_value={sv} delta={val:.3f}")

        # Per Codex round-1 NIT M2-Q7: caption directly under figure
        fig.suptitle(
            f"M2 single-axis nonideality envelope — {args.config_id}\n"
            f"(joint robustness is NOT characterized; per-dim sweeps only)",
            fontsize=11,
        )
        plt.tight_layout(rect=(0, 0, 1, 0.95))

        pdf = out_dir / f"m2_envelope_{args.config_id}.pdf"
        png = out_dir / f"m2_envelope_{args.config_id}.png"
        fig.savefig(str(pdf))
        fig.savefig(str(png), dpi=150)
        print(f"[ok] wrote {pdf}")
        print(f"[ok] wrote {png}")

    print(f"M2_ENVELOPE_PLOT_DONE config={args.config_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
