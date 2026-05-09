#!/usr/bin/env python3
"""Phase-1 smoke for H1 full-set schedule ablation."""

from __future__ import annotations

import csv
from pathlib import Path

import h1_schedule_ablation as ablation


OUT_DIR = (Path(__file__).resolve().parent.parent.parent / "SoC Design" / "essay" / "exp_h1_schedule_ablation").resolve()
CONFIG_ID = ablation.CONFIG_FASHION14
BASELINE = "baseline"
SCHED_A = "thresh_ramp_descending"
SCHED_B = "reset_mixed_soft_early"
HEADLINE = 82.38


def _summary_map() -> dict[str, dict[str, object]]:
    rows: dict[str, dict[str, object]] = {}
    for schedule_name in (BASELINE, SCHED_A, SCHED_B):
        raw_csv = ablation._raw_csv_path(CONFIG_ID, schedule_name)
        with raw_csv.open("r", encoding="utf-8", newline="") as f:
            reader = list(csv.DictReader(f))
        correct = sum(int(row["correct"]) for row in reader)
        total = len(reader)
        rows[schedule_name] = {
            "schedule_name": schedule_name,
            "accuracy_pct": f"{100.0 * correct / total:.4f}",
        }
    return rows


def main() -> int:
    summary_csv = OUT_DIR / f"summary_{CONFIG_ID}.csv"
    summary_backup = summary_csv.read_text(encoding="utf-8") if summary_csv.exists() else None
    for schedule_name in (BASELINE, SCHED_A, SCHED_B):
        ablation.run_schedule(config_id=CONFIG_ID, schedule_name=schedule_name, out_dir=OUT_DIR)

    if summary_backup is not None:
        summary_csv.write_text(summary_backup, encoding="utf-8")

    rows = _summary_map()
    baseline = float(rows[BASELINE]["accuracy_pct"])
    sched_a = float(rows[SCHED_A]["accuracy_pct"])
    sched_b = float(rows[SCHED_B]["accuracy_pct"])
    baseline_delta = baseline - HEADLINE
    changed = (abs(sched_a - baseline) > 1e-9) or (abs(sched_b - baseline) > 1e-9)

    print(f"Config #2 baseline accuracy: {baseline:.4f}% (headline {HEADLINE:.2f}%, delta {baseline_delta:+.4f}%)")
    print(f"Schedule A accuracy: {sched_a:.4f}%")
    print(f"Schedule B accuracy: {sched_b:.4f}%")
    print(f"Schedule A/B different than baseline: {'yes' if changed else 'no'}")
    print("H1_SMOKE_FULL_SET_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
