#!/usr/bin/env python3
"""Phase-1 smoke for H1 full-set schedule ablation."""

from __future__ import annotations

import csv
import os
from pathlib import Path

import h1_schedule_ablation as ablation


OUT_DIR = (Path(os.environ.get("SOC_DESIGN", Path(__file__).resolve().parent.parent.parent / "SoC Design")) / "essay" / "exp_h1_schedule_ablation").resolve()
CONFIG_ID = ablation.CONFIG_FASHION14
BASELINE = "baseline"
SCHED_A = "thresh_ramp_descending"
SCHED_B = "reset_mixed_soft_early"
HEADLINE = 82.38
HEADLINE_TOLERANCE_PCT = 0.01
SUMMARY_TOLERANCE_PCT = 1e-6


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


def _committed_summary_map(summary_csv: Path) -> dict[str, float]:
    with summary_csv.open("r", encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    return {
        row["schedule_name"]: float(row["accuracy_pct"])
        for row in rows
        if row["schedule_name"] in {BASELINE, SCHED_A, SCHED_B}
    }


def _backup_raw_csvs() -> dict[str, str]:
    backups: dict[str, str] = {}
    for schedule_name in (BASELINE, SCHED_A, SCHED_B):
        raw_csv = ablation._raw_csv_path(CONFIG_ID, schedule_name)
        if raw_csv.exists():
            backups[schedule_name] = raw_csv.read_text(encoding="utf-8")
            raw_csv.unlink()
    return backups


def _restore_raw_csvs(backups: dict[str, str]) -> None:
    for schedule_name, payload in backups.items():
        raw_csv = ablation._raw_csv_path(CONFIG_ID, schedule_name)
        raw_csv.write_text(payload, encoding="utf-8")


def main() -> int:
    summary_csv = OUT_DIR / f"summary_{CONFIG_ID}.csv"
    summary_backup = summary_csv.read_text(encoding="utf-8") if summary_csv.exists() else None
    committed_rows = _committed_summary_map(summary_csv) if summary_csv.exists() else {}
    raw_backups = _backup_raw_csvs()
    try:
        for schedule_name in (BASELINE, SCHED_A, SCHED_B):
            ablation.run_schedule(config_id=CONFIG_ID, schedule_name=schedule_name, out_dir=OUT_DIR)
    finally:
        if summary_backup is not None:
            summary_csv.write_text(summary_backup, encoding="utf-8")
        _restore_raw_csvs(raw_backups)

    rows = _summary_map()
    baseline = float(rows[BASELINE]["accuracy_pct"])
    sched_a = float(rows[SCHED_A]["accuracy_pct"])
    sched_b = float(rows[SCHED_B]["accuracy_pct"])
    baseline_delta = baseline - HEADLINE
    changed = (abs(sched_a - baseline) > 1e-9) or (abs(sched_b - baseline) > 1e-9)
    summary_ok = True
    failures: list[str] = []

    if abs(baseline_delta) > HEADLINE_TOLERANCE_PCT:
        failures.append(
            f"baseline drift {baseline_delta:+.4f}% exceeds tolerance ±{HEADLINE_TOLERANCE_PCT:.2f}%"
        )
    if not changed:
        failures.append("Schedule A/B both collapsed to baseline")
    for schedule_name, expected in committed_rows.items():
        actual = float(rows[schedule_name]["accuracy_pct"])
        if abs(actual - expected) > SUMMARY_TOLERANCE_PCT:
            summary_ok = False
            failures.append(
                f"summary CSV mismatch for {schedule_name}: committed {expected:.4f}% vs recomputed {actual:.4f}%"
            )

    print(f"Config #2 baseline accuracy: {baseline:.4f}% (headline {HEADLINE:.2f}%, delta {baseline_delta:+.4f}%)")
    print(f"Schedule A accuracy: {sched_a:.4f}%")
    print(f"Schedule B accuracy: {sched_b:.4f}%")
    print(f"Schedule A/B different than baseline: {'yes' if changed else 'no'}")
    print(f"Summary CSV matches recomputed rows: {'yes' if summary_ok else 'no'}")
    if failures:
        for failure in failures:
            print(f"[FAIL] {failure}")
        print("H1_SMOKE_FULL_SET_FAIL")
        return 1
    print("H1_SMOKE_FULL_SET_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
