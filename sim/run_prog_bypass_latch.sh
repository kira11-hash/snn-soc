#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

run_iverilog -g2012 -gno-assertions \
  -f sim_prog_bypass_latch.f \
  -s prog_bypass_latch_tb \
  -o prog_bypass_latch.out

run_vvp prog_bypass_latch.out | tee prog_bypass_latch.log

if grep -q "PROG_BYPASS_LATCH_TB_PASS" prog_bypass_latch.log; then
  echo "============================================"
  echo "[RESULT] PROG_BYPASS_LATCH_TB_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] PROG_BYPASS_LATCH_TB_FAIL"
  echo "============================================"
  exit 1
fi
