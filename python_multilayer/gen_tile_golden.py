"""Generate tile-mode golden for B3 tile_accumulator_parity_tb.

Small deterministic case (in_dim=16 split into 2 tiles of 8, out_dim=4, T=16)
exercises REV 3.1 D1 (T×out_dim accumulator) and D7 (per-tile ADC then
accumulate, not raw-sum then single ADC).

Produces under python_multilayer/results_multilayer/tile_golden/:
  tile0_w_pos.hex, tile0_w_neg.hex   — 8 × 4 int-level
  tile1_w_pos.hex, tile1_w_neg.hex   — 8 × 4
  wl_stream.hex                      — T lines, 16-bit packed (wide enough for in_dim=16)
  spike_stream.hex                   — T lines, 4-bit packed
  counts.txt                         — 4 ints
  meta.txt
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from snn_engine_multilayer import _run_stage_streamed_rate_tiled  # noqa: E402


class FakeStage:
    def __init__(self, in_dim, out_dim, threshold):
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.threshold = threshold


def main() -> None:
    out_dir = ROOT / "results_multilayer" / "tile_golden"
    out_dir.mkdir(parents=True, exist_ok=True)

    tile_sizes = [8, 8]
    in_dim = sum(tile_sizes)  # 16
    out_dim = 4
    T = 16
    threshold = 6
    adc_bits = 10

    rng = np.random.default_rng(42)
    wl_stream = rng.integers(0, 2, (T, in_dim), dtype=np.int64)
    w_pos = rng.integers(0, 16, (in_dim, out_dim), dtype=np.int64)
    w_neg = rng.integers(0, 16, (in_dim, out_dim), dtype=np.int64)

    stage = FakeStage(in_dim, out_dim, threshold)

    # Split into tiles
    wl_tiles = [wl_stream[:, :8], wl_stream[:, 8:]]
    wp_tiles = [w_pos[:8, :], w_pos[8:, :]]
    wn_tiles = [w_neg[:8, :], w_neg[8:, :]]
    sum_max_per_tile = [ts * 15 for ts in tile_sizes]

    counts, _, spike_stream = _run_stage_streamed_rate_tiled(
        stage, wl_tiles, wp_tiles, wn_tiles,
        sum_max_per_tile=sum_max_per_tile, adc_bits=adc_bits,
    )

    # Dump hex
    for i, (wp, wn) in enumerate(zip(wp_tiles, wn_tiles)):
        with (out_dir / f"tile{i}_w_pos.hex").open("w") as f:
            for a in range(wp.shape[0]):
                for b in range(wp.shape[1]):
                    f.write(f"{int(wp[a, b]):01x}\n")
        with (out_dir / f"tile{i}_w_neg.hex").open("w") as f:
            for a in range(wn.shape[0]):
                for b in range(wn.shape[1]):
                    f.write(f"{int(wn[a, b]):01x}\n")

    # WL stream: 16-bit packed (bit i = wl[t, i])
    with (out_dir / "wl_stream.hex").open("w") as f:
        for t in range(T):
            val = 0
            for i in range(in_dim):
                if wl_stream[t, i]:
                    val |= (1 << i)
            f.write(f"{val:04x}\n")

    # Spike stream: 4-bit packed
    with (out_dir / "spike_stream.hex").open("w") as f:
        for t in range(T):
            val = 0
            for j in range(out_dim):
                if spike_stream[t, j]:
                    val |= (1 << j)
            f.write(f"{val:01x}\n")

    # Counts
    with (out_dir / "counts.txt").open("w") as f:
        for c in counts:
            f.write(f"{int(c)}\n")

    # Meta
    with (out_dir / "meta.txt").open("w") as f:
        f.write(f"in_dim {in_dim}\n")
        f.write(f"out_dim {out_dim}\n")
        f.write(f"T {T}\n")
        f.write(f"threshold {threshold}\n")
        f.write(f"adc_bits {adc_bits}\n")
        f.write(f"n_tiles {len(tile_sizes)}\n")
        for i, ts in enumerate(tile_sizes):
            f.write(f"tile{i}_in_dim {ts}\n")
            f.write(f"tile{i}_sum_max {ts*15}\n")

    print(f"[done] {out_dir}")
    print(f"  counts = {counts.tolist()}")
    print(f"  total stream spikes = {int(spike_stream.sum())}")


if __name__ == "__main__":
    main()
