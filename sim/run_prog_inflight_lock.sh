#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.prog_inflight_lock_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -f sim_prog_inflight_lock.f \
  -s prog_inflight_lock_tb \
  -o "$RUN_DIR/prog_inflight_lock_tb.out"

LOG="$RUN_DIR/prog_inflight_lock_tb.log"
run_vvp "$RUN_DIR/prog_inflight_lock_tb.out" | tee "$LOG"

grep -q "PROG_INFLIGHT_LOCK_TB_PASS" "$LOG"
echo "============================================"
echo "[RESULT] PROG_INFLIGHT_LOCK_TB_PASS"
echo "============================================"
