#!/usr/bin/env bash
# sim/run_fpga_programmable_cim_model.sh
# Run FPGA programmable CIM model unit testbench.
# Expected pass tag: FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.fpga_cim_model_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top \
  -f sim_fpga_programmable_cim_model.f \
  -s fpga_programmable_cim_model_tb \
  -o "$RUN_DIR/fpga_cim_model_tb.out"

LOG="$RUN_DIR/fpga_cim_model_tb.log"
run_vvp "$RUN_DIR/fpga_cim_model_tb.out" | tee "$LOG"

if grep -q "FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] FPGA_PROGRAMMABLE_CIM_MODEL_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] FPGA_PROGRAMMABLE_CIM_MODEL_TB_FAIL"
  echo "============================================"
  exit 1
fi
