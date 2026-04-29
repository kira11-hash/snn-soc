#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.fmap_flatten_reader_unit_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

GOLDEN_DIR="$RUN_DIR/golden"
mkdir -p "$GOLDEN_DIR"

run_python - "$GOLDEN_DIR" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path.cwd().parent / "python_multilayer"
sys.path.insert(0, str(ROOT))
from pack_fmap_words import pack_spike_fmap  # noqa: E402
from snn_engine_conv import flatten_gather_from_words, wordline_to_u32_words  # noqa: E402

out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)

cases = [
    {"H": 3, "W": 5, "C_in": 7, "T": 33, "tile": 0, "t": 32, "seed": 301},
    {"H": 4, "W": 4, "C_in": 20, "T": 10, "tile": 0, "t": 5, "seed": 302},
    {"H": 4, "W": 4, "C_in": 20, "T": 10, "tile": 1, "t": 9, "seed": 302},
]

case_file_idx: dict[tuple[int, int, int, int, int], int] = {}
lines: list[str] = []
for spec in cases:
    key = (spec["H"], spec["W"], spec["C_in"], spec["T"], spec["seed"])
    rng = np.random.default_rng(spec["seed"])
    spikes = rng.integers(0, 2, size=(spec["H"], spec["W"], spec["C_in"], spec["T"]),
                          dtype=np.int64)
    words = pack_spike_fmap(spikes)
    if key not in case_file_idx:
        case_file_idx[key] = len(case_file_idx)
        with (out_dir / f"flat_case{case_file_idx[key]}_words.hex").open(
            "w", encoding="ascii", newline="\n"
        ) as f:
            for word in words:
                f.write(f"{int(word):08x}\n")
    cfg = {
        "flatten_mode": True,
        "H": spec["H"],
        "W": spec["W"],
        "C_in": spec["C_in"],
        "C_out": 16,
        "T": spec["T"],
        "tile_count": (spec["H"] * spec["W"] * spec["C_in"] + 255) // 256,
        "last_tile_valid_count": (
            spec["H"] * spec["W"] * spec["C_in"]
            - 256 * (((spec["H"] * spec["W"] * spec["C_in"] + 255) // 256) - 1)
        ),
    }
    wl, valid_count = flatten_gather_from_words(
        words, cfg, timestep=spec["t"], tile_idx=spec["tile"]
    )
    wl_words = wordline_to_u32_words(wl)
    line = [
        str(case_file_idx[key]),
        str(len(words)),
        str(spec["tile"]),
        str(spec["H"]),
        str(spec["W"]),
        str(spec["C_in"]),
        str(spec["T"]),
        str((spec["T"] + 31) >> 5),
        str(spec["t"]),
        str(valid_count),
        *wl_words,
    ]
    lines.append(" ".join(line))

with (out_dir / "flat_expected.txt").open("w", encoding="ascii", newline="\n") as f:
    f.write(f"{len(lines)}\n")
    for line in lines:
        f.write(line + "\n")

print(f"[PY] generated {len(lines)} flatten-reader vectors in {out_dir}")
PY

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_fmap_flatten_reader_unit.f \
  -s fmap_flatten_reader_unit_tb -o "$RUN_DIR/fmap_flatten_reader_unit_tb.out"

LOG="$SCRIPT_DIR/fmap_flatten_reader_unit_sim.log"
run_vvp "$RUN_DIR/fmap_flatten_reader_unit_tb.out" "+GOLDEN_DIR=$GOLDEN_DIR" | tee "$LOG"

if grep -q "FMAP_FLATTEN_READER_UNIT_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] FMAP_FLATTEN_READER_UNIT_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] FMAP_FLATTEN_READER_UNIT_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
