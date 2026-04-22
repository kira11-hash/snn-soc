#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: FW_COSIM_RESIDENT_14X14_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.fw_cosim_resident_14x14_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_fw_cosim_resident_14x14.f   -s fw_cosim_resident_14x14_tb -o "$RUN_DIR/fw_cosim_resident_14x14_tb.out"

LOG="$RUN_DIR/fw_cosim_resident_14x14_tb.log"
run_vvp "$RUN_DIR/fw_cosim_resident_14x14_tb.out" | tee "$LOG"

if grep -q "FW_COSIM_RESIDENT_14X14_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] FW_COSIM_RESIDENT_14X14_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] FW_COSIM_RESIDENT_14X14_TB_FAIL"
  echo "============================================"
  exit 1
fi
