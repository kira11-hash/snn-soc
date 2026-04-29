#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.tile_mode_1_e2e_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

GOLDEN_DIR="$RUN_DIR/golden"
mkdir -p "$GOLDEN_DIR"

run_python - "$GOLDEN_DIR" <<'PY'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import numpy as np

ROOT = Path.cwd().parent / "python_multilayer"
sys.path.insert(0, str(ROOT))
from adc_scale_v2 import rtl_adc_scale_v2  # noqa: E402

out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)

FULL_IN_DIM = 320
TILE0_DIM = 256
TILE1_DIM = 64
OUT_DIM = 16
T = 10
THRESHOLD = 128
ADC_BITS = 10
LEVEL_MAX = 7

rng = np.random.default_rng(0x20260430)
wl_stream = rng.integers(0, 2, size=(T, FULL_IN_DIM), dtype=np.int64)
w_pos = rng.integers(0, LEVEL_MAX + 1, size=(FULL_IN_DIM, OUT_DIM), dtype=np.int64)
w_neg = rng.integers(0, LEVEL_MAX + 1, size=(FULL_IN_DIM, OUT_DIM), dtype=np.int64)


def write_flat_hex(path: Path, matrix: np.ndarray) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for i in range(matrix.shape[0]):
            for j in range(matrix.shape[1]):
                f.write(f"{int(matrix[i, j]):x}\n")


def write_wl_hex(path: Path, matrix: np.ndarray, width: int) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for t in range(matrix.shape[0]):
            value = 0
            for i in range(width):
                if int(matrix[t, i]):
                    value |= 1 << i
            f.write(f"{value:064x}\n")


def mac_diff(wl: np.ndarray, pos: np.ndarray, neg: np.ndarray, sum_max: int) -> np.ndarray:
    raw_pos = wl @ pos
    raw_neg = wl @ neg
    return np.asarray([
        rtl_adc_scale_v2(int(p), sum_max=sum_max, adc_bits=ADC_BITS)
        - rtl_adc_scale_v2(int(n), sum_max=sum_max, adc_bits=ADC_BITS)
        for p, n in zip(raw_pos, raw_neg)
    ], dtype=np.int64)


tile0_w_pos = w_pos[:TILE0_DIM]
tile0_w_neg = w_neg[:TILE0_DIM]
tile1_w_pos = w_pos[TILE0_DIM:]
tile1_w_neg = w_neg[TILE0_DIM:]
tile0_wl = wl_stream[:, :TILE0_DIM]
tile1_wl = wl_stream[:, TILE0_DIM:]

partial_tile0 = np.zeros((T, OUT_DIM), dtype=np.int64)
partial_final = np.zeros((T, OUT_DIM), dtype=np.int64)
for t in range(T):
    d0 = mac_diff(tile0_wl[t], tile0_w_pos, tile0_w_neg, TILE0_DIM * LEVEL_MAX)
    d1 = mac_diff(tile1_wl[t], tile1_w_pos, tile1_w_neg, TILE1_DIM * LEVEL_MAX)
    partial_tile0[t] = d0
    partial_final[t] = d0 + d1

max_abs_partial = int(np.max(np.abs(partial_final)))
if max_abs_partial > 8191:
    raise SystemExit(f"partial overflow: max_abs_partial={max_abs_partial}")

membrane = np.zeros(OUT_DIM, dtype=np.int64)
spike_stream = np.zeros((T, OUT_DIM), dtype=np.int64)
for t in range(T):
    membrane += partial_final[t]
    fired = membrane >= THRESHOLD
    spike_stream[t, fired] = 1
    membrane[fired] -= THRESHOLD

write_wl_hex(out_dir / "wl_tile0.hex", tile0_wl, TILE0_DIM)
write_wl_hex(out_dir / "wl_tile1.hex", tile1_wl, TILE1_DIM)
write_flat_hex(out_dir / "tile0_w_pos.hex", tile0_w_pos)
write_flat_hex(out_dir / "tile0_w_neg.hex", tile0_w_neg)
write_flat_hex(out_dir / "tile1_w_pos.hex", tile1_w_pos)
write_flat_hex(out_dir / "tile1_w_neg.hex", tile1_w_neg)

with (out_dir / "expected_spike_stream.hex").open("w", encoding="ascii", newline="\n") as f:
    for t in range(T):
        value = 0
        for j in range(OUT_DIM):
            if int(spike_stream[t, j]):
                value |= 1 << j
        f.write(f"{value:04x}\n")

counts = spike_stream.sum(axis=0)
with (out_dir / "expected_counts.txt").open("w", encoding="ascii", newline="\n") as f:
    for value in counts:
        f.write(f"{int(value)}\n")

trace_points = [(0, 0), (3, 5)]
with (out_dir / "partial_trace.txt").open("w", encoding="ascii", newline="\n") as f:
    for t, j in trace_points:
        f.write(f"{t} {j} {int(partial_tile0[t, j])} {int(partial_final[t, j])}\n")

expected_path = out_dir / "expected_spike_stream.hex"
expected_sha = hashlib.sha256(expected_path.read_bytes()).hexdigest()
(out_dir / "expected_spike_stream.sha256").write_text(expected_sha + "\n", encoding="ascii")

with (out_dir / "meta.txt").open("w", encoding="ascii", newline="\n") as f:
    f.write(f"full_in_dim {FULL_IN_DIM}\n")
    f.write(f"tile0_dim {TILE0_DIM}\n")
    f.write(f"tile1_dim {TILE1_DIM}\n")
    f.write(f"out_dim {OUT_DIM}\n")
    f.write(f"T {T}\n")
    f.write(f"threshold {THRESHOLD}\n")
    f.write(f"adc_bits {ADC_BITS}\n")
    f.write(f"sum_max0 {TILE0_DIM * LEVEL_MAX}\n")
    f.write(f"sum_max1 {TILE1_DIM * LEVEL_MAX}\n")
    f.write(f"max_abs_partial {max_abs_partial}\n")
    f.write("counts " + " ".join(str(int(x)) for x in counts) + "\n")
    f.write(f"expected_spike_stream_sha256 {expected_sha}\n")

print(f"[PY] generated tile_mode_1_e2e golden in {out_dir}")
print(f"[PY] counts={counts.astype(int).tolist()}")
print(f"[PY] max_abs_partial={max_abs_partial}")
print(f"[PY] expected_spike_stream_sha256={expected_sha}")
PY

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_tile_mode_1_e2e.f \
  -s tile_mode_1_e2e_tb -o "$RUN_DIR/tile_mode_1_e2e_tb.out"

LOG="$SCRIPT_DIR/tile_mode_1_e2e_sim.log"
run_vvp "$RUN_DIR/tile_mode_1_e2e_tb.out" "+GOLDEN_DIR=$GOLDEN_DIR" | tee "$LOG"

PY_SHA=$(run_python - "$GOLDEN_DIR/expected_spike_stream.sha256" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).read_text(encoding="ascii").strip())
PY
)
RTL_SHA=$(run_python - "$GOLDEN_DIR/rtl_spike_stream.hex" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)

echo "[SHA] python_expected_spike_stream=$PY_SHA" | tee -a "$LOG"
echo "[SHA] rtl_spike_stream=$RTL_SHA" | tee -a "$LOG"

if [ "$PY_SHA" != "$RTL_SHA" ]; then
  echo "[RESULT] TILE_MODE_1_E2E_TB_FAIL_SHA_MISMATCH" | tee -a "$LOG"
  exit 1
fi

if grep -q "TILE_MODE_1_E2E_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] TILE_MODE_1_E2E_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] TILE_MODE_1_E2E_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
