#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

RUN_DIR=$(mktemp -d "$SCRIPT_DIR/.boot_erase_e2e_run.XXXXXX")
cleanup() {
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

run_iverilog -g2012 -gno-assertions -f sim_boot_erase_e2e.f \
  -s boot_erase_e2e_tb \
  -o "$RUN_DIR/boot_erase_e2e_tb.out"

LOG="$RUN_DIR/boot_erase_e2e_tb.log"
run_vvp "$RUN_DIR/boot_erase_e2e_tb.out" | tee "$LOG"

grep -q "BOOT_ERASE_E2E_TB_PASS" "$LOG"
echo "============================================"
echo "[RESULT] BOOT_ERASE_E2E_TB_PASS"
echo "============================================"
