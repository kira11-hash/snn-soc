#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

rm -f jtag_loader_test

echo "[INFO] Compiling JTAG loader test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o jtag_loader_test \
         -f sim_jtag_loader.f \
         2>&1 | tee jtag_loader_compile.log

if [ ! -f jtag_loader_test ]; then
  echo "[ERROR] Compilation failed - check sim/jtag_loader_compile.log"
  exit 1
fi

echo "[INFO] Running simulation..."
run_vvp jtag_loader_test 2>&1 | tee jtag_loader_sim.log

if grep -q "JTAG_MEM_LOADER_PASS" jtag_loader_sim.log; then
  echo "============================================"
  echo "[RESULT] JTAG_MEM_LOADER_PASS"
  echo "============================================"
  exit 0
fi

echo "============================================"
echo "[RESULT] JTAG_MEM_LOADER_FAIL"
echo "  -> check sim/jtag_loader_sim.log"
echo "============================================"
exit 1
