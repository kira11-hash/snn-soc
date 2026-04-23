#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

run_iverilog -g2012 -gno-assertions \
  -s jtag_instr_hi_window_tb \
  -o jtag_instr_hi_window.out \
  -I../rtl/top \
  ../rtl/top/snn_soc_pkg.sv \
  ../rtl/periph/jtag_mem_loader.sv \
  ../tb/jtag_instr_hi_window_tb.sv

run_vvp jtag_instr_hi_window.out | tee jtag_instr_hi_window.log

if grep -q "JTAG_INSTR_HI_WINDOW_TB_PASS" jtag_instr_hi_window.log; then
  echo "============================================"
  echo "[RESULT] JTAG_INSTR_HI_WINDOW_TB_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] JTAG_INSTR_HI_WINDOW_TB_FAIL"
  echo "============================================"
  exit 1
fi
