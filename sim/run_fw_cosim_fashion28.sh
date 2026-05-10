#!/usr/bin/env bash
# Config #5 firmware-style cosim runner.
# Expected pass tag: FW_COSIM_FASHION28_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.fw_cosim_fashion28_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_fw_cosim_fashion28.f \
  -s fw_cosim_fashion28_tb -o "$RUN_DIR/fw_cosim_fashion28_tb.out"

LOG="$RUN_DIR/fw_cosim_fashion28_tb.log"
run_vvp "$RUN_DIR/fw_cosim_fashion28_tb.out" | tee "$LOG"

if grep -q "FW_COSIM_FASHION28_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] FW_COSIM_FASHION28_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] FW_COSIM_FASHION28_TB_FAIL"
  echo "============================================"
  exit 1
fi
