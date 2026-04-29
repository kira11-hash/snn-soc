#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.conv_ctrl_v2_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_conv_ctrl_v2.f \
  -s conv_ctrl_v2_tb -o "$RUN_DIR/conv_ctrl_v2_tb.out"

LOG="$RUN_DIR/conv_ctrl_v2_tb.log"
run_vvp "$RUN_DIR/conv_ctrl_v2_tb.out" | tee "$LOG"

if grep -q "CONV_CTRL_V2_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] CONV_CTRL_V2_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] CONV_CTRL_V2_TB_FAIL"
  echo "============================================"
  exit 1
fi
