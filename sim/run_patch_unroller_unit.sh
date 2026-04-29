#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools
resolve_python_tool

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.patch_unroller_unit_run.XXXXXX")
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
from pack_fmap_words import read_hex_words  # noqa: E402
from snn_engine_conv import patch_gather_from_words, wordline_to_u32_words  # noqa: E402
from synthetic_conv_cases import get_case  # noqa: E402

out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)

specs = [
    ("C1", 0, 0, 0, 0),
    ("C2", 1, 2, 0, 5),
    ("C3", 0, 0, 0, 9),
    ("C4", 0, 0, 0, 13),
    ("C4", 7, 7, 1, 63),
    ("C8", 32, 32, 0, 32),
]

case_file_idx: dict[str, int] = {}
lines: list[str] = []
for case_name, h, w, tile_idx, timestep in specs:
    case = get_case(case_name)
    cfg = case.cfg_dict(include_tile_cfg=True)
    words = read_hex_words(ROOT / f"synthetic_{case_name}_input_fmap_words.hex")
    if case_name not in case_file_idx:
        case_file_idx[case_name] = len(case_file_idx)
        with (out_dir / f"patch_case{case_file_idx[case_name]}_words.hex").open(
            "w", encoding="ascii", newline="\n"
        ) as f:
            for word in words:
                f.write(f"{int(word):08x}\n")
    wl, valid_count = patch_gather_from_words(
        words, cfg, out_h=h, out_w=w, timestep=timestep, tile_idx=tile_idx
    )
    wl_words = wordline_to_u32_words(wl)
    line = [
        str(case_file_idx[case_name]),
        str(len(words)),
        str(h),
        str(w),
        str(tile_idx),
        str(case.K),
        str(case.stride),
        str(case.pad),
        str(case.C_in),
        str(case.H),
        str(case.W),
        str(case.T),
        str(case.stream_words()),
        str(timestep),
        str(valid_count),
        *wl_words,
    ]
    lines.append(" ".join(line))

with (out_dir / "patch_expected.txt").open("w", encoding="ascii", newline="\n") as f:
    f.write(f"{len(lines)}\n")
    for line in lines:
        f.write(line + "\n")

print(f"[PY] generated {len(lines)} patch-unroller vectors in {out_dir}")
PY

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_patch_unroller_unit.f \
  -s patch_unroller_unit_tb -o "$RUN_DIR/patch_unroller_unit_tb.out"

LOG="$SCRIPT_DIR/patch_unroller_unit_sim.log"
run_vvp "$RUN_DIR/patch_unroller_unit_tb.out" "+GOLDEN_DIR=$GOLDEN_DIR" | tee "$LOG"

if grep -q "PATCH_UNROLLER_UNIT_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] PATCH_UNROLLER_UNIT_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] PATCH_UNROLLER_UNIT_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
