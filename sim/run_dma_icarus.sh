#!/usr/bin/env bash
# sim/run_dma_icarus.sh
# Build and run DMA unit smoke test with Icarus.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/common_iverilog_env.sh"
resolve_iverilog_tools

rm -f dma_test

echo "[INFO] Compiling DMA test (Icarus)..."
run_iverilog -g2012 -gno-assertions \
         -o dma_test \
         -f sim_dma.f \
         2>&1 | tee dma_compile.log

if [ ! -f dma_test ]; then
  echo "[ERROR] Compilation failed - check dma_compile.log"
  exit 1
fi

echo "[INFO] Running simulation..."
run_vvp dma_test 2>&1 | tee dma_sim.log

echo ""
if grep -q "DMA_SMOKETEST_PASS" dma_sim.log; then
  echo "============================================"
  echo "[RESULT] DMA_SMOKETEST_PASS"
  echo "============================================"
else
  echo "============================================"
  echo "[RESULT] DMA_SMOKETEST_FAIL"
  echo "  -> check sim/dma_sim.log for [FAIL] lines"
  echo "============================================"
  exit 1
fi
