#!/usr/bin/env python3
"""Phase-1 smoke for H1 full-set schedule ablation."""

from __future__ import annotations

import csv
import os
from pathlib import Path

import h1_schedule_ablation as ablation
import h1_schedule_library as lib


OUT_DIR = (Path(os.environ.get("SOC_DESIGN", Path(__file__).resolve().parent.parent.parent / "SoC Design")) / "essay" / "exp_h1_schedule_ablation").resolve()
RAW_DATA_DIR = (
    Path(os.environ.get("SOC_DESIGN", Path(__file__).resolve().parent.parent.parent / "SoC Design"))
    / "essay"
    / "raw_data_for_replot"
    / "h1_schedule_ablation"
    / "sim_full_set"
).resolve()
CONFIG_ID = ablation.CONFIG_FASHION14
BASELINE = "baseline"
SCHED_A = "thresh_ramp_descending"
SCHED_B = "reset_mixed_soft_early"
HEADLINE = 82.38
HEADLINE_TOLERANCE_PCT = 0.01
SUMMARY_TOLERANCE_PCT = 1e-6
EXPECTED_TOTAL_COUNTS = {
    ablation.CONFIG_V1: 5000,
    ablation.CONFIG_FASHION14: 10000,
    ablation.CONFIG_MNIST14: 10000,
    ablation.CONFIG_LENET5_MNIST: 10000,
    ablation.CONFIG_FASHION28: 10000,
    ablation.CONFIG_LENET5_FASHION: 10000,
}
EXPECTED_POSITIVE_WINNERS = {
    ablation.CONFIG_FASHION14: ("reset_mixed_soft_early", 1.11),
    ablation.CONFIG_MNIST14: ("reset_mixed_soft_early", 0.43),
    ablation.CONFIG_FASHION28: ("reset_mixed_soft_early", 1.03),
}


def _raw_bundle_csv_path(raw_dir: Path, config_id: str, schedule_name: str) -> Path:
    return raw_dir / f"h1_schedule_ablation_{config_id}_{schedule_name}.csv"


def _recompute_expected_rows(raw_dir: Path) -> dict[tuple[str, str], dict[str, float | int]]:
    rows: dict[tuple[str, str], dict[str, float | int]] = {}
    for config_id in ablation.CONFIG_ORDER:
        baseline_accuracy: float | None = None
        raw_rows: dict[str, dict[str, float | int]] = {}
        for schedule_name, _factory, _rationale in lib.SCHEDULES:
            raw_csv = _raw_bundle_csv_path(raw_dir, config_id, schedule_name)
            with raw_csv.open("r", encoding="utf-8", newline="") as f:
                reader = list(csv.DictReader(f))
            total_count = len(reader)
            correct_count = sum(int(row["correct"]) for row in reader)
            accuracy_pct = 100.0 * correct_count / total_count
            raw_rows[schedule_name] = {
                "correct_count": correct_count,
                "total_count": total_count,
                "accuracy_pct": accuracy_pct,
            }
            if schedule_name == BASELINE:
                baseline_accuracy = accuracy_pct
        assert baseline_accuracy is not None
        for schedule_name, row in raw_rows.items():
            rows[(config_id, schedule_name)] = {
                **row,
                "delta_vs_baseline_pct": float(row["accuracy_pct"]) - baseline_accuracy,
            }
    return rows


def _validate_summary_csv(
    summary_csv: Path,
    expected_keys: list[tuple[str, str]],
    expected_rows: dict[tuple[str, str], dict[str, float | int]],
    failures: list[str],
) -> None:
    with summary_csv.open("r", encoding="utf-8", newline="") as f:
        actual_rows = list(csv.DictReader(f))
    expected_key_set = set(expected_keys)
    if len(actual_rows) != len(expected_keys):
        failures.append(
            f"{summary_csv.name}: row-count mismatch "
            f"{len(actual_rows)} != {len(expected_keys)}"
        )
        return
    for row in actual_rows:
        config_id = row["config_id"]
        schedule_name = row["schedule_name"]
        key = (config_id, schedule_name)
        if key not in expected_key_set:
            failures.append(f"{summary_csv.name}: unexpected row {config_id}/{schedule_name}")
            continue
        expected = expected_rows[key]
        if "total_count" in row:
            actual_total = int(row["total_count"])
            if actual_total != int(expected["total_count"]):
                failures.append(
                    f"{summary_csv.name}: total-count mismatch for {config_id}/{schedule_name}: "
                    f"{actual_total} != {int(expected['total_count'])}"
                )
        if "config_number" in row:
            expected_number = str(ablation.CONFIGS[config_id].config_number)
            if row["config_number"] != expected_number:
                failures.append(
                    f"{summary_csv.name}: config-number mismatch for {config_id}: "
                    f"{row['config_number']} != {expected_number}"
                )
        if "config_label" in row:
            expected_label = ablation.CONFIGS[config_id].paper_label
            if row["config_label"] != expected_label:
                failures.append(
                    f"{summary_csv.name}: config-label mismatch for {config_id}: "
                    f"{row['config_label']} != {expected_label}"
                )
        actual_accuracy = float(row["accuracy_pct"])
        if abs(actual_accuracy - float(expected["accuracy_pct"])) > SUMMARY_TOLERANCE_PCT:
            failures.append(
                f"{summary_csv.name}: accuracy mismatch for {config_id}/{schedule_name}: "
                f"{actual_accuracy:.4f}% vs raw {float(expected['accuracy_pct']):.4f}%"
            )
        actual_delta = float(row["delta_vs_baseline_pct"])
        if abs(actual_delta - float(expected["delta_vs_baseline_pct"])) > SUMMARY_TOLERANCE_PCT:
            failures.append(
                f"{summary_csv.name}: delta mismatch for {config_id}/{schedule_name}: "
                f"{actual_delta:+.4f} vs raw {float(expected['delta_vs_baseline_pct']):+.4f}"
            )


