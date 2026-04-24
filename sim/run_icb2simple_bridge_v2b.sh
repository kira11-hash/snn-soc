#!/usr/bin/env bash
# sim/run_icb2simple_bridge_v2b.sh
# icb2simple_bridge_v2b (Phase A-2) Icarus smoke test.
# Usage (from sim/): bash run_icb2simple_bridge_v2b.sh
# Pass criteria: log contains ICB2SIMPLE_BRIDGE_V2B_PASS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

echo "[INFO] Compiling icb2simple_bridge_v2b unit test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o icb_br_v2b_test \
         -f sim_icb2simple_bridge_v2b.f \
         2>&1 | tee icb_br_v2b_compile.log

if [ ! -f icb_br_v2b_test ]; then
  echo "[ERROR] Compilation failed - check icb_br_v2b_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
run_vvp icb_br_v2b_test 2>&1 | tee icb_br_v2b_sim.log

echo ""
if grep -q "ICB2SIMPLE_BRIDGE_V2B_PASS" icb_br_v2b_sim.log; then
  echo "============================================"
  echo "[RESULT] ICB2SIMPLE_BRIDGE_V2B_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] ICB2SIMPLE_BRIDGE_V2B_FAIL"
  echo "  -> Check sim/icb_br_v2b_sim.log for [ERR] lines"
  echo "============================================"
  exit 1
fi
