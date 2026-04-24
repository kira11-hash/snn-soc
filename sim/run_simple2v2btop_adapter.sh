#!/usr/bin/env bash
# sim/run_simple2v2btop_adapter.sh
# simple2v2btop_adapter (Phase A-3) Icarus smoke test.
# DUT 来源：v2-arm-fpga-demo-passed@24951bb3（0 字拷入）
# Usage (from sim/): bash run_simple2v2btop_adapter.sh
# Pass criteria: log contains SIMPLE2V2BTOP_ADAPTER_PASS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

mkdir -p waves

echo "[INFO] Compiling simple2v2btop_adapter unit test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o adapter_test \
         -f sim_simple2v2btop_adapter.f \
         2>&1 | tee adapter_compile.log

if [ ! -f adapter_test ]; then
  echo "[ERROR] Compilation failed - check adapter_compile.log"
  exit 1
fi
echo "[INFO] Compilation OK"

echo "[INFO] Running simulation..."
run_vvp adapter_test 2>&1 | tee adapter_sim.log

echo ""
if grep -q "SIMPLE2V2BTOP_ADAPTER_PASS" adapter_sim.log; then
  echo "============================================"
  echo "[RESULT] SIMPLE2V2BTOP_ADAPTER_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] SIMPLE2V2BTOP_ADAPTER_FAIL"
  echo "  -> Check sim/adapter_sim.log for [ERR] lines"
  echo "============================================"
  exit 1
fi
