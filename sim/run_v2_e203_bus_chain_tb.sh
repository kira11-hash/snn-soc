#!/usr/bin/env bash
# sim/run_v2_e203_bus_chain_tb.sh
# Phase A-4: full bus-chain co-sim (bridge + fabric + adapter + mock v2b_top)
# Pass criteria: log contains V2_E203_BUS_CHAIN_PASS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

echo "[INFO] Compiling v2_e203 bus chain TB (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o v2e203_chain_test \
         -f sim_v2_e203_bus_chain.f \
         2>&1 | tee v2e203_chain_compile.log

if [ ! -f v2e203_chain_test ]; then
  echo "[ERROR] Compilation failed"
  exit 1
fi

echo "[INFO] Running simulation..."
run_vvp v2e203_chain_test 2>&1 | tee v2e203_chain_sim.log

echo ""
if grep -q "V2_E203_BUS_CHAIN_PASS" v2e203_chain_sim.log; then
  echo "============================================"
  echo "[RESULT] V2_E203_BUS_CHAIN_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] V2_E203_BUS_CHAIN_FAIL"
  echo "============================================"
  exit 1
fi
