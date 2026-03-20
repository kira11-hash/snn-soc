#!/usr/bin/env bash
# sim/run_uart_icarus.sh
# UART TX controller Icarus smoke test.
# Usage (from sim/): bash run_uart_icarus.sh
# Pass criteria: log contains UART_SMOKETEST_PASS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

echo "[INFO] Compiling UART TX test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o uart_test \
         -f sim_uart.f \
         2>&1 | tee uart_compile.log

if [ ! -f uart_test ]; then
  echo "[ERROR] Compilation failed - check uart_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
run_vvp uart_test 2>&1 | tee uart_sim.log

echo ""
if grep -q "UART_SMOKETEST_PASS" uart_sim.log; then
  echo "============================================"
  echo "[RESULT] UART_SMOKETEST_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] UART_SMOKETEST_FAIL"
  echo "  -> Check sim/uart_sim.log for [FAIL] lines"
  echo "============================================"
  exit 1
fi
