#!/usr/bin/env bash
# sim/run_bus_interconnect_v2_e203.sh
# bus_interconnect_v2_e203 (Phase A-1) Icarus smoke test.
# Usage (from sim/): bash run_bus_interconnect_v2_e203.sh
# Pass criteria: log contains BUS_INTERCONNECT_V2_E203_PASS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

echo "[INFO] Compiling bus_interconnect_v2_e203 unit test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o bus_ic_v2e203_test \
         -f sim_bus_interconnect_v2_e203.f \
         2>&1 | tee bus_ic_v2e203_compile.log

if [ ! -f bus_ic_v2e203_test ]; then
  echo "[ERROR] Compilation failed - check bus_ic_v2e203_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
run_vvp bus_ic_v2e203_test 2>&1 | tee bus_ic_v2e203_sim.log

echo ""
if grep -q "BUS_INTERCONNECT_V2_E203_PASS" bus_ic_v2e203_sim.log; then
  echo "============================================"
  echo "[RESULT] BUS_INTERCONNECT_V2_E203_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] BUS_INTERCONNECT_V2_E203_FAIL"
  echo "  -> Check sim/bus_ic_v2e203_sim.log for [ERR] lines"
  echo "============================================"
  exit 1
fi
