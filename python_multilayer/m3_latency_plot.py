#!/usr/bin/env python3
"""
m3_latency_plot.py — M3 Phase 2A latency partition plotter.

Reads board UART logs containing M3_CYCLES lines from ZCU102 runs
(captured via scripts/capture_uart.py) and produces:

  - essay/exp_latency_partition/m3_segments.csv
        Per-sample CSV: config, host, sample, seg0..seg4, total
  - essay/exp_latency_partition/m3_stacked_bar.png + .pdf
        Mean cycle counts per (config, host) as a stacked bar chart
        with 5 segments (HOST_SETUP / TRANSFER / ACCEL_ACTIVE /
        READBACK / DECODE) in distinct colors

Spec: essay/m3_phase2a_design_2026_05_06.md §6.

Codex review nice-to-have #4 (parser smoke test):
  - line count == sample × config × host (must equal 4 × 10 = 40 by
    default; 2 × 10 = 20 if only one host's logs are passed)
  - all seg fields >= 0
  - no negative totals
  - M3_JITTER_FAIL count == 0 (fail loud if any non-zero)

Usage:
    python m3_latency_plot.py LOG1 [LOG2 ...] \\
        --out-dir essay/exp_latency_partition \\
        [--expected-samples-per-bar 10]

Each log file may contain interleaved M3_CYCLES + M3_JITTER_FAIL +
unrelated debug lines; only M3_CYCLES is parsed for chart data.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import defaultdict
from typing import Iterable

# ── Parsing ────────────────────────────────────────────────────────────

M3_CYCLES_RE = re.compile(
    r"^M3_CYCLES\s+(\S+)\s+(\S+)\s+(\d+)\s+"
    r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$"
)
M3_JITTER_RE = re.compile(
    r"^M3_JITTER_FAIL\s+(\S+)\s+(\S+)\s+(\d+)\s+sum=(\d+)\s+total=(\d+)\s+delta=(\d+)\s*$"
)

SEG_NAMES = ["HOST_SETUP", "TRANSFER", "ACCEL_ACTIVE", "READBACK", "DECODE"]
SEG_COLORS = ["#7fbc41", "#1f78b4", "#e31a1c", "#ff7f00", "#6a3d9a"]

# Sentinels for parser sanity. 2^53 chosen as a hard limit to flag any
# corruption that yields garbage u64 values. At 50 MHz, 2^53 cycles ≈
# 5.7 years, so legitimate measurements never approach it.
MAX_REASONABLE_CYCLES = 1 << 53


class M3Sample:
    __slots__ = ("config", "host", "sample", "segs", "total")

    def __init__(self, config: str, host: str, sample: int, segs: list[int]):
        if len(segs) != 5:
            raise ValueError(f"need 5 seg fields, got {len(segs)}: {segs!r}")
        for s in segs:
            if s < 0:
                raise ValueError(f"negative seg: {segs!r}")
            if s > MAX_REASONABLE_CYCLES:
                raise ValueError(
                    f"seg exceeds 2^53: {s} ({config}/{host}/sample={sample})"
                )
        self.config = config
        self.host = host
        self.sample = sample
        self.segs = segs
        self.total = sum(segs)


class JitterFail:
    __slots__ = ("config", "host", "sample", "sum_cycles", "total_cycles", "delta")

    def __init__(self, config: str, host: str, sample: int, s: int, t: int, d: int):
        self.config = config
        self.host = host
        self.sample = sample
        self.sum_cycles = s
        self.total_cycles = t
        self.delta = d


def parse_log(path: str) -> tuple[list[M3Sample], list[JitterFail]]:
    samples: list[M3Sample] = []
    jitters: list[JitterFail] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            line = raw_line.rstrip("\r\n")
            m = M3_CYCLES_RE.match(line)
            if m:
                config = m.group(1)
                host = m.group(2)
                sample = int(m.group(3))
                segs = [int(m.group(i)) for i in range(4, 9)]
                samples.append(M3Sample(config, host, sample, segs))
                continue
            j = M3_JITTER_RE.match(line)
            if j:
                jitters.append(JitterFail(
                    j.group(1), j.group(2), int(j.group(3)),
                    int(j.group(4)), int(j.group(5)), int(j.group(6))
                ))
    return samples, jitters


# ── Smoke test (Codex §13 #4) ──────────────────────────────────────────

def smoke_test(samples: list[M3Sample],
               jitters: list[JitterFail],
               expected_samples_per_bar: int) -> None:
    """Run parser smoke test. Raises AssertionError on first failure;
    callers should let the exception abort the plot generation per spec.
    """
    if not samples:
        raise AssertionError("no M3_CYCLES lines parsed from any log")

    # Group by (config, host) — these are the bars in the chart.
    groups: dict[tuple[str, str], list[M3Sample]] = defaultdict(list)
    for s in samples:
        groups[(s.config, s.host)].append(s)

    # Per-bar count check.
    for (cfg, host), bar_samples in sorted(groups.items()):
        if len(bar_samples) != expected_samples_per_bar:
            raise AssertionError(
                f"bar ({cfg!r}, {host!r}) has {len(bar_samples)} samples, "
                f"expected {expected_samples_per_bar}"
            )
        # Sample IDs should be 0..N-1 with no duplicates.
        ids = sorted(s.sample for s in bar_samples)
        if ids != list(range(expected_samples_per_bar)):
            raise AssertionError(
                f"bar ({cfg!r}, {host!r}) sample ids = {ids}; "
                f"expected range(0, {expected_samples_per_bar})"
            )

    # Jitter must be zero for a clean board run. If non-zero, fail loud
    # so user is forced to investigate before plotting.
    if jitters:
        details = "\n".join(
            f"  {j.config} {j.host} sample={j.sample} "
            f"sum={j.sum_cycles} total={j.total_cycles} delta={j.delta}"
            for j in jitters[:10]
        )
        raise AssertionError(
            f"M3_JITTER_FAIL lines present ({len(jitters)} total). First 10:\n{details}"
        )


# ── Aggregation + CSV ──────────────────────────────────────────────────

def write_csv(samples: list[M3Sample], path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["config", "host", "sample"] +
                   [f"seg{i}_{n}" for i, n in enumerate(SEG_NAMES)] +
                   ["total"])
        # Sort for stable output regardless of input ordering.
        for s in sorted(samples, key=lambda x: (x.config, x.host, x.sample)):
            w.writerow([s.config, s.host, s.sample] + s.segs + [s.total])


def aggregate_means(
    samples: list[M3Sample]
) -> dict[tuple[str, str], list[float]]:
    """Return {(config, host) → [mean_seg0, ..., mean_seg4]}."""
    groups: dict[tuple[str, str], list[list[int]]] = defaultdict(
        lambda: [[] for _ in range(5)]
    )
    for s in samples:
        for i, v in enumerate(s.segs):
            groups[(s.config, s.host)][i].append(v)
    return {
        key: [sum(seg) / len(seg) for seg in seg_lists]
        for key, seg_lists in groups.items()
    }


# ── Plotting ───────────────────────────────────────────────────────────

def plot_stacked_bar(
    means: dict[tuple[str, str], list[float]],
    out_png: str,
    out_pdf: str,
) -> None:
    # matplotlib import here so smoke test still works on hosts without it.
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    keys = sorted(means.keys())
    if not keys:
        raise AssertionError("nothing to plot")

    labels = [f"{cfg}\n({host})" for cfg, host in keys]
    seg_matrix = [[means[k][i] for k in keys] for i in range(5)]

    fig, ax = plt.subplots(figsize=(max(6, 1.6 * len(keys)), 5.0))
    bottom = [0.0] * len(keys)
    for i, (seg_name, color) in enumerate(zip(SEG_NAMES, SEG_COLORS)):
        ax.bar(labels, seg_matrix[i], bottom=bottom,
               color=color, label=seg_name, edgecolor="black", linewidth=0.4)
        bottom = [b + v for b, v in zip(bottom, seg_matrix[i])]

    # Log scale because LeNet-5 ~ 10× FC Fashion 14×14.
    # Add a small floor so log doesn't choke on segments that are 0.
    ax.set_yscale("log")
    ax.set_ylim(bottom=max(1.0, min(b for b in bottom if b > 0) * 0.5))
    ax.set_ylabel("Cycles per inference (log scale)")
    ax.set_title("M3: latency / cycle partition (mean of 10 samples)")
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), borderaxespad=0)
    ax.grid(True, axis="y", which="both", alpha=0.3)

    fig.tight_layout()
    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    fig.savefig(out_png, dpi=150)
    fig.savefig(out_pdf)
    plt.close(fig)


# ── Driver ─────────────────────────────────────────────────────────────

def main(argv: Iterable[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("logs", nargs="+",
                   help="UART log file(s) containing M3_CYCLES lines")
    p.add_argument("--out-dir", default="essay/exp_latency_partition",
                   help="Output directory (default: essay/exp_latency_partition)")
    p.add_argument("--expected-samples-per-bar", type=int, default=10,
                   help="Per-bar sample count for smoke test (default: 10)")
    p.add_argument("--no-plot", action="store_true",
                   help="Skip rendering — only emit CSV + run smoke test")
    args = p.parse_args(list(argv) if argv is not None else None)

    all_samples: list[M3Sample] = []
    all_jitters: list[JitterFail] = []
    for path in args.logs:
        samples, jitters = parse_log(path)
        print(f"[M3 parse] {path}: {len(samples)} M3_CYCLES, "
              f"{len(jitters)} M3_JITTER_FAIL")
        all_samples.extend(samples)
        all_jitters.extend(jitters)

    # Smoke test first; assertions abort plotting per Codex review #4.
    smoke_test(all_samples, all_jitters, args.expected_samples_per_bar)
    print(f"[M3 smoke] PASS — {len(all_samples)} samples across "
          f"{len({(s.config, s.host) for s in all_samples})} bars")

    # CSV always (cheap and essential for paper/manifest reproducibility).
    csv_path = os.path.join(args.out_dir, "m3_segments.csv")
    write_csv(all_samples, csv_path)
    print(f"[M3 csv]   wrote {csv_path}")

    if args.no_plot:
        return 0

    means = aggregate_means(all_samples)
    png_path = os.path.join(args.out_dir, "m3_stacked_bar.png")
    pdf_path = os.path.join(args.out_dir, "m3_stacked_bar.pdf")
    plot_stacked_bar(means, png_path, pdf_path)
    print(f"[M3 plot]  wrote {png_path} + {pdf_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
