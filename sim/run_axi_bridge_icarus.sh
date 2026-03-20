#!/usr/bin/env bash
# sim/run_axi_bridge_icarus.sh
# AXI-Lite bridge Icarus smoke test.
# Usage (from sim/): bash run_axi_bridge_icarus.sh
# Pass criteria: log contains AXI_BRIDGE_SMOKETEST_PASS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

echo "[INFO] Compiling AXI-Lite bridge test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o axi_bridge_test \
         -f sim_axi_bridge.f \
         2>&1 | tee axi_bridge_compile.log

if [ ! -f axi_bridge_test ]; then
  echo "[ERROR] Compilation failed - check axi_bridge_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
run_vvp axi_bridge_test 2>&1 | tee axi_bridge_sim.log

echo ""
if grep -q "AXI_BRIDGE_SMOKETEST_PASS" axi_bridge_sim.log; then
  echo "============================================"
  echo "[RESULT] AXI_BRIDGE_SMOKETEST_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] AXI_BRIDGE_SMOKETEST_FAIL"
  echo "  -> Check sim/axi_bridge_sim.log for [FAIL] lines"
  echo "============================================"
  exit 1
fi
