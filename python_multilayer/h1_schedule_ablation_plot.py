#!/usr/bin/env python3
"""Plotter for H1 schedule ablation summaries."""

from __future__ import annotations

import csv
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import TwoSlopeNorm

import h1_schedule_ablation as ablation
import h1_schedule_library as lib


OUT_DIR = ablation.DEFAULT_OUT_DIR


def _load_summary(config_id: str) -> list[dict[str, object]]:
    path = OUT_DIR / f"summary_{config_id}.csv"
    rows: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        by_name = {row["schedule_name"]: row for row in csv.DictReader(f)}
    for schedule_name, _factory, rationale in lib.SCHEDULES:
        row = by_name[schedule_name]
        rows.append(
            {
                "schedule_name": schedule_name,
                "schedule_rationale": rationale,
                "accuracy_pct": float(row["accuracy_pct"]),
                "delta_vs_baseline_pct": float(row["delta_vs_baseline_pct"]),
            }
        )
    return rows


def _write_combined_summary() -> Path:
    out_path = OUT_DIR / "summary_per_config.csv"
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "config_id",
                "config_number",
                "config_label",
                "schedule_name",
                "schedule_rationale",
                "accuracy_pct",
                "delta_vs_baseline_pct",
            ],
        )
        writer.writeheader()
        for config_id in ablation.CONFIG_ORDER:
            spec = ablation.CONFIGS[config_id]
            for row in _load_summary(config_id):
                writer.writerow(
                    {
                        "config_id": config_id,
                        "config_number": spec.config_number,
                        "config_label": spec.paper_label,
                        **row,
                    }
                )
    return out_path


def _plot_per_config(config_id: str) -> None:
    spec = ablation.CONFIGS[config_id]
    rows = _load_summary(config_id)
    labels = [row["schedule_name"] for row in rows]
    accuracy = [float(row["accuracy_pct"]) for row in rows]
    delta = [float(row["delta_vs_baseline_pct"]) for row in rows]

    colors = []
    for idx, d in enumerate(delta):
        if idx == 0:
            colors.append("#1f4b99")
        elif d > 0:
            colors.append("#2a9d5b")
        elif d < 0:
            colors.append("#c96a3d")
        else:
            colors.append("#8c8c8c")

    fig, ax = plt.subplots(figsize=(11.5, 5.6))
    y = np.arange(len(labels))
    ax.barh(y, accuracy, color=colors, edgecolor="#222222", linewidth=0.6)
    ax.set_yticks(y, labels)
    ax.invert_yaxis()
    ax.set_xlabel("Accuracy (%)")
    ax.set_title(f"{spec.paper_label}: full-test-set accuracy across 8 predefined schedules")
    ax.grid(axis="x", linestyle="--", alpha=0.25)

    x_max = max(accuracy) + 2.2
    ax.set_xlim(min(accuracy) - 1.0, x_max)
    for idx, (acc, d) in enumerate(zip(accuracy, delta)):
        text = f"{acc:.2f}%"
        if idx != 0:
            text += f" ({d:+.2f})"
        ax.text(acc + 0.12, idx, text, va="center", fontsize=9)

    caption = (
        "Predefined search space, reported exhaustively. Baseline is the uniform default. "
        "Joint multi-axis robustness beyond {threshold, reset_mode} single-axis-pair changes is not characterized."
    )
    fig.text(0.01, 0.01, caption, ha="left", va="bottom", fontsize=9)
    fig.tight_layout(rect=(0, 0.05, 1, 1))

    stem = OUT_DIR / f"h1_ablation_{config_id}"
    fig.savefig(stem.with_suffix(".png"), dpi=220)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def _plot_heatmap() -> None:
    schedule_names = [name for name, _factory, _rationale in lib.SCHEDULES]
    config_labels = [ablation.CONFIGS[cfg].paper_label for cfg in ablation.CONFIG_ORDER]
    matrix = np.zeros((len(ablation.CONFIG_ORDER), len(schedule_names)), dtype=np.float64)

    for row_idx, config_id in enumerate(ablation.CONFIG_ORDER):
        rows = _load_summary(config_id)
        by_name = {str(row["schedule_name"]): float(row["delta_vs_baseline_pct"]) for row in rows}
        for col_idx, schedule_name in enumerate(schedule_names):
            matrix[row_idx, col_idx] = by_name[schedule_name]

    vmax = float(np.max(np.abs(matrix))) if matrix.size else 1.0
    norm = TwoSlopeNorm(vmin=-vmax, vcenter=0.0, vmax=vmax)

    fig, ax = plt.subplots(figsize=(13.5, 5.8))
    im = ax.imshow(matrix, cmap="RdYlGn", norm=norm, aspect="auto")
    ax.set_xticks(np.arange(len(schedule_names)), schedule_names, rotation=30, ha="right")
    ax.set_yticks(np.arange(len(config_labels)), config_labels)
    ax.set_title("H1 schedule ablation: delta vs baseline across 6 configs x 8 schedules")

    for r in range(matrix.shape[0]):
        for c in range(matrix.shape[1]):
            ax.text(c, r, f"{matrix[r, c]:+.2f}", ha="center", va="center", fontsize=8, color="#111111")

    cbar = fig.colorbar(im, ax=ax, shrink=0.92)
    cbar.set_label("Delta vs baseline (percentage points)")
    fig.tight_layout()

    stem = OUT_DIR / "h1_ablation_cross_config_heatmap"
    fig.savefig(stem.with_suffix(".png"), dpi=220)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    combined = _write_combined_summary()
    for config_id in ablation.CONFIG_ORDER:
        _plot_per_config(config_id)
    _plot_heatmap()
    print(f"[ok] wrote {combined}")
    print("H1_SCHEDULE_ABLATION_PLOTS_READY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
