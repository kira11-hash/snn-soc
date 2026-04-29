#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.fmap_sram_v2_run.XXXXXX")
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_fmap_sram_v2.f \
  -s fmap_sram_v2_tb -o "$RUN_DIR/fmap_sram_v2_tb.out"

LOG="$SCRIPT_DIR/fmap_sram_v2_sim.log"
run_vvp "$RUN_DIR/fmap_sram_v2_tb.out" | tee "$LOG"

if grep -q "FMAP_SRAM_V2_TB_PASS" "$LOG"; then
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] FMAP_SRAM_V2_TB_PASS" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 0
else
  echo "============================================" | tee -a "$LOG"
  echo "[RESULT] FMAP_SRAM_V2_TB_FAIL" | tee -a "$LOG"
  echo "============================================" | tee -a "$LOG"
  exit 1
fi
