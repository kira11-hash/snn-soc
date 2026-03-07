"""Presets for the paper-oriented E0 staged reruns.

This module keeps the paper-specific search scope separate from the
general-purpose exhaustive flow in ``run_all.py``.
"""

from __future__ import annotations

from typing import Dict, Iterable, List


STAGE_METHODS: List[str] = [
    "avgpool_8x8",
    "pad32_zero_8x8",
    "pad32_reflect_8x8",
    "pad32_replicate_8x8",
    "maxpool_8x8",
    "proj_sup_64",
]

STAGE1_FIXED_CONFIG: Dict[str, int] = {
    "adc_bits": 8,
    "weight_bits": 4,
    "timesteps": 3,
}

STAGE1_COARSE_RATIOS: List[float] = [0.01, 0.02, 0.04, 0.08, 0.15, 0.30, 0.50]
STAGE1_SCHEMES: List[str] = ["B"]

STAGE2_FINE_STEP = 0.01
STAGE2_FINE_HALF_WIDTH = 0.05
STAGE2_FINE_MIN = 0.01
STAGE2_FINE_MAX = 0.70
STAGE2_TOP_NON_NEURAL = 2

STAGE3_ADC_BITS = [6, 8, 10, 12]
STAGE3_WEIGHT_BITS = [2, 3, 4, 6, 8]
STAGE3_TIMESTEPS = [1, 3, 5, 10, 20]
STAGE3_PRIMARY_SCHEME = "B"
RECOMMEND_ACC_MARGIN = 0.005


def is_learned_method(method_name: str) -> bool:
    return method_name.startswith("proj_")


def build_fine_ratio_grid(
    center: float,
    half_width: float = STAGE2_FINE_HALF_WIDTH,
    step: float = STAGE2_FINE_STEP,
    min_ratio: float = STAGE2_FINE_MIN,
    max_ratio: float = STAGE2_FINE_MAX,
) -> List[float]:
    """Build a clipped linear fine grid around a coarse ratio center."""
    low = max(min_ratio, center - half_width)
    high = min(max_ratio, center + half_width)
    points: List[float] = []
    cur = low
    while cur <= high + 1e-9:
        points.append(round(cur, 4))
        cur += step
    if round(center, 4) not in points:
        points.append(round(center, 4))
        points = sorted(set(points))
    return points


def select_stage2_finalists(best_rows: Iterable[dict]) -> List[str]:
    """Pick the non-neural finalists plus the learned upper-bound reference."""
    rows = list(best_rows)
    non_neural = [row for row in rows if not is_learned_method(row["method"])]
    non_neural = sorted(non_neural, key=lambda row: row["best_val_acc"], reverse=True)
    finalists = [row["method"] for row in non_neural[:STAGE2_TOP_NON_NEURAL]]

    learned = [row for row in rows if is_learned_method(row["method"])]
    learned = sorted(learned, key=lambda row: row["best_val_acc"], reverse=True)
    if learned:
        finalists.append(learned[0]["method"])

    seen = set()
    deduped: List[str] = []
    for method in finalists:
        if method in seen:
            continue
        seen.add(method)
        deduped.append(method)
    return deduped
