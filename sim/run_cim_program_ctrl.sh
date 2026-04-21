#!/usr/bin/env bash
# Run cim_program_ctrl_tb on main (V1 single-layer 64->10 SoC + CIM programming).
# Expected pass tag: CIM_PROGRAM_CTRL_PASS (8/8 cases).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.cim_program_ctrl_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_cim_program_ctrl.f \
  -s cim_program_ctrl_tb -o "$RUN_DIR/cim_program_ctrl_tb.out"

LOG="$RUN_DIR/cim_program_ctrl_tb.log"
run_vvp "$RUN_DIR/cim_program_ctrl_tb.out" | tee "$LOG"

if grep -q "CIM_PROGRAM_CTRL_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] CIM_PROGRAM_CTRL_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] CIM_PROGRAM_CTRL_FAIL"
  echo "============================================"
  exit 1
fi
