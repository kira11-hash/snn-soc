#!/usr/bin/env bash
# Run prog_pulse_cfg_tb on main: verify REG_PROG_PULSE_WIDTH 4-level preset decode
# (0=1us / 1=10us / 2=100us / 3=reserved->100us) and REG_PROG_ERASE_WIDTH
# fixed at 50000 cycles (1ms @ 50 MHz) with writes ignored.
# Expected pass tag: PROG_PULSE_CFG_TB_PASS.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.prog_pulse_cfg_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -I../rtl/top -f sim_prog_pulse_cfg.f \
  -s prog_pulse_cfg_tb -o "$RUN_DIR/prog_pulse_cfg_tb.out"

LOG="$RUN_DIR/prog_pulse_cfg_tb.log"
run_vvp "$RUN_DIR/prog_pulse_cfg_tb.out" | tee "$LOG"

if grep -q "PROG_PULSE_CFG_TB_PASS" "$LOG"; then
  echo "============================================"
  echo "[RESULT] PROG_PULSE_CFG_TB_PASS"
  echo "============================================"
  exit 0
else
  echo "============================================"
  echo "[RESULT] PROG_PULSE_CFG_TB_FAIL"
  echo "============================================"
  exit 1
fi
