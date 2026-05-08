"""Predefined H1 per-layer LIF schedule library for §5.7 ablation.

The search space is fixed before the sweep runs to avoid cherry-picking.
Schedule A / B are aligned to the live H1 Phase-7 board definitions:

- Schedule A (threshold ramp): layer 0 uses threshold x0.85 and later layers
  relax toward x1.00; for L=2 this matches the board-proven `(13, soft)`,
  `(8, soft)` pair derived from defaults `(16, 8)`.
- Schedule B (mixed reset): soft reset on early layers, hard reset on late
  layers; for L=2 this matches the board-proven `(soft, hard)` pair.
"""

from __future__ import annotations

from typing import Callable

LayerSchedule = list[tuple[float, int]]
ScheduleFactory = Callable[[int], LayerSchedule]


def _lerp(start: float, stop: float, fraction: float) -> float:
    return float(start + (stop - start) * fraction)


def schedule_baseline(L: int) -> LayerSchedule:
    """Baseline (uniform default). Must reproduce §3 Table-3."""
    return [(1.00, 0)] * L


def schedule_thresh_ramp_descending(L: int) -> LayerSchedule:
    """Phase-7 Schedule A: early layers tighter, later layers relax to default."""
    if L <= 1:
        return schedule_baseline(L)
    return [(_lerp(0.85, 1.00, i / (L - 1)), 0) for i in range(L)]


def schedule_thresh_ramp_ascending(L: int) -> LayerSchedule:
    """Mirror of Schedule A: late layers tighter, early layers stay at default."""
    if L <= 1:
        return schedule_baseline(L)
    return [(_lerp(1.00, 0.85, i / (L - 1)), 0) for i in range(L)]


def schedule_reset_mixed_soft_early(L: int) -> LayerSchedule:
    """Phase-7 Schedule B: soft reset early layers, hard reset late layers."""
    if L <= 1:
        return schedule_baseline(L)
    return [(1.00, 0 if i < L // 2 else 1) for i in range(L)]


def schedule_reset_mixed_hard_early(L: int) -> LayerSchedule:
    """Mirror of Schedule B: hard reset early layers, soft reset late layers."""
    if L <= 1:
        return schedule_baseline(L)
    return [(1.00, 1 if i < L // 2 else 0) for i in range(L)]


def schedule_thresh_tight_uniform(L: int) -> LayerSchedule:
    """Every layer threshold x0.85 (uniform tightening)."""
    return [(0.85, 0)] * L


def schedule_thresh_loose_uniform(L: int) -> LayerSchedule:
    """Every layer threshold x1.15 (uniform loosening)."""
    return [(1.15, 0)] * L


def schedule_all_hard_reset(L: int) -> LayerSchedule:
    """Every layer hard reset (no soft accumulation)."""
    return [(1.00, 1)] * L


SCHEDULES: list[tuple[str, ScheduleFactory, str]] = [
    ("baseline", schedule_baseline, "uniform default; control / byte-parity anchor"),
    (
        "thresh_ramp_descending",
        schedule_thresh_ramp_descending,
        "Phase-7 Schedule A; layer-0 threshold x0.85, later layers relax toward x1.00",
    ),
    (
        "thresh_ramp_ascending",
        schedule_thresh_ramp_ascending,
        "mirror of Schedule A; later layers tighten toward x0.85",
    ),
    (
        "reset_mixed_soft_early",
        schedule_reset_mixed_soft_early,
        "Phase-7 Schedule B; soft-early / hard-late reset mix",
    ),
    (
        "reset_mixed_hard_early",
        schedule_reset_mixed_hard_early,
        "mirror of Schedule B; hard-early / soft-late reset mix",
    ),
    ("thresh_tight_uniform", schedule_thresh_tight_uniform, "every layer threshold x0.85"),
    ("thresh_loose_uniform", schedule_thresh_loose_uniform, "every layer threshold x1.15"),
    ("all_hard_reset", schedule_all_hard_reset, "every layer hard reset; no soft accumulation"),
]


SCHEDULE_MAP = {name: (factory, rationale) for name, factory, rationale in SCHEDULES}
