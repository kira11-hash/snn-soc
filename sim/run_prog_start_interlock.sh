#!/usr/bin/env bash
# Run prog_start_interlock_tb: verify back-to-back CIM/PROG START race is blocked.
# Expected pass tag: PROG_START_INTERLOCK_TB_PASS (6 cases including Q2 race T3/T4).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.prog_start_interlock_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_prog_start_interlock.f \
  -s prog_start_interlock_tb -o "$RUN_DIR/prog_start_interlock_tb.out"

LOG="$RUN_DIR/prog_start_interlock_tb.log"
run_vvp "$RUN_DIR/prog_start_interlock_tb.out" | tee "$LOG"

if grep -q "PROG_START_INTERLOCK_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] PROG_START_INTERLOCK_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] PROG_START_INTERLOCK_TB_FAIL"
  echo "============================================"
  exit 1
fi