def _validate_locked_rows(
    expected_rows: dict[tuple[str, str], dict[str, float | int]],
    failures: list[str],
) -> None:
    positive_configs: list[str] = []
    for config_id in ablation.CONFIG_ORDER:
        total_count = int(expected_rows[(config_id, BASELINE)]["total_count"])
        if total_count != EXPECTED_TOTAL_COUNTS[config_id]:
            failures.append(
                f"locked sample-count mismatch for {config_id}: raw {total_count} vs expected {EXPECTED_TOTAL_COUNTS[config_id]}"
            )
        best_schedule, best_delta = max(
            (
                (
                    schedule_name,
                    float(expected_rows[(config_id, schedule_name)]["delta_vs_baseline_pct"]),
                )
                for schedule_name, _factory, _rationale in lib.SCHEDULES
            ),
            key=lambda item: item[1],
        )
        if best_delta > SUMMARY_TOLERANCE_PCT:
            positive_configs.append(config_id)
            expected_winner = EXPECTED_POSITIVE_WINNERS.get(config_id)
            if expected_winner is None:
                failures.append(
                    f"unexpected positive H1 winner for {config_id}: {best_schedule} ({best_delta:+.4f})"
                )
            else:
                expected_name, expected_delta = expected_winner
                if best_schedule != expected_name or abs(best_delta - expected_delta) > SUMMARY_TOLERANCE_PCT:
                    failures.append(
                        f"winner mismatch for {config_id}: "
                        f"{best_schedule} ({best_delta:+.4f}) vs expected {expected_name} ({expected_delta:+.4f})"
                    )
    if set(positive_configs) != set(EXPECTED_POSITIVE_WINNERS):
        failures.append(
            "positive-config set mismatch: "
            f"{sorted(positive_configs)} vs expected {sorted(EXPECTED_POSITIVE_WINNERS)}"
        )


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
    combined_summary_csv = OUT_DIR / "summary_per_config.csv"
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
    expected_rows = _recompute_expected_rows(RAW_DATA_DIR)

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
    for cfg_id in ablation.CONFIG_ORDER:
        per_config_keys = [(cfg_id, schedule_name) for schedule_name, _factory, _rationale in lib.SCHEDULES]
        _validate_summary_csv(
            OUT_DIR / f"summary_{cfg_id}.csv",
            per_config_keys,
            expected_rows,
            failures,
        )
        _validate_summary_csv(
            RAW_DATA_DIR / f"summary_{cfg_id}.csv",
            per_config_keys,
            expected_rows,
            failures,
        )
    all_keys = [
        (cfg_id, schedule_name)
        for cfg_id in ablation.CONFIG_ORDER
        for schedule_name, _factory, _rationale in lib.SCHEDULES
    ]
    _validate_summary_csv(combined_summary_csv, all_keys, expected_rows, failures)
    _validate_summary_csv(RAW_DATA_DIR / "summary_per_config.csv", all_keys, expected_rows, failures)
    _validate_locked_rows(expected_rows, failures)

    print(f"Config #2 baseline accuracy: {baseline:.4f}% (headline {HEADLINE:.2f}%, delta {baseline_delta:+.4f}%)")
    print(f"Schedule A accuracy: {sched_a:.4f}%")
    print(f"Schedule B accuracy: {sched_b:.4f}%")
    print(f"Schedule A/B different than baseline: {'yes' if changed else 'no'}")
    print(f"Summary CSV matches recomputed rows: {'yes' if summary_ok else 'no'}")
    print("Combined H1 summary matches raw 48-cell bundle: " + ("yes" if not failures else "no"))
    if failures:
        for failure in failures:
            print(f"[FAIL] {failure}")
        print("H1_SMOKE_FULL_SET_FAIL")
        return 1
    print("H1_SMOKE_FULL_SET_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
