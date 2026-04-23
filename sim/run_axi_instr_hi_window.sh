#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

run_iverilog -g2012 -gno-assertions \
  -s axi_instr_hi_window_tb \
  -o axi_instr_hi_window.out \
  ../rtl/top/snn_soc_pkg.sv \
  ../rtl/bus/axi2simple_bridge.sv \
  ../tb/axi_instr_hi_window_tb.sv

run_vvp axi_instr_hi_window.out | tee axi_instr_hi_window.log

if grep -q "AXI_INSTR_HI_WINDOW_TB_PASS" axi_instr_hi_window.log; then
  echo "============================================"
  echo "[RESULT] AXI_INSTR_HI_WINDOW_TB_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] AXI_INSTR_HI_WINDOW_TB_FAIL"
  echo "============================================"
  exit 1
fi
