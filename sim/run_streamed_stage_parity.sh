#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: STREAMED_STAGE_PARITY_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.streamed_stage_parity_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_streamed_stage_parity.f   -s streamed_stage_parity_tb -o "$RUN_DIR/streamed_stage_parity_tb.out"

LOG="$RUN_DIR/streamed_stage_parity_tb.log"
run_vvp "$RUN_DIR/streamed_stage_parity_tb.out" | tee "$LOG"

if grep -q "STREAMED_STAGE_PARITY_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] STREAMED_STAGE_PARITY_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] STREAMED_STAGE_PARITY_TB_FAIL"
  echo "============================================"
  exit 1
fi
