#!/usr/bin/env bash
# H1-full unit TB runner (essay/h1_full_design_2026_05_07.md §3.2).
# Verifies the LIF per-layer schedule mux + cfg_reset_mode plumbing in
# rtl/top/snn_soc_v2b_top.sv across 5 sub-tests:
#   1. GLOBAL_MODE=1 default sources STAGE_CFG1
#   2. LUT-write does not perturb GLOBAL_MODE=1 path
#   3. GLOBAL_MODE=0 + LAYER_IDX selects the LUT slot
#   4. GLOBAL_MODE=0 + reset_mode=1 (hard) -> membrane=0 after fire
#   5. GLOBAL_MODE toggle 1->0->1 honours last-write-wins
# Expected pass tag: LIF_PER_LAYER_SCHEDULE_UNIT_TB_PASS
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

run_iverilog -g2012 -gno-assertions \
  -o lif_per_layer_schedule_unit_test \
  -f sim_lif_per_layer_schedule_unit.f

LOG="lif_per_layer_schedule_unit.log"
run_vvp lif_per_layer_schedule_unit_test | tee "$LOG"

if grep -q "LIF_PER_LAYER_SCHEDULE_UNIT_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] LIF_PER_LAYER_SCHEDULE_UNIT_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] LIF_PER_LAYER_SCHEDULE_UNIT_TB_FAIL"
  echo "============================================"
  exit 1
fi
