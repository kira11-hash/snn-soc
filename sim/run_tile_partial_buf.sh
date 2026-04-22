#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: TILE_PARTIAL_BUF_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.tile_partial_buf_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_tile_partial_buf.f   -s tile_partial_buf_tb -o "$RUN_DIR/tile_partial_buf_tb.out"

LOG="$RUN_DIR/tile_partial_buf_tb.log"
run_vvp "$RUN_DIR/tile_partial_buf_tb.out" | tee "$LOG"

if grep -q "TILE_PARTIAL_BUF_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] TILE_PARTIAL_BUF_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] TILE_PARTIAL_BUF_TB_FAIL"
  echo "============================================"
  exit 1
fi
