"""Generate streamed-rate stage golden vectors for RTL bit-parity.

Small deterministic case (in_dim=8, out_dim=4, T=16) produces:
  - wl_stream.hex      : [T][in_dim] 1-bit binary WL mask per line
  - w_pos.hex          : [in_dim][out_dim] 4-bit level index, row-major
  - w_neg.hex          : [in_dim][out_dim] 4-bit level index
  - diff_per_t.hex     : [T][out_dim] signed 14-bit per line (pre-LIF diff)
  - spike_stream.hex   : [T][out_dim] 1-bit fired-at-t
  - counts.txt         : final spike_counts per neuron
  - golden_meta.txt    : threshold, sum_max, adc_bits

Python path: _run_stage_streamed_rate from snn_engine_multilayer, ADC via
adc_scale_v2.rtl_adc_scale_v2. These match cim_mac_behavioral_v2.sv and
stage_engine_v2 semantics exactly (Scheme B per-tile sum_max, integer
arithmetic, 10-bit ADC).
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from adc_scale_v2 import rtl_adc_scale_v2  # noqa: E402
from snn_engine_multilayer import _run_stage_streamed_rate  # noqa: E402


class FakeStage:
    def __init__(self, in_dim: int, out_dim: int, threshold: int):
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.threshold = threshold


def gen_case(
    out_dir: Path,
    *,
    in_dim: int = 8,
    out_dim: int = 4,
    T: int = 16,
    adc_bits: int = 10,
    threshold: int = 8,
    seed: int = 0,
) -> None:
    """Write golden hex files into out_dir."""
    rng = np.random.default_rng(seed)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Random binary WL stream and 4-bit weight matrices
    wl_stream = rng.integers(0, 2, (T, in_dim), dtype=np.int64)
    w_pos = rng.integers(0, 16, (in_dim, out_dim), dtype=np.int64)
    w_neg = rng.integers(0, 16, (in_dim, out_dim), dtype=np.int64)
    sum_max = in_dim * 15
    stage = FakeStage(in_dim, out_dim, threshold)

    counts, membrane, spike_stream = _run_stage_streamed_rate(
        stage, wl_stream, w_pos, w_neg, sum_max=sum_max, adc_bits=adc_bits,
    )

    # Reproduce per-timestep signed diff (before LIF) for TB waveform compare
    diff_per_t = np.zeros((T, out_dim), dtype=np.int64)
    for t in range(T):
        wl = wl_stream[t]
        pos_sum = (wl @ w_pos).astype(np.int64)
        neg_sum = (wl @ w_neg).astype(np.int64)
        adc_pos = np.array(
            [rtl_adc_scale_v2(int(v), sum_max=sum_max, adc_bits=adc_bits) for v in pos_sum],
            dtype=np.int64,
        )
        adc_neg = np.array(
            [rtl_adc_scale_v2(int(v), sum_max=sum_max, adc_bits=adc_bits) for v in neg_sum],
            dtype=np.int64,
        )
        diff_per_t[t] = adc_pos - adc_neg

    # --- Hex writers ---
    # wl_stream: one line per timestep; each line = `in_dim` chars of 0/1
    # (LSB = in_dim-1; packs into P_N_IN-bit vector from right-to-left).
    # Emit as hex of an in_dim-bit vector where bit i represents WL row i.
    hex_width = (in_dim + 3) // 4
    with (out_dir / "wl_stream.hex").open("w") as f:
        for t in range(T):
            val = 0
            for i in range(in_dim):
                if wl_stream[t, i]:
                    val |= (1 << i)
            f.write(f"{val:0{hex_width}x}\n")

    # Weight hex: one line per (i, j) — in_dim * out_dim lines in row-major
    # (matches cim_mac_behavioral_v2 load port: i = w_load_i, j = w_load_j).
    with (out_dir / "w_pos.hex").open("w") as f:
        for i in range(in_dim):
            for j in range(out_dim):
                f.write(f"{int(w_pos[i, j]):01x}\n")
    with (out_dir / "w_neg.hex").open("w") as f:
        for i in range(in_dim):
            for j in range(out_dim):
                f.write(f"{int(w_neg[i, j]):01x}\n")

    # Expected per-neuron signed diff per timestep (14-bit two's complement)
    with (out_dir / "diff_per_t.hex").open("w") as f:
        for t in range(T):
            for j in range(out_dim):
                v = int(diff_per_t[t, j]) & 0x3FFF  # 14-bit mask
                f.write(f"{v:04x}\n")

    # Expected spike stream per timestep (binary, length out_dim)
    spike_hex_width = (out_dim + 3) // 4
    with (out_dir / "spike_stream.hex").open("w") as f:
        for t in range(T):
            val = 0
            for j in range(out_dim):
                if spike_stream[t, j]:
                    val |= (1 << j)
            f.write(f"{val:0{spike_hex_width}x}\n")

    # Final spike counts
    with (out_dir / "counts.txt").open("w") as f:
        for j in range(out_dim):
            f.write(f"{int(counts[j])}\n")

    # Metadata
    with (out_dir / "golden_meta.txt").open("w") as f:
        f.write(f"in_dim {in_dim}\n")
        f.write(f"out_dim {out_dim}\n")
        f.write(f"T {T}\n")
        f.write(f"adc_bits {adc_bits}\n")
        f.write(f"threshold {threshold}\n")
        f.write(f"sum_max {sum_max}\n")
        f.write(f"seed {seed}\n")

    print(f"[gen] wrote {out_dir}")
    print(f"       counts = {counts.tolist()}")
    print(f"       stream total = {int(spike_stream.sum())}")


if __name__ == "__main__":
    here = ROOT / "results_multilayer" / "streamed_stage_golden"
    gen_case(here, in_dim=8, out_dim=4, T=16, threshold=8, seed=0)
