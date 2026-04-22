#!/usr/bin/env bash
# Auto-generated V2.B regression runner (2026-04-22 post-audit).
# Expected pass tag: STAGE_ENGINE_V2_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.stage_engine_v2_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_stage_engine_v2.f   -s stage_engine_v2_tb -o "$RUN_DIR/stage_engine_v2_tb.out"

LOG="$RUN_DIR/stage_engine_v2_tb.log"
run_vvp "$RUN_DIR/stage_engine_v2_tb.out" | tee "$LOG"

if grep -q "STAGE_ENGINE_V2_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] STAGE_ENGINE_V2_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] STAGE_ENGINE_V2_TB_FAIL"
  echo "============================================"
  exit 1
fi
