#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.prog_disabled_no_pending_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -f sim_prog_disabled_no_pending.f \
  -s prog_disabled_no_pending_tb \
  -o "$RUN_DIR/prog_disabled_no_pending_tb.out"

LOG="$RUN_DIR/prog_disabled_no_pending_tb.log"
run_vvp "$RUN_DIR/prog_disabled_no_pending_tb.out" | tee "$LOG"

grep -q "PROG_DISABLED_NO_PENDING_TB_PASS" "$LOG"
echo "============================================"
echo "[RESULT] PROG_DISABLED_NO_PENDING_TB_PASS"
echo "============================================"
