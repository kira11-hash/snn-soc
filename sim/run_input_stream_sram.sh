#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: INPUT_STREAM_SRAM_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.input_stream_sram_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_input_stream_sram.f   -s input_stream_sram_tb -o "$RUN_DIR/input_stream_sram_tb.out"

LOG="$RUN_DIR/input_stream_sram_tb.log"
run_vvp "$RUN_DIR/input_stream_sram_tb.out" | tee "$LOG"

if grep -q "INPUT_STREAM_SRAM_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] INPUT_STREAM_SRAM_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] INPUT_STREAM_SRAM_TB_FAIL"
  echo "============================================"
  exit 1
fi
