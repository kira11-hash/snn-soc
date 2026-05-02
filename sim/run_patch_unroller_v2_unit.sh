#!/usr/bin/env bash
# B1 fix（2026-05-02）：patch_unroller_v2 unit smoke gate.
# Expected pass tag: PATCH_UNROLLER_V2_UNIT_TB_PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.patch_unroller_v2_unit_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_patch_unroller_v2_unit.f -s patch_unroller_v2_unit_tb -o "$RUN_DIR/patch_unroller_v2_unit_tb.out"

LOG="$RUN_DIR/patch_unroller_v2_unit_tb.log"
run_vvp "$RUN_DIR/patch_unroller_v2_unit_tb.out" | tee "$LOG"

if grep -q "PATCH_UNROLLER_V2_UNIT_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] PATCH_UNROLLER_V2_UNIT_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] PATCH_UNROLLER_V2_UNIT_TB_FAIL"
  echo "============================================"
  exit 1
fi
